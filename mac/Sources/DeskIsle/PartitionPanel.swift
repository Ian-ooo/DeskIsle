import AppKit
import SwiftUI
import DeskIsleLayout

/// 分区全局外观默认值。
///
/// ⚠️ 圆角**曾经**是不可调项（设置面板里连滑杆都没有，`Config.styleKeys` 只被内部代码读到）。
/// 2026-09-30 起分区级外观开放为「背景色 / 不透明度 / 圆角 / 模糊 / 标题色 / 正文色」六项，
/// 口径集中在 `DeskIsleLayout/PartitionLook.swift`（三端共用、带单测）；
/// 这里只留「一个 per-partition 值都没有时的全局默认」。
enum Look {
    static let cornerRadius: CGFloat = PartitionLook.defaultCornerRadius
}

/// 顶栏（导航栏）与分区标题栏的字体规格。
///
/// 两处**必须取自同一份常量**：这两排 UI 在视觉上是同一条水平带（顶栏胶囊 / 各分区标题栏），
/// 分开各写一个 `.system(size:weight:)` 时极易悄悄分叉（一个 semibold、一个 medium，
/// 差 0.5pt 也看得出来「不齐」），而它们又分居两个结构体、改一处不会想起另一处。
///
/// 字号取 12.5pt（而非此前的 13pt）：标题栏右侧的按钮个数在增长（置顶/锁定/设置/自适应/
/// 折叠/删除），13pt 下中文标题在默认宽度分区里会被压到截断；
/// 12.5pt 同屏能多放下约 1 个汉字，且与 44pt 标题栏的留白比例更协调。
enum DeskFont {
    /// 顶栏品牌名、分区标题正文。
    static let header = Font.system(size: 12.5, weight: .semibold)
    /// 顶栏图标按钮。
    static let topIcon = Font.system(size: 11.5)
    /// 分区标题栏图标按钮（比顶栏更小：标题栏按钮更密）。
    static let headerIcon = Font.system(size: 10, weight: .semibold)
    /// 顶栏品牌图标、分区标题前的类型 emoji。
    static let glyph = Font.system(size: 12.5)
    /// 分区标题右侧的数字徽标。
    static let badge = Font.system(size: 10, weight: .medium)
}

/// 单个分区窗口。每分区一个 NSPanel：置顶与否只改 `level` / `collectionBehavior`，
/// 内容不搬家 —— 从架构上消灭 Electron 版的「跨窗口搬家闪烁」。
final class PartitionPanel: NSPanel {
    let partitionID: String
    let cornerRadius: CGFloat
    let config: Config

