import AppKit
import SwiftUI
import DeskIsleCore

// MARK: - 拖出（分区 → 访达 / 桌面 / 其它应用）

/// 拖出结束后**要不要删掉原件**的判定 —— 与 Windows `FileDragSource.TryBegin` 同一口径。
///
/// 两条缺一不可：
/// 1. **对方必须明确完成了移动**（`operation == .move`）。系统只有在移动成功时才回 `.move`，
///    失败回 `[]`，所以不会出现「对方没接到、我们却先把原件删了」。
/// 2. **落点不能在应用内部**。分区↔分区、拖到某个文件夹条目上，都由
///    `PortalView.importFiles` 自己把文件搬走（真实 `moveItem`）；
///    若这里再删一次，删掉的是**刚搬过去的新位置**，用户看到的就是「拖进去了又立刻没了」。
enum FileDrag {
    static func shouldRemoveOriginals(operationIsMove: Bool, handledInsideApp: Bool) -> Bool {
        operationIsMove && !handledInsideApp
    }

    /// 拖出成功后，**等多久**才轮到我们动原件。
    ///
    /// ⚠️⚠️ 这是整条拖出链路里最要命的一个数，别再改回 0。
    /// 访达接收拖放后是**异步**拷贝的：`draggingSession(_:endedAt:operation:)` 触发时，
    /// 它的拷贝任务很可能才刚刚开始读源文件。此时删原件会让访达的拷贝**中途断流**，
    /// 于是它弹出「无法完成此操作，因为发生意外错误（错误代码 -8058）」——
    /// 而原件已经被我们删掉了，目标又没拷成，**用户看到的就是「两边都没有」**。
    /// （拖文件夹尤其明显：递归拷贝到一半被抽掉源，表现就是「乱移动」。）
    ///
    /// 所以这里给一个保守的等待窗口；目录按更长的窗口算，因为递归拷贝的尾巴比单文件长得多。
    /// 窗口本身不够精确，所以配套的另一半是：**一律进废纸篓、绝不硬删**
    /// —— 万一窗口还是不够，用户至少能从废纸篓把原件捞回来。
    static func settleDelay(containsDirectory: Bool) -> TimeInterval {
        containsDirectory ? 12.0 : 3.0
    }

    /// 本次拖拽是否被应用自己的落点接手。
    ///
    /// ⚠️ 是全局状态，但拖拽在 macOS 上一次只能有一个会话，所以不会出现串台。
    /// 由 `PortalView.importFiles` 置位，
    /// 由下面 `FileDragSourceView.beginSession` 在发起时清零。
    static var handledInsideApp = false

    /// 当前是否已有文件行发起了拖拽会话。
    ///
    /// ⚠️ 为什么要这个额外的锁：光靠「按下点落在本行内」不够 ——
    /// 不同分区窗口的行会**坐标撞车**（列表布局一致、行高列宽相同），
    /// 谁抢到谁发起（监视器回调是「后安装的先跑」），拖走的就是别的文件。
    /// 窗口级监视器已经把「一次拖动只在一个窗口里裁决」坐实了，
    /// 这把锁是第二道保险：即使哪天窗口判据被改坏，也保证**一次拖动只会带出一组文件**。
    ///
    /// 由 `beginSession` 置 true、`draggingSession(_:endedAt:operation:)` 置 false；
    /// 另外在 `leftMouseDown` 里兜底清零 —— 万一某个会话没走到 endedAt，
    /// 用户下一次按下就能自动解开，不会永远拖不动。
    static var sessionActive = false

    /// 当前正在由本应用发起的拖拽源路径。
    static var activeDragPaths: [String] = []

    /// 判定目标路径是否不能作为本次拖拽的落点（例如文件夹不能拖入其自身或子孙）。
    static func isDropTargetForbidden(for targetPath: String) -> Bool {
        FileMove.isDropTargetForbidden(targetDirectory: targetPath, draggedPaths: activeDragPaths)
    }
}

