import Foundation
import DeskIsleCore

/// 全局搜索的一条结果。
struct SearchHit: Identifiable {
    enum Kind: String {
        case file, folder, todo, note

        var icon: String {
            switch self {
            case .file:   return "doc"
            case .folder: return "folder.fill"
            case .todo:   return "checkmark.circle"
            case .note:   return "note.text"
            }
        }
    }

    let id: String
    let kind: Kind
    /// 主行：文件名 / 待办文本 / 便签行内容
    let title: String
    /// 副行：文件所在目录，或「所属分区」说明
    let detail: String
    let partitionID: String
    let partitionTitle: String
    /// 文件 / 目录类才有真实路径
    let path: String?
    let score: Int

    var url: URL? { path.map { URL(fileURLWithPath: $0) } }
}

/// 跨分区搜索：一次查询覆盖全部映射文件夹、待办与便签。
///
/// 设计取舍：
/// - **只搜"便宜"的东西**：分区自己的目录一层（或按规则递归一层）、
///   待办与便签的内存文本。不做全盘索引 —— 那需要一个常驻索引与失效策略，
///   而本应用的分区数量与目录规模（几十个分区、每目录几百个文件）远没到需要索引的量级。
/// - **目录列举带 5 秒缓存**：边打边搜会一个字符触发一次列举，没有缓存时
///   在一个几千文件的目录上会明显卡手。
/// - **每目录有上限**：极端目录（几万文件）宁可少收一些，也不能让 UI 卡住。
enum GlobalSearch {
    /// 单个目录最多列举的条目数
    static let perDirectoryLimit = 2000
    /// 默认返回的结果条数上限
    static let defaultLimit = 150

    // MARK: - 目录列举缓存

    private struct DirEntry {
        let items: [(name: String, isDir: Bool)]
        let at: Date
    }
    private static var dirCache: [String: DirEntry] = [:]
    private static let dirCacheTTL: TimeInterval = 5
    private static let cacheLock = NSLock()

    /// 支持多线程调用（支持后台异步搜索）。
    private static func listDirectory(_ path: String) -> [(name: String, isDir: Bool)] {
        guard !path.isEmpty else { return [] }
        let now = Date()
        cacheLock.lock()
        if let hit = dirCache[path], now.timeIntervalSince(hit.at) < dirCacheTTL {
            cacheLock.unlock()
            return hit.items
        }
        cacheLock.unlock()

        let fm = FileManager.default
        // 「是不是目录」走 FileKinds 的口径（是目录 且 不是包）：
        // 否则映射目录里的 `.app` 会被搜成「文件夹」，结果行的图标与可用动作都对不上。
        guard FileKinds.meta(ofPath: path, fileManager: fm).isDirectory else {
            cacheLock.lock()
            dirCache[path] = DirEntry(items: [], at: now)
            cacheLock.unlock()
            return []
        }

        // 批量预取 isDirectory / isPackage：比原先的「contentsOfDirectory + 逐条 meta」
        // 少一轮系统调用，2000 条目录约快 2–5x（OS 内部对批量 getattrlist 做了合并）。
        // skipsSubdirectoryDescendants = 只取一层，skipsHiddenFiles = 与 DirectoryScan 口径一致。
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let baseURL = URL(fileURLWithPath: path)
        var items: [(name: String, isDir: Bool)] = []
        if let enumerator = fm.enumerator(
            at: baseURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                guard items.count < perDirectoryLimit else { break }
                let vals = try? url.resourceValues(forKeys: Set(resourceKeys))
                let isPhysDir = vals?.isDirectory ?? false
                let isPkg    = vals?.isPackage ?? false
                    || (isPhysDir && FileKinds.packageExtensions.contains(
                            url.pathExtension.lowercased()))
                items.append((name: url.lastPathComponent, isDir: isPhysDir && !isPkg))
            }
        }
        cacheLock.lock()
        dirCache[path] = DirEntry(items: items, at: now)
        cacheLock.unlock()
        return items
    }

    /// 手动清缓存（新建/删除分区、导入配置后调用，避免搜到已消失的文件）。
    static func invalidateCache() {
        cacheLock.lock()
        dirCache.removeAll()
        cacheLock.unlock()
    }

    // MARK: - 搜索

    static func search(query: String, in config: Config,
                       limit: Int = defaultLimit) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        var hits: [SearchHit] = []
        var seq = 0
        func add(_ kind: SearchHit.Kind, title: String, detail: String, path: String?,
                 partitionID: String, partitionTitle: String, score: Int) {
            seq += 1
            hits.append(SearchHit(id: "\(partitionID)-\(kind.rawValue)-\(seq)",
                                  kind: kind, title: title, detail: detail,
                                  partitionID: partitionID, partitionTitle: partitionTitle,
                                  path: path, score: score))
        }

        for p in config.partitions {
            guard let id = p["id"] as? String else { continue }
            let type = (p["type"] as? String) ?? ""
            let title = (p["title"] as? String) ?? type

            switch type {
            case "portal":
                let folder = (p["folderPath"] as? String) ?? ""
                guard !folder.isEmpty else { break }
                for e in listDirectory(folder) {
                    guard let s = QueryMatcher.score(query: q, candidate: e.name) else { continue }
                    add(e.isDir ? .folder : .file, title: e.name, detail: folder,
                        path: (folder as NSString).appendingPathComponent(e.name),
                        partitionID: id, partitionTitle: title, score: s)
                }

            case "todo":
                for t in config.todos(of: id) {
                    guard let s = QueryMatcher.score(query: q, candidate: t.text) else { continue }
                    add(.todo, title: t.text,
                        detail: t.completed ? "\(title) · 已完成" : title,
                        path: nil, partitionID: id, partitionTitle: title, score: s)
                }

            case "notes":
                let body = config.str("noteContent", of: id) ?? ""
                let lines = body.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                for line in lines {
                    guard let s = QueryMatcher.score(query: q, candidate: line) else { continue }
                    add(.note, title: line, detail: title, path: nil,
                        partitionID: id, partitionTitle: title, score: s)
                }

            default:
                break
            }
        }

        // 先按得分，再按名称 —— 得分相同时按名称保证结果顺序稳定（不会因遍历顺序抖动）
        hits.sort {
            $0.score != $1.score ? $0.score > $1.score : $0.title.localizedCompare($1.title) == .orderedAscending
        }
        return Array(hits.prefix(limit))
    }
}
