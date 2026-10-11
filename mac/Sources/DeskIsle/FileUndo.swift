import Foundation

// MARK: - ⌘Z：文件操作的「撤销」栈

/// 一次文件操作的**逆操作**。
///
/// ⚠️ 设计前提：**只记录「逆操作所需的最小信息」，不记录操作本身**。
/// 因为撤销永远是从「现状」往回走一步，而不是重放历史 ——
/// 用户随时可能自己去动那些文件（改名、删掉、移走），保存旧快照没有意义，
/// 反而会让「删了不该删的」变成可能。所以每一条都只在**确认目标还处于刚被操作出来的状态**时才执行。
enum FileUndoKind {
    /// 移回原位（剪切粘贴 / 拖入移动）。
    case moveBack(pairs: [(from: String, to: String)])
    /// 删掉刚**复制**出来的目标（复制粘贴的逆操作就是删掉那些副本）。
    case removeCopies([String])
    /// 从废纸篓捡回来。
    case restoreFromTrash(pairs: [(original: String, trashed: String)])
    /// 改回旧名字。
    case rename(path: String, oldName: String)
    /// 删掉新建出来的东西（新建文件 / 文件夹、制作副本、替身、压缩产物）。
    case removeCreated([String])
}

struct FileUndoRecord {
    let kind: FileUndoKind
    /// 展示用的一句话 —— 撤销提示要说清「撤销了什么」，不然用户不知道发生了什么。
    let verb: String
    /// 条目数（决定 Toast 用不用带计数）。
    let count: Int
}

/// 进程级单例：撤销栈是**跨分区**的（在 A 分区删、切到 B 分区撤销，用户眼里是同一个「上一步」）。
final class FileUndoStack {
    static let shared = FileUndoStack()
    private init() {}

    private(set) var records: [FileUndoRecord] = []
    /// 上限：再多的历史也用不上，而且栈里躺着的历史文件路径随时可能被别的程序动过。
    private let limit = 30

    func push(_ record: FileUndoRecord) {
        records.append(record)
        if records.count > limit { records.removeFirst(records.count - limit) }
    }

    /// 推入一条逆操作（`count` 由 `paths` 自动算）。
    func push(_ kind: FileUndoKind, verb: String, count: Int? = nil) {
        let n = count ?? {
            switch kind {
            case .moveBack(let p):            return p.count
            case .removeCopies(let p):        return p.count
            case .restoreFromTrash(let p):    return p.count
            case .rename:                     return 1
            case .removeCreated(let p):       return p.count
            }
        }()
        guard n > 0 else { return }   // 没实际改动就别占一格，否则 ⌘Z 会「空转」
        push(FileUndoRecord(kind: kind, verb: verb, count: n))
    }

    @discardableResult
    func pop() -> FileUndoRecord? { records.popLast() }

    var isEmpty: Bool { records.isEmpty }
}

extension AppDelegate {

    /// 撤销最近一次文件操作（⌘Z）。
    ///
    /// 三条规矩：
    /// 1. **目标不见了就跳过**（用户可能自己动过），半途失败也算数，只要有一项成功就算撤销成功；
    /// 2. 目标位已被占用的也不动 —— 撤销的目的是「回到操作前」，
    ///    强行覆盖同名只会制造新的损失；
    /// 3. 撤销**不进撤销栈**（否则 ⌘Z 会来回抖），也不产生 Toast 之外的任何副作用。
    func undoLastFileOperation(in id: String) {
        guard let rec = FileUndoStack.shared.pop() else {
            Toast.shared.show("没有可撤销的操作", icon: "arrow.uturn.left")
            return
        }

        let fm = FileManager.default
        var done = 0
        var failed: [String] = []

        switch rec.kind {
        case .moveBack(let pairs):
            for pair in pairs {
                guard fm.fileExists(atPath: pair.to), !fm.fileExists(atPath: pair.from) else {
                    failed.append((pair.from as NSString).lastPathComponent); continue
                }
                do { try fm.moveItem(atPath: pair.to, toPath: pair.from); done += 1 }
                catch { failed.append((pair.from as NSString).lastPathComponent) }
            }

        case .removeCopies(let paths), .removeCreated(let paths):
            for path in paths where fm.fileExists(atPath: path) {
                do { try fm.removeItem(atPath: path); done += 1 }
                catch { failed.append((path as NSString).lastPathComponent) }
            }

        case .restoreFromTrash(let pairs):
            for pair in pairs {
                guard fm.fileExists(atPath: pair.trashed), !fm.fileExists(atPath: pair.original) else {
                    failed.append((pair.original as NSString).lastPathComponent); continue
                }
                do { try fm.moveItem(atPath: pair.trashed, toPath: pair.original); done += 1 }
                catch { failed.append((pair.original as NSString).lastPathComponent) }
            }

        case .rename(let path, let oldName):
            let dir = (path as NSString).deletingLastPathComponent
            let target = (dir as NSString).appendingPathComponent(oldName)
            guard fm.fileExists(atPath: path), !fm.fileExists(atPath: target) else {
                failed.append(oldName); break
            }
            do { try fm.moveItem(atPath: path, toPath: target); done += 1 }
            catch { failed.append(oldName) }
        }

        guard done > 0 else {
            Toast.shared.show("无法撤销",
                              detail: "相关文件已被改动，DeskIsle 不会再动它们",
                              icon: "exclamationmark.triangle.fill")
            return
        }

        NotificationCenter.default.post(name: .portalFolderChanged, object: id)
        Toast.shared.show(countText(done, "已撤销：\(rec.verb)"),
                          detail: failed.isEmpty ? "" : "\(failed.count) 项已跳过（可能被改动过）",
                          icon: "arrow.uturn.left")
    }

    private func countText(_ n: Int, _ verb: String) -> String {
        n == 1 ? "\(verb) 1 项" : "\(verb) \(n) 项"
    }
}