/// 「把分区里的文件拖出去」的拖拽源。
///
/// 为什么不用 SwiftUI 的 `.onDrag`：
/// 它内部确实发起了 `NSDraggingSession`，但**没有把 `NSDraggingSource` 暴露出来**，
/// 于是我们永远收不到 `draggingSession(_:endedAt:operation:)`，
/// 也就无从得知访达到底执行的是「移动」还是「复制」。
/// 后果就是：拖出去永远只复制一份，**原件留在映射文件夹里** ——
/// 用户看到的就是「移出了但文件还在」，以及之后同名文件再移入时弹出的重复提示。
///
/// 而访达的同款行为是**同卷移动、跨卷复制**，由系统按卷自己决定，并把结果回传给源。
/// 想拿到这个结果，就只能自己发起会话、自己当 `NSDraggingSource`。
///
/// ⚠️⚠️ **绝不参与命中测试**（`hitTest` 恒返回 `nil`）：
/// 一旦这里返回 `self`，AppKit 的命中测试就会停在这一层，
/// 下面 SwiftUI 行的 `.onTapGesture`（单击选中 / 双击打开）和 `.contextMenu` 会**全部收不到事件**。
/// 所以本视图的拖拽由**窗口级**鼠标监视器感知并转发进来（`PartitionPanel.installDragMonitor`），
/// 而不是自己成为第一响应者、也不是自己装监视器。
///
/// ⚠️ 为什么监视器装在**窗口**上而不是每个行各装一个：监视器是应用级的，
/// AppKit 每个事件都要把它们全部跑一遍。一个分区几十个条目、多分区叠加就是几百个监视器
/// 参与每次 mousedown / dragged 的分发，而拖拽期间这类事件每秒来几十次。
/// 窗口级之后：一个窗口一个监视器，按下时按坐标定位到那一行并缓存，拖拽期间 O(1)。
final class FileDragSourceView: NSView, NSDraggingSource {
    override var isFlipped: Bool { true }

    /// 要拖出的文件（支持多个 —— 与访达一致，拖选中的多个就走多个）。
    var paths: [String] = []
    /// 原件被移走后要刷新的分区。
    var partitionID: String?

    private var downWindowNumber = Int.max
    private var downLocation = NSPoint.zero
    private var beganSession = false

    // MARK: 命中测试 —— 必须恒为 nil，见类型注释

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func teardown() {
        FileDrag.activeDragPaths = []
    }

    /// - Returns: 原事件（继续正常派发）或 `nil`（已吞掉 / 已转为拖拽）。
    ///
    /// ⚠️ 由**窗口级**监视器转发过来（见 `PartitionPanel.installDragMonitor`），本类自己不再装监视器。

    /// - Returns: 原事件（继续正常派发）或 `nil`（已吞掉 / 已转为拖拽）。
    func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDown:
            // ⚠️ 只认「本行所在窗口」的按下。监视器是应用级的，别的分区窗口按下也会送到这里；
            // 不校验窗口的话，另一个窗口里恰好同坐标的那一行会认为自己被按住，
            // 于是抢走这次拖拽 —— 用户拖的是 A，被搬走的却是 B。
            guard event.windowNumber == ownWindowID else {
                downWindowNumber = Int.max
                return event
            }
            downWindowNumber = event.windowNumber
            downLocation = event.locationInWindow
            beganSession = false
            // 兜底解锁：万一上一次会话没走到 endedAt，这一次按下自动解掉。
            FileDrag.sessionActive = false
            FileDrag.activeDragPaths = []
            return event

        case .leftMouseDragged:
            // 判据全部在 `FileDragLaunch.shouldBegin`（两端同源、有断言覆盖），
            // 别在这里手写 —— 漏一条就会拖错文件。
            let input = DragLaunchInput(
                eventWindowID: event.windowNumber,
                ownWindowID: ownWindowID,
                downWindowID: downWindowNumber,
                downInsideRow: containsDownPoint(),
                alreadyBegan: beganSession,
                anotherSessionActive: FileDrag.sessionActive,
                dx: event.locationInWindow.x - downLocation.x,
                dy: event.locationInWindow.y - downLocation.y)
            guard FileDragLaunch.shouldBegin(input) else { return event }
            return beginSession(with: event) ? nil : event