    /// 配置坐标（x/y）是「相对所在屏幕左上角」的距离；多显示器下必须加上
    /// 该屏幕的 origin 才是全局原生坐标，否则分区会全部跑到主屏左上角。
    init(config: Config, id: String, screen: NSScreen) {
        self.partitionID = id
        self.cornerRadius = Look.cornerRadius
        self.config = config

        let w = CGFloat(config.num("width", of: id))
        let h = CGFloat(config.num("height", of: id))
        let x = CGFloat(config.num("x", of: id)) + screen.frame.origin.x
        let y = CGFloat(config.num("y", of: id))
        let yNative = screen.frame.origin.y + screen.frame.height - y - h

        super.init(
            contentRect: NSRect(x: x, y: yNative, width: w, height: h),
            // .nonactivatingPanel 是「常显」的关键：激活式面板在 accessory 应用未激活时
            // 不会被合成显示（窗口存在但 onscreen=false）。键盘焦点改为在点击时
            // 由 Store 显式激活应用 + makeKey（见 AppDelegate 的鼠标监视器）。
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        // ⚠️ **绝不能开 `isMovableByWindowBackground`**：一开就是「窗口内任何位置都能拖着走」，
        // 于是拖分区里的文件 / 选便签里的文字 / 拖待办条目时，AppKit 的窗口拖动会**抢在**这些
        // 手势前面 —— 表现为「一拖文件，整个分区跟着跑，文件根本拖不出去」。
        // 拖动改由 `sendEvent` 只在**标题栏**那一条上接管（见 `isInTitleBar`），
        // 内容区留给条目拖拽（`.onDrag`）与文本选择。
        isMovableByWindowBackground = false
        acceptsMouseMovedEvents = true

        // 系统 tooltip 默认**只在应用位于前台时**才显示
        // （`NSWindow.allowsToolTipsWhenApplicationIsInactive` 默认 false，Apple 文档明写）。
        // 而 DeskIsle 是 accessory 应用 + `.nonactivatingPanel`：用户不点分区时应用就在后台，
        // 于是「悬停图标 / 文件名看完整提示」几乎从不出现 —— 这正是它「时有时无」的原因：
        // 点过分区后应用短暂前台，提示才正常。打开这个开关让提示不再依赖前台状态。
        // （实测：默认 false 时后台悬停 2.6s 无提示；置 true 后 0.46s 即出现。）
        allowsToolTipsWhenApplicationIsInactive = true

        let pinned = config.bool("isAlwaysOnTop", of: id)
        let collapsed = config.bool("isCollapsed", of: id)
        applyPinned(pinned)
        // 全局锁按屏独立：用**本分区所属显示器**的锁定态
        applyLocked(config.bool("isLocked", of: id) || config.isScreenLocked(screen.displayID))
        if collapsed { applyCollapsed(collapsed, expandedHeight: h, animate: false) }

        contentView = NSHostingView(rootView: PartitionView(config: config, id: id))
        setupTrackingArea()
        installDragMonitor()
    }

    deinit {
        if let m = dragMonitor { NSEvent.removeMonitor(m); dragMonitor = nil }
    }

    // MARK: - 拖出：窗口级鼠标监视器

    /// 本窗口唯一的鼠标监视器：把按下 / 拖动转发给光标下那一个 `FileDragSourceView`。
    ///
    /// 每个文件行各装一个监视器的写法见 `FileDragSourceView` 的类型注释 —— 那是 O(条目数)
    /// 的分发成本，这里收成一个。
    private var dragMonitor: Any?
    /// 本次按下命中的拖拽源：拖拽期间复用，免得每条 dragged 都遍历一次视图树。
    private weak var pendingDragSource: FileDragSourceView?

    private func installDragMonitor() {
        guard dragMonitor == nil else { return }
        dragMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self, event.window === self else { return event }
            switch event.type {
            case .leftMouseDown:
                self.pendingDragSource = self.dragSourceView(at: event.locationInWindow)
                return self.pendingDragSource?.handle(event) ?? event
            case .leftMouseDragged:
                // 返回 nil = 吞掉该事件：发起拖拽后，原来的那一次 dragged 不该再往下派发
                return self.pendingDragSource?.handle(event) ?? event
            case .leftMouseUp:
                self.pendingDragSource = nil
                return event
            default:
                return event
            }
        }
    }

    /// 找到窗口坐标 `pointInWindow` 下的那个拖拽源视图。
    ///
    /// ⚠️ 不能用 `hitTest`：`FileDragSourceView.hitTest` 恒返回 nil
    /// （否则会吃掉单击 / 双击 / 右键菜单），所以只能自己遍历视图树按 bounds 判。
    /// 只在 mouseDown 时走一次，随后缓存到 `pendingDragSource`。
    private func dragSourceView(at pointInWindow: NSPoint) -> FileDragSourceView? {
        guard let root = contentView else { return nil }
        return findDragSource(in: root, windowPoint: pointInWindow)
    }

    private func findDragSource(in view: NSView, windowPoint: NSPoint) -> FileDragSourceView? {
        if let d = view as? FileDragSourceView {
            // from: nil = 从窗口坐标换算到本视图本地坐标
            return view.bounds.contains(view.convert(windowPoint, from: nil)) ? d : nil
        }
        for sub in view.subviews {
            if let hit = findDragSource(in: sub, windowPoint: windowPoint) { return hit }
        }
        return nil
    }