        default:
            return event
        }
    }

    /// 本行所在窗口；还没挂到窗口上时为 nil（此时一律不发起拖拽）。
    private var ownWindowID: Int? { window?.windowNumber }

    /// 按下点是否落在本视图内（把自身 bounds 换算到窗口坐标再判）。
    private func containsDownPoint() -> Bool {
        let frameInWindow = convert(bounds, to: nil)
        return frameInWindow.contains(downLocation)
    }

    private func beginSession(with event: NSEvent) -> Bool {
        let urls: [URL] = paths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return false }

        let currentBounds = (bounds.width > 0 && bounds.height > 0)
            ? bounds
            : NSRect(x: 0, y: 0, width: 64, height: 64)

        let items: [NSDraggingItem] = urls.enumerated().map { index, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)

            // 计算在当前视图本地坐标系（view's local coordinate system）下的图标矩形：
            // ⚠️ NSDraggingItem.setDraggingFrame(_:contents:) 要求传入发起会话的视图（self）本地坐标系！
            // 绝对不能传入转成窗口坐标的 NSRect（convert(bounds, to: nil)），
            // 否则 AppKit 会把窗口坐标再次叠加上视图在窗口内的原点位置，导致拖拽浮层从分区窗外甚至屏幕边缘漂移进来。
            let stackOffset = CGFloat(min(index, 4)) * 3
            let dragRect: NSRect
            if currentBounds.height <= 36 {
                // 列表视图：小图标（20x20），在左侧垂直居中
                let size: CGFloat = 20
                let x: CGFloat = 4 + stackOffset
                let y = max(0, (currentBounds.height - size) / 2) + stackOffset
                dragRect = NSRect(x: x, y: y, width: size, height: size)
            } else {
                // 网格视图：标准图标（32x32），在单元格上半部分水平居中
                let size: CGFloat = 32
                let x = max(0, (currentBounds.width - size) / 2) + stackOffset
                let y: CGFloat = 6 + stackOffset
                dragRect = NSRect(x: x, y: y, width: size, height: size)
            }

            icon.size = dragRect.size
            item.setDraggingFrame(dragRect, contents: icon)
            return item
        }

        beganSession = true
        FileDrag.sessionActive = true
        FileDrag.activeDragPaths = paths
        // 每次发起都清零：上一次落在应用内部留下的 true 不能带到这一次
        FileDrag.handledInsideApp = false
        beginDraggingSession(with: items, event: event, source: self)
        return true
    }

    // MARK: NSDraggingSource

    /// 允许哪些操作：应用外交给系统按卷决定（同卷 → move、跨卷 → copy），应用内只允许移动。
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        switch context {
        case .outsideApplication: return [.copy, .move]
        case .withinApplication:  return [.move]
        @unknown default:         return [.copy]
        }
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {}
    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {}

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        defer {
            beganSession = false
            FileDrag.sessionActive = false
            FileDrag.activeDragPaths = []
            downWindowNumber = Int.max
            downLocation = .zero
        }
        guard FileDrag.shouldRemoveOriginals(operationIsMove: operation == .move,
                                             handledInsideApp: FileDrag.handledInsideApp) else { return }

        let fm = FileManager.default
        // 先把这一刻确实存在的原件记下来：稍后异步处理时，列表可能已经被刷新过。
        let pending = paths.filter { fm.fileExists(atPath: $0) }
        guard !pending.isEmpty else { return }

        var isDir: ObjCBool = false
        let hasDirectory = pending.contains {
            fm.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue
        }
        let delay = FileDrag.settleDelay(containsDirectory: hasDirectory)
        let id = partitionID

        // 见 `FileDrag.settleDelay` 的说明：等访达的拷贝落定，再动原件。
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            var removed = 0
            for path in pending {
                // 访达若已自己把原件搬走（同卷 rename），这里就没它了 —— 什么都不用做。
                guard fm.fileExists(atPath: path) else { continue }
                do {
                    // ⚠️ 一律进废纸篓，绝不硬删：等待窗口只是估算，
                    // 真被掐断时用户还能从废纸篓把原件捞回来。
                    try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                    removed += 1
                } catch {
                    NSLog("[DeskIsle] 拖出后原件移入废纸篓失败 %@: %@", path, error.localizedDescription)
                }
            }
            guard removed > 0, let id else { return }
            DispatchQueue.main.async {
                // 目录已经变了，让分区立刻重扫（比等目录监听那一拍更快、也更确定）
                NotificationCenter.default.post(name: .portalFolderChanged, object: id)
            }
        }
    }
}

/// SwiftUI 侧的包装：作为**覆盖层**铺在文件行上（自身不参与命中测试，见 `FileDragSourceView`）。
struct FileDragSource: NSViewRepresentable {
    var paths: [String]
    var partitionID: String?

    func makeNSView(context: Context) -> FileDragSourceView {
        let v = FileDragSourceView(frame: .zero)
        apply(to: v)
        return v
    }

    func updateNSView(_ nsView: FileDragSourceView, context: Context) { apply(to: nsView) }

    static func dismantleNSView(_ nsView: FileDragSourceView, coordinator: ()) { nsView.teardown() }

    private func apply(to v: FileDragSourceView) {
        v.paths = paths
        v.partitionID = partitionID
    }
}