    // borderless 窗口默认不能成为 key window；不放开的话 TextEditor 无法接收输入。
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// 置顶 / 取消置顶：只改这一个窗口的层级与跨桌面语义，内容不搬家、零闪烁。
    func applyPinned(_ on: Bool) {
        level = on ? .floating : .desktopLevel
        collectionBehavior = on
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.canJoinAllSpaces]
    }

    /// 动态提升为普通窗口层级（点击选中时同普通应用一样参与层级切换）
    func activateAsNormalWindow() {
        guard !config.bool("isAlwaysOnTop", of: partitionID) else { return }
        if level != .normal {
            level = .normal
        }
    }

    /// 降回桌面层级（失焦或用户点击外部应用/桌面时）
    func deactivateToDesktop() {
        guard !config.bool("isAlwaysOnTop", of: partitionID) else { return }
        if level != .desktopLevel {
            level = .desktopLevel
        }
    }

    /// 标题栏是否还能拖着窗口走（锁定时为 false）。
    ///
    /// 取代旧的 `isMovableByWindowBackground`：那个开关是**整窗**生效的，
    /// 一开就会抢走内容区的拖拽手势（详见 `init` 里的注释）。
    var canDragWindow = true

    /// 锁定：禁止拖动（锁定时分区只可交互内容，不可挪位）。
    func applyLocked(_ on: Bool) {
        canDragWindow = !on
        if on { moveArmed = false; isMovingWindow = false }
    }

    /// 折叠：窗口收窄到标题栏高度（44）；展开：恢复 `expandedHeight`。
    func applyCollapsed(_ collapsed: Bool, expandedHeight: CGFloat, animate: Bool = true) {
        let h = collapsed ? 44 : expandedHeight
        var f = frame
        // 折叠/展开时保持顶部对齐（AppKit 左下原点 → 保持 origin.y 不变会从底部收放，
        // 需按高度差上移 origin 以保持顶部不动）。
        let dy = frame.height - h
        f.origin.y += dy
        f.size.height = h
        if animate {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.20
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animator().setFrame(f, display: true)
            }
        } else {
            setFrame(f, display: true, animate: false)
        }
    }

    /// 缩放：直接设置尺寸（保持左上角不动 → origin.y 随高度差下移）。
    func setSize(width: CGFloat, height: CGFloat) {
        var f = frame
        let dy = f.height - height
        f.origin.y += dy
        f.size.width = width
        f.size.height = height
        setFrame(f, display: true, animate: false)
    }

    // MARK: - 8 向缩放（AppKit 窗口级处理，纯外边缘响应，不遮挡删除/折叠等内部按钮）

    enum ResizeEdge {
        case left, right, top, bottom
        case topLeft, topRight, bottomLeft, bottomRight

        var cursor: NSCursor {
            switch self {
            case .top, .bottom:
                return .resizeUpDown
            case .left, .right:
                return .resizeLeftRight
            case .topLeft, .bottomRight:
                return PartitionPanel.diagonalNWSE
            case .topRight, .bottomLeft:
                return PartitionPanel.diagonalNESW
            }
        }
    }

    private var isResizing = false
    private var currentResizeEdge: ResizeEdge?
    private var initialMouseScreenLocation = NSPoint.zero
    private var initialWindowFrame = NSRect.zero
    private var hasCustomCursor = false
    private var trackingArea: NSTrackingArea?

    // MARK: - 窗口拖动（只有标题栏这一条能拖）

    /// 按下点落在标题栏上（还没真的开始拖）。
    private var moveArmed = false
    private var isMovingWindow = false
    private var moveInitialScreen = NSPoint.zero    // 按下时的光标屏幕坐标（左下原点）
    private var moveInitialOrigin = NSPoint.zero    // 按下时的窗口 origin
    /// 越过多少距离才算「拖动」。
    ///
    /// ⚠️ 不能没有阈值：标题栏上排着 6 个按钮，手抖 1px 就把「点一下按钮」
    /// 判成「拖窗口」，按钮再也点不动。3pt 是肉眼察觉不到、又足以区分点击与拖拽的量。
    private let moveThreshold: CGFloat = 3

    /// 该点是否落在「可拖窗口」的标题栏条带上。
    ///
    /// 只用顶部 `Layout.headerHeight`（44pt）这一条 —— 内容区一律不拖，
    /// 否则会抢走分区内条目的拖拽（把文件拖出去）与便签的文本选择。
    /// 顶部 5pt / 两角 8pt 是缩放手柄，已被 `resizeEdge(for:)` 先行判定，这里不再重复排除。
    private func isInTitleBar(_ pt: NSPoint) -> Bool {
        guard let cv = contentView else { return false }
        let yFromTop = cv.bounds.height - pt.y
        return yFromTop >= 0 && yFromTop <= PartitionMetrics.headerHeight
    }

    /// 窗口坐标 → 屏幕坐标（AppKit 两边都是**左下原点**，直接相加即可）。
    private func screenPoint(of pt: NSPoint) -> NSPoint {
        NSPoint(x: frame.origin.x + pt.x, y: frame.origin.y + pt.y)
    }

    // MARK: - 拖拽时的实时尺寸提示

    /// 尺寸提示胶囊。放在 **`PartitionPanel` 这一层**（而不是分区内容里），所以
    /// 便签 / 图片 / 网格视图**一视同仁**都能显示 —— 内容怎么变都不影响它。
    /// 位置贴**右下角内侧**：类比「输入框右下角的字数统计」，视线自然，且不压住
    /// 正在拖动的边缘（四角手柄处看不到被自己手指/光标挡住的数字）。
    private let sizeHUD: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 6
        // ⚠️ 用**语义色**而不是写死的白/黑：分区底色随系统外观变化，
        // 写死一侧会在另一侧几乎看不见（这一步踩过：浅色下白 20% 只有 +3/255）。
        v.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        v.alphaValue = 0
        v.isHidden = true
        return v
    }()
    private let sizeHUDLabel: NSTextField = {
        let t = NSTextField(labelWithString: "")
        // 等宽数字：拖动时数字跳动但**胶囊宽度不抖**
        t.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        t.textColor = .labelColor
        t.alignment = .center
        t.lineBreakMode = .byClipping
        return t
    }()
    private var sizeHUDHideWork: DispatchWorkItem?

    static let diagonalNWSE: NSCursor = makeDiagonalCursor("arrow.up.left.and.arrow.down.right")
    static let diagonalNESW: NSCursor = makeDiagonalCursor("arrow.up.right.and.arrow.down.left")

    private static func makeDiagonalCursor(_ symbol: String) -> NSCursor {
        guard let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else {
            return .crosshair
        }
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let sized = img.withSymbolConfiguration(cfg) ?? img
        return NSCursor(image: sized, hotSpot: NSPoint(x: 6, y: 6))
    }

    private func setupTrackingArea() {
        if let old = trackingArea, let cv = contentView {
            cv.removeTrackingArea(old)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .cursorUpdate, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        contentView?.addTrackingArea(area)
        self.trackingArea = area
    }

    private func resizeEdge(for pt: NSPoint) -> ResizeEdge? {
        guard let cv = contentView else { return nil }
        let bounds = cv.bounds
        let w = bounds.width
        let h = bounds.height
        guard pt.x >= 0 && pt.x <= w && pt.y >= 0 && pt.y <= h else { return nil }

        // 四边判定厚度 5px，四角判定范围：
        // 顶部角落严格控制在 8px（右上角删除按钮在 x: w-26~w-12, y: h-29~h-15，留出充裕安全操作空间）
        let edge: CGFloat = 5
        let cornerTop: CGFloat = 8
        let cornerBottom: CGFloat = 14

        // 四角优先
        if pt.x <= cornerTop && pt.y >= h - cornerTop { return .topLeft }
        if pt.x >= w - cornerTop && pt.y >= h - cornerTop { return .topRight }
        if pt.x <= cornerBottom && pt.y <= cornerBottom { return .bottomLeft }
        if pt.x >= w - cornerBottom && pt.y <= cornerBottom { return .bottomRight }

        // 四边
        if pt.x <= edge { return .left }
        if pt.x >= w - edge { return .right }
        if pt.y <= edge { return .bottom }
        if pt.y >= h - edge { return .top }

        return nil
    }

    private var isTextInputActive: Bool {
        guard let responder = firstResponder else { return false }
        if let tv = responder as? NSTextView, tv.isEditable {
            return true
        }
        if responder is NSTextField {
            return true
        }
        return false
    }

    override func sendEvent(_ event: NSEvent) {
        // isLocked(partitionID) 内部已含「本屏全局锁 ‖ 分区锁」，无需再叠加全局开关
        let isLocked = AppDelegate.shared?.isLocked(partitionID) ?? false
        if isLocked {
            super.sendEvent(event)
            return
        }

        switch event.type {
        case .keyDown:
            // 文件列表的键盘意图（⌘A / ⌘⌫ / ⌘C、方向键、首字母跳转…）由 AppDelegate 统一裁决：
            // ⚠️ 正在编辑文本（如搜索框、便签、重命名文本框）时绝不拦截，避免打字被吃掉。
            // ⚠️ 只有当前分区确实是 portal 且不是文本输入时才处理。
            if !isTextInputActive,
               AppDelegate.shared?.handleFileKey(partitionID: partitionID, event: event) == true {
                return
            }
            super.sendEvent(event)

        case .mouseMoved:
            if isResizing {
                currentResizeEdge?.cursor.set()
            } else {
                let pt = event.locationInWindow
                if let edge = resizeEdge(for: pt) {
                    edge.cursor.set()
                    hasCustomCursor = true
                } else if hasCustomCursor {
                    NSCursor.arrow.set()
                    hasCustomCursor = false
                }
            }
            super.sendEvent(event)

        case .leftMouseDown:
            AppDelegate.shared?.activatePartition(self)
            let pt = event.locationInWindow
            if let edge = resizeEdge(for: pt) {
                // 双击边缘快捷操作：
                if event.clickCount == 2 {
                    if edge == .bottom {
                        // 双击底边：仅自适应高度，保持宽度不变（双击是显式操作 → 折叠时顺势展开）
                        AppDelegate.shared?.autoFitHeight(partitionID, resetWidth: false,
                                                          expandIfCollapsed: true)
                        return
                    } else if edge == .bottomRight {
                        // 双击右下角：自适应高度并初始化宽度（同上，折叠时顺势展开）
                        AppDelegate.shared?.autoFitHeight(partitionID, resetWidth: true,
                                                          expandIfCollapsed: true)
                        return
                    } else if edge == .right {
                        // 双击右边：仅初始化分区宽度，保持高度不变
                        AppDelegate.shared?.resetPartitionWidth(partitionID)
                        return
                    }
                }
                isResizing = true
                currentResizeEdge = edge
                initialMouseScreenLocation = NSEvent.mouseLocation
                initialWindowFrame = frame
                AppDelegate.shared?.setResizing(partitionID, active: true)
                edge.cursor.set()
                return
            }
            // 只有标题栏记下拖动起点。⚠️ **仍然要把事件投递给 SwiftUI**（不 return）：
            // 标题栏上的按钮 / 双击重命名靠这次 mouse-down 生效，只在真的「拖动」时才挪窗口。
            if canDragWindow && isInTitleBar(pt) {
                // 双击标题栏空白处：折叠 / 展开分区（避开左侧标题区域与右侧功能按钮区）
                if event.clickCount == 2 {
                    let rightButtonsWidth: CGFloat = 186
                    let isRightButtons = pt.x >= (frame.width - rightButtonsWidth)
                    let leftTitleWidth: CGFloat = 140
                    let isLeftTitle = pt.x <= leftTitleWidth
                    if !isRightButtons && !isLeftTitle {
                        if AppDelegate.shared?.blockedByLock(partitionID, action: "折叠") != true {
                            AppDelegate.shared?.toggleCollapse(partitionID)
                            return
                        }
                    }
                }
                moveArmed = true
                moveInitialScreen = screenPoint(of: pt)
                // ⚠️ 必须记录按下时的窗口 origin：拖动按「起点 → 当前」净位移挪窗口，
                // 若这里漏掉，moveInitialOrigin 恒为 (0,0)，越过阈值那一刻窗口会瞬间
                // 跳到屏幕原点再跟手 —— 表现为「拖动漂移 / 跳动」。
                moveInitialOrigin = frame.origin
            }
            super.sendEvent(event)

        case .rightMouseDown:
            // 右键时仅提升窗口层级以防被遮挡，绝不能在此执行 makeKey / NSApp.activate，
            // 否则会触发应用激活和 key 窗口焦点切换，打断刚刚建立的上下文菜单追踪循环（产生菜单闪现）。
            activateAsNormalWindow()
            orderFrontRegardless()
            super.sendEvent(event)

        case .otherMouseDown:
            // 鼠标侧键返回（buttonNumber == 3 是绝大多数 5 键鼠标的后退键）
            if event.buttonNumber == 3 {
                NotificationCenter.default.post(name: .portalNavigateParent, object: partitionID)
                return
            }
            super.sendEvent(event)

        case .leftMouseDragged:
            if isResizing, let edge = currentResizeEdge {
                edge.cursor.set()
                let curMouse = NSEvent.mouseLocation
                let dx = curMouse.x - initialMouseScreenLocation.x
                let dy = curMouse.y - initialMouseScreenLocation.y
                applyResize(edge: edge, dx: dx, dy: dy)
                return
            }
            if moveArmed {
                // ⚠️ 用「当前窗口 origin + 事件坐标」现算屏幕位置，而不是 `NSEvent.mouseLocation`：
                // 窗口一边被拖一边读全局光标，两套坐标系会互相污染；而且事件坐标是按
                // **当前**窗口位置给的，换算出来才是真实光标位置。
                let cur = screenPoint(of: event.locationInWindow)
                if !isMovingWindow {
                    let dx = cur.x - moveInitialScreen.x
                    let dy = cur.y - moveInitialScreen.y
                    // 没过阈值 → 当成点击，交给 SwiftUI（按钮 / 标题双击重命名要能生效）
                    guard dx * dx + dy * dy >= moveThreshold * moveThreshold else {
                        super.sendEvent(event)
                        return
                    }
                    isMovingWindow = true
                    // ⚠️ **不要**在越过阈值时重新起算基准：那样窗口会永久「落后」光标
                    // 首次事件的那段位移（拖得快时一次事件就是几十像素，手感像拖不动）。
                    // 用按下时的原始基准，窗口与光标保持恒定相对位置 —— 这才是系统拖窗的手感。
                }
                // 按「起点 → 当前」的净位移挪窗口：逐帧累加 delta 会在丢事件时漂移。
                var o = moveInitialOrigin
                o.x += cur.x - moveInitialScreen.x
                o.y += cur.y - moveInitialScreen.y
                // `setFrameOrigin` 会照常抛 `didMove` → 坐标落盘 + 停止 250ms 后吸附，
                // 与改之前 AppKit 原生窗口拖动的行为一致。
                setFrameOrigin(o)
                return
            }
            super.sendEvent(event)

        case .leftMouseUp:
            moveArmed = false
            isMovingWindow = false
            if isResizing {
                isResizing = false
                currentResizeEdge = nil
                AppDelegate.shared?.finishResize(partitionID)
                AppDelegate.shared?.setResizing(partitionID, active: false)
                let pt = event.locationInWindow
                if let edge = resizeEdge(for: pt) {
                    edge.cursor.set()
                    hasCustomCursor = true
                } else {
                    NSCursor.arrow.set()
                    hasCustomCursor = false
                }
                return
            }
            super.sendEvent(event)

        default:
            super.sendEvent(event)
        }
    }

    override func mouseExited(with event: NSEvent) {
        if !isResizing && hasCustomCursor {
            NSCursor.arrow.set()
            hasCustomCursor = false
        }
        super.mouseExited(with: event)
    }

    /// 显示当前宽高，并在停止拖动后自动淡出。
    ///
    /// ⚠️ 隐藏延迟用 `DispatchWorkItem` 而不是 `Timer`：拖拽期间 AppKit 跑的是
    /// **局部事件跟踪循环**，`Timer` 不会被及时触发（表现为「数字停在那儿不走」）。
    private func showSizeHUD(width: CGFloat, height: CGFloat) {
        guard let cv = contentView else { return }
        if sizeHUD.superview == nil {
            cv.addSubview(sizeHUD)
            sizeHUD.addSubview(sizeHUDLabel)
            // 保持「右下角」的相对位置：宽/高变化时自动跟随，不必每帧重算布局
            sizeHUD.autoresizingMask = [.minXMargin, .maxYMargin]
        }
        sizeHUDLabel.stringValue = "\(Int(round(width))) × \(Int(round(height)))"
        sizeHUDLabel.sizeToFit()

        let lw = sizeHUDLabel.frame.width, lh = sizeHUDLabel.frame.height
        // contentView 坐标系是**左下原点** ⇒ 「右下角」= x 靠右、y 靠下。
        // 落位交给 `SizeHUD.frame`（纯函数，已单测）——这里不再自己算，避免与测试分叉。
        sizeHUD.frame = SizeHUD.frame(contentWidth: cv.bounds.width, contentHeight: cv.bounds.height,
                                      labelWidth: lw, labelHeight: lh)
        sizeHUDLabel.frame = SizeHUD.labelFrame(labelWidth: lw, labelHeight: lh)

        sizeHUD.isHidden = false
        sizeHUD.layer?.removeAllAnimations()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.08
            sizeHUD.animator().alphaValue = 1
        }

        sizeHUDHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hideSizeHUD() }
        sizeHUDHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private func hideSizeHUD() {
        guard !sizeHUD.isHidden else { return }
        sizeHUD.layer?.removeAllAnimations()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            sizeHUD.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.sizeHUD.isHidden = true
        })
    }

    private func applyResize(edge: ResizeEdge, dx: CGFloat, dy: CGFloat) {
        let minW: CGFloat = 120
        // 拖边缩放的高度下限跟随「全局偏好 → 分区最小高度」（此前硬编码 64，
        // 于是设了 300 的用户照样能把分区拖到 64，设置形同虚设）。
        // 保留 64 这个渲染底线兜底：设置值异常小时也不会把内容区压没。
        let minH: CGFloat = max(64, AppDelegate.shared?.effectiveMinPartitionHeight(on: screen) ?? 64)
        var f = initialWindowFrame

        // 水平调整
        switch edge {
        case .left, .topLeft, .bottomLeft:
            let newW = max(minW, initialWindowFrame.width - dx)
            f.origin.x = initialWindowFrame.origin.x + (initialWindowFrame.width - newW)
            f.size.width = newW
        case .right, .topRight, .bottomRight:
            f.size.width = max(minW, initialWindowFrame.width + dx)
        default:
            break
        }

        // 垂直调整（Cocoa 左下原点：顶部变化改 height，底部变化改 origin.y 和 height）
        switch edge {
        case .top, .topLeft, .topRight:
            f.size.height = max(minH, initialWindowFrame.height + dy)
        case .bottom, .bottomLeft, .bottomRight:
            let newH = max(minH, initialWindowFrame.height - dy)
            f.origin.y = initialWindowFrame.origin.y + (initialWindowFrame.height - newH)
            f.size.height = newH
        default:
            break
        }

        setFrame(f, display: true, animate: false)

        let scr = self.screen ?? NSScreen.main ?? NSScreen.screens.first!
        let topY = scr.frame.origin.y + scr.frame.height - f.origin.y - f.height
        let relX = f.origin.x - scr.frame.origin.x
        AppDelegate.shared?.updatePartitionFrameQuiet(partitionID, x: relX, y: topY, width: f.width, height: f.height)
        showSizeHUD(width: f.width, height: f.height)
    }
}

/// 桌面层：贴壁纸之上、普通窗口之下（桌面挂件的标准语义）。
extension NSWindow.Level {
    static let desktopLevel: NSWindow.Level = {
        let v = CGWindowLevelForKey(.desktopIconWindow)
        // 比桌面图标层略高，保证分区压在桌面图标之上，但仍在所有普通窗口之下。
        return NSWindow.Level(rawValue: Int(v) + 1)
    }()
}
