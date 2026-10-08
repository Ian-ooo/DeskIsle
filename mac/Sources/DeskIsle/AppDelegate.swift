import AppKit
import ApplicationServices
import Carbon
import SwiftUI
import ServiceManagement
import DeskIsleCore
import DeskIsleLayout

extension Notification.Name {
    static let portalFolderChanged = Notification.Name("DeskIsle.portalFolderChanged")
    /// 让某个分区的文件列表**全选**（⌘A）。object = 分区 id。
    static let portalSelectAll = Notification.Name("DeskIsle.portalSelectAll")
    /// 清空某个分区的选中（Esc）。object = 分区 id。
    static let portalClearSelection = Notification.Name("DeskIsle.portalClearSelection")
    /// 请求某个分区给「唯一选中项」弹重命名框（Enter）。object = 分区 id。
    static let portalRequestRename = Notification.Name("DeskIsle.portalRequestRename")
    /// 「活跃分区」变了 —— 选区的作用域。object = 活跃分区 id；
    /// **点到分区之外时为 nil**（此时所有分区的选区一律失效）。
    /// 判据见 `FileSelectionScope.shouldClear`，各分区自己决定要不要清。
    static let portalActivePartitionChanged = Notification.Name("DeskIsle.portalActivePartitionChanged")
    /// 映射文件夹首字母/按键即时跳转定位（Type-to-Select）。object = 分区 id, userInfo = ["char": String]
    static let portalQuickSelect = Notification.Name("DeskIsle.portalQuickSelect")
    /// 映射文件夹方向键导航。object = 分区 id, userInfo = ["direction": String, "shift": Bool]
    static let portalArrowNavigate = Notification.Name("DeskIsle.portalArrowNavigate")
    /// 映射文件夹深度键盘流：返回上一层目录（⌘↑ 或 鼠标侧键）。object = 分区 id
    static let portalNavigateParent = Notification.Name("DeskIsle.portalNavigateParent")
    /// 映射文件夹深度键盘流：下钻进入选中文件夹/打开（⌘↓ 或 ⌘O）。object = 分区 id
    static let portalEnterSelected = Notification.Name("DeskIsle.portalEnterSelected")
}

// 排版基准 `Layout`、尺寸口径 `PartitionMetrics`、坐标解算 `LayoutEngine`
// 均位于 LayoutEngine.swift —— 三端共享的数值只在一处定义。

extension NSScreen {
    /// 稳定的显示器标识。多显示器下用它把顶栏与分区归属到具体屏幕，
    /// 避免用 `NSScreen.main`（随焦点漂移）或数组下标（插拔后错位）判定。
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

/// 视图型托盘菜单项：点击不会关闭 NSMenu（实现「保持托盘菜单不收起、可连续编辑」）。
/// 自绘标题 + 左侧勾选标记 + hover 高亮，外观对齐原生菜单项。
final class ToggleMenuItemView: NSView {
    private let title: String
    private var hovering = false { didSet { needsDisplay = true } }

    /// 勾选态，set 后自动重绘。
    var isOn: Bool = false { didSet { needsDisplay = true } }
    /// 点击回调。
    var onToggle: (() -> Void)?

    init(title: String, isOn: Bool, onToggle: @escaping () -> Void) {
        self.title = title
        self.isOn = isOn
        self.onToggle = onToggle
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        wantsLayer = true
        // 菜单比 view 宽时自动拉伸填满，保证勾选标记始终贴菜单右缘
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        let fg: NSColor = hovering ? .white : .labelColor
        // 勾选标记画在右侧（不占左侧列，保证标题与原生菜单项左对齐）
        if isOn, let check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(hierarchicalColor: fg)) {
            check.draw(in: NSRect(x: bounds.width - 20, y: (bounds.height - 11) / 2, width: 11, height: 11))
        }
        // 标题左缘 15pt：与原生菜单项文字左缘对齐（实测校准值，原生项 ≈ 菜单左缘 +16pt）
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: fg
        ]
        (title as NSString).draw(at: NSPoint(x: 15, y: (bounds.height - 16) / 2), withAttributes: attrs)
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {
        // 视图型菜单项不会因点击关闭菜单；在 mouseDown 触发，保证可靠单次触发
        onToggle?()
    }

    /// 吞掉 mouseUp（不调 super）：
    /// 显式 `menu.popUp(...)` 的菜单跟踪循环若收到 mouseUp，会把这一项判定为「已选中」并收起菜单；
    /// 不向上传递即可让菜单保持打开 —— 与 `statusItem.menu` 模式下的行为一致，
    /// 实现「切换类项可连续点击、菜单不收起」。
    override func mouseUp(with event: NSEvent) {
        // 有意不调用 super
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static weak var shared: AppDelegate?

    let config: Config
    private var panels: [PartitionPanel] = []
    /// 每台显示器一个顶栏实例（键 = CGDirectDisplayID）。
    /// 多屏下各屏顶栏只控制本屏分区（显隐 / 对齐 / 新建），互不干扰。
    private var topBars: [CGDirectDisplayID: TopBarPanel] = [:]
    private var statusItem: NSStatusItem?
    /// 状态栏菜单（不用 `statusItem.menu`，改由 `statusButtonClicked` 显式定位弹出）
    private var statusMenu: NSMenu?
    private var globalMouse: Any?
    private var localMouse: Any?
    private var hotKeyRef: EventHotKeyRef?
    /// 搜索快捷键的独立注册引用（与显示/隐藏热键分开，见 `installSearchHotkey`）
    private var searchHotKeyRef: EventHotKeyRef?
    private var saveWork: DispatchWorkItem?
    private var snapWork: DispatchWorkItem?
    /// hover 展开（hoverPeek）进行中：抑制 didMove 的写配置/吸附/保存副作用。
    private var isHoverPeeking = false
    /// 程序性重排（align / realign / ensurePartitionsInBounds）正在移动窗口。
    /// 这类移动不是用户拖动，不应触发「拖动停止后吸附」——否则吸附会用另一套基准
    /// 把刚排好的坐标改写偏（新建分区间隔偏小即由此而来）。
    private var isProgrammaticMove = false
    /// 托盘菜单的视图型切换项引用（菜单打开时同步勾选态）。
    private var hidePartitionView: ToggleMenuItemView?
    private var lockView: ToggleMenuItemView?
    private var alignViews: [String: ToggleMenuItemView] = [:]
    private var topBarView: ToggleMenuItemView?
    /// 「布局预设」子菜单：条目按光标所在屏动态重建（预设是按屏的，且会增删）
    private var layoutPresetMenu: NSMenu?

    override init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/deskisle")
        self.config = Config(url: dir.appendingPathComponent("deskisle_config.json"))
        super.init()
        AppDelegate.shared = self
    }

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 系统默认的 tooltip 延迟是 1500ms —— 悬停后要「定住」一秒半才出提示，
        // 体感就是「没有提示」（实测 1503ms）。收到 450ms（实测 457ms）：
        // 换到另一个提示区会重置计时，所以扫过一排图标仍不会乱闪，但停一下就能看到。
        // 用 register 而非 set：只填「用户没设过」的空位 —— 用户自己改过就尊重用户的设置。
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 450])

        config.load()
        // 徽标要数「用户当前看到的那个目录」：视图与徽标必须同源，否则一进子目录
        // 就会出现「上面写 10、下面列 3 个」。浏览路径只活在 AppDelegate 里，故在此注入。
        // ⚠️ 必须在 rebuild() **之前**接好：面板一建出来就会渲染第一帧的徽标，
        // 那时若还没注入，徽标会退回「配置里的根目录」去数。
        config.portalCountPath = { [weak self] id in
            self?.effectiveBrowsePath(id) ?? ""
        }
        // 配置结构升级过（或首次运行）就立刻落盘一次，把版本号写进文件。
        // 放在 rebuild 之前：后续所有读取都以补齐后的结构为准。
        if config.didMigrate { config.save() }
        rebuild()
        setupStatusItem()
        startMouseMonitors()
        registerHotkey()
        startFolderWatching()
        startConfigWatching()
        startScreenObservation()
        ensurePartitionsInBounds()
        NotificationCenter.default.addObserver(self, selector: #selector(appDidResignActive),
                                               name: NSApplication.didResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
        applyToolTipPolicy()
        showAll()
    }

    // MARK: - 悬停提示策略

    /// 重新下发「应用在后台也显示 tooltip」策略。
    ///
    /// 两个面板的 `init` 里已经设过；这里补一次是因为 Apple 注明：
    /// **该属性的改动要到窗口下一次 active 状态变化才生效**，
    /// 所以在应用激活 / 退活这两个时点各补一次，保证切换后策略确实吃到。
    func applyToolTipPolicy() {
        for p in panels { p.allowsToolTipsWhenApplicationIsInactive = true }
        for (_, tb) in topBars { tb.allowsToolTipsWhenApplicationIsInactive = true }
    }

    @objc private func appDidBecomeActive() {
        applyToolTipPolicy()
        if AXIsProcessTrusted() {
            if globalMouse != nil { stopCursorFallbackPoll() }
        } else {
            startCursorFallbackPoll()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveNow()
        stopFolderWatching()
        stopConfigWatching()
    }

    // MARK: - 多显示器

    /// 参考屏幕：第一个分区所在的屏幕，否则主屏。
    /// 单显示器环境下永远等于主屏；多显示器下分区跟随其所在屏幕。
    func referenceScreen() -> NSScreen {
        if let s = panels.first?.screen { return s }
        // 多显示器下 NSScreen.main 会随按键焦点漂移，导致分区每次启动
        // 随机落到另一个屏；优先取「光标所在屏幕」（用户正在看的屏）。
        if let s = screenUnderCursor() { return s }
        return NSScreen.main ?? NSScreen.screens.first!
    }

    /// 光标当前所在的屏幕 —— 交互发生的屏。
    /// 多显示器下「点击显示器 A 却在 B 弹出面板」的根因就是没用它：
    /// 任何用户触发的弹窗/新建/显隐都必须以这个屏为准。
    func screenUnderCursor() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
    }

    /// 交互目标屏：优先光标所在屏，取不到时退回参考屏。
    func activeScreen() -> NSScreen {
        screenUnderCursor() ?? referenceScreen()
    }

    /// 归属于指定显示器的分区（以窗口当前所在屏为准，支持用户手动拖到另一屏）。
    func panels(on screen: NSScreen) -> [PartitionPanel] {
        let sid = screen.displayID
        return panels.filter { ($0.screen?.displayID ?? config.screenId(of: $0.partitionID) ?? 0) == sid }
    }

    /// 指定显示器上的分区 ID（按配置顺序）。
    func partitionIDs(on screen: NSScreen) -> [String] {
        panels(on: screen).map { $0.partitionID }
    }

    /// 把「屏幕相对坐标（左上原点）」换算成 AppKit 全局 frame 原点。
    private func nativeOrigin(_ screen: NSScreen, x: CGFloat, y: CGFloat, h: CGFloat) -> NSPoint {
        NSPoint(x: screen.frame.origin.x + x,
                y: screen.frame.origin.y + screen.frame.height - y - h)
    }

    /// 依据是否显示顶栏计算视觉顶部边距：
    /// 顶栏顶部离顶端固定 topInset (40pt)，顶栏高度 44pt，
    /// 导航栏底部与顶层分区顶部距离为 16pt。
    func visualTopMargin(for screen: NSScreen) -> CGFloat {
        // 顶栏显隐**按屏独立**：某屏没顶栏时，该屏分区的上边距回到 24
        guard config.showTopBar(forScreen: screen.displayID) else { return 24 }
        let bottomGap: CGFloat = 16.0
        return TopBarPanel.topInset + TopBarPanel.height + bottomGap
    }

    // MARK: - 窗口构建

    /// 分区窗口的两个窗口级监听：移动（写回坐标）与失去 key（收回临时提升）。
    private func addPanelObservers(_ panel: PartitionPanel) {
        NotificationCenter.default.addObserver(self, selector: #selector(panelDidMove(_:)),
                                               name: NSWindow.didMoveNotification, object: panel)
        NotificationCenter.default.addObserver(self, selector: #selector(panelDidResignKey(_:)),
                                               name: NSWindow.didResignKeyNotification, object: panel)
    }

    private func removePanelObservers(_ panel: PartitionPanel) {
        NotificationCenter.default.removeObserver(self, name: NSWindow.didMoveNotification, object: panel)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: panel)
    }

    func rebuild() {
        for p in panels { removePanelObservers(p); p.close() }
        panels.removeAll()
        for (_, tb) in topBars { tb.close() }
        topBars.removeAll()

        let fallback = referenceScreen()

        for p in config.partitions {
            guard let id = p["id"] as? String else { continue }
            // 分区优先回到它自己所属的显示器（配置里的 screenId）；
            // 找不到（显示器已拔掉 / 旧配置无该字段）时回退到参考屏。
            let targetScreen = config.screenId(of: id).flatMap { self.screen(id: $0) } ?? fallback
            let panel = PartitionPanel(config: config, id: id, screen: targetScreen)
            panels.append(panel)
            addPanelObservers(panel)
        }

        migrateScreenOwnership()
        rebuildTopBars()
    }

    /// 旧配置迁移：为缺少 `screenId` 的分区补上「它当前所在显示器」的标识。
    /// 只在首次升级后执行一次（补完即不再触发）。
    private func migrateScreenOwnership() {
        guard panels.contains(where: { config.screenId(of: $0.partitionID) == nil }) else { return }
        config.updateQuiet { raw in
            guard var parts = raw["partitions"] as? [[String: Any]] else { return }
            for i in 0..<parts.count {
                guard let id = parts[i]["id"] as? String, parts[i]["screenId"] == nil else { continue }
                if let scr = self.panels.first(where: { $0.partitionID == id })?.screen {
                    parts[i]["screenId"] = Int(scr.displayID)
                }
            }
            raw["partitions"] = parts
        }
        saveSoon(0.5)
    }

    /// 按当前显示器集合重建顶栏：**每台显示器一个**，各自只控制本屏分区。
    private func rebuildTopBars() {
        for (_, tb) in topBars { tb.close() }
        topBars.removeAll()
        // 每块显示器按其自身的显隐设置决定是否创建顶栏
        for screen in NSScreen.screens where config.showTopBar(forScreen: screen.displayID) {
            topBars[screen.displayID] = makeTopBar(for: screen)
        }
    }

    /// 用「屏幕 ID」而非 NSScreen 实例做闭包捕获：显示器插拔后旧实例会失效，
    /// 回调时按 ID 重新查找当前有效的屏幕。
    private func makeTopBar(for screen: NSScreen) -> TopBarPanel {
        let sid = screen.displayID
        return TopBarPanel(screen: screen, hasPinned: config.hasPinned, config: config,
                           onToggleHide: { [weak self] in self?.toggleGhost(onScreenID: sid) },
                           onAlign: { [weak self] in self?.align(mode: $0, onScreenID: sid) },
                           onAdd: { [weak self] in self?.addPartition(onScreenID: sid) },
                           onSettings: { [weak self] in self?.openGlobalSettings() },
                           onHideTopBar: { [weak self] in self?.setTopBarVisible(false, onScreenID: sid) },
                           onQuit: { NSApp.terminate(nil) })
    }

    /// 按显示器 ID 取回当前有效的 NSScreen。
    func screen(id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == id }
    }

    /// 解析目标屏幕：显式传入的 ID 优先，否则用光标所在屏。
    func resolvedScreen(_ id: CGDirectDisplayID?) -> NSScreen {
        if let id, let s = screen(id: id) { return s }
        return activeScreen()
    }

    func showAll() {
        // 尊重各屏独立的显隐态：隐藏中的屏幕不唤出分区
        for p in panels where !config.isScreenHidden(p.screen?.displayID ?? 0) {
            p.orderFrontRegardless()
        }
        for (_, tb) in topBars { tb.orderFrontRegardless() }
        refreshHitTest()
    }

    // MARK: - 托盘

    private func setupStatusItem() {
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "DeskIsle")
        let menu = NSMenu()

        // 品牌标牌（disabled，仅作视觉标牌，对齐 Electron 托盘第一项）
        let brand = NSMenuItem(title: "DeskIsle 桌岛", action: nil, keyEquivalent: "")
        brand.isEnabled = false
        menu.addItem(brand)
        menu.addItem(.separator())

        // 1. 新建分区 / 全局搜索
        menu.addItem(item("新建分区...", #selector(addMenu)))
        menu.addItem(item("全局搜索...　\(searchShortcut.display)", #selector(menuSearch)))

        menu.addItem(.separator())

        // 2. 显示 / 隐藏分区（视图型：点击不收起菜单）
        // 显隐项作用于**光标所在屏**（多显示器下每屏独立），勾选态反映该屏当前状态
        let hideView = ToggleMenuItemView(title: "显示 / 隐藏分区",
                                          isOn: !config.isScreenHidden(activeScreen().displayID)) { [weak self] in
            self?.toggleGhost()
            self?.syncStickyViews()
        }
        hidePartitionView = hideView
        let hideItem = NSMenuItem()
        hideItem.view = hideView
        menu.addItem(hideItem)

        // 3. 锁定分区位置（视图型：点击不收起菜单，标签固定不变）
        let lockView = ToggleMenuItemView(title: "锁定分区位置", isOn: isLayoutLocked) { [weak self] in
            self?.toggleLock()
            self?.syncStickyViews()
        }
        self.lockView = lockView
        let lockItem = NSMenuItem()
        lockItem.view = lockView
        menu.addItem(lockItem)

        // 4. 分区排版对齐（子菜单：四个对齐为视图型点击不收起；重新对齐/自适应为执行型）
        let align = NSMenuItem(title: "分区排版对齐", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let modes: [(String, String)] = [("top", "顶部横向排序"), ("left", "左侧纵向对齐"),
                                         ("right", "右侧纵向对齐"), ("grid", "网格平铺自适应")]
        for (mode, label) in modes {
            let v = ToggleMenuItemView(title: label, isOn: alignMode == mode) { [weak self] in
                self?.align(mode: mode)
                self?.syncStickyViews()
            }
            alignViews[mode] = v
            let it = NSMenuItem()
            it.view = v
            sub.addItem(it)
        }
        sub.addItem(.separator())
        sub.addItem(item("重新对齐分区", #selector(menuRealign(_:))))
        sub.addItem(item("所有分区自适应高度", #selector(menuAutoFitAll(_:))))
        align.submenu = sub
        menu.addItem(align)

        // 4b. 布局预设（子菜单条目在 menuNeedsUpdate 里按**光标所在屏**动态重建）
        let presetRoot = NSMenuItem(title: "布局预设", action: nil, keyEquivalent: "")
        let presetMenu = NSMenu()
        presetMenu.delegate = self
        presetRoot.submenu = presetMenu
        layoutPresetMenu = presetMenu
        menu.addItem(presetRoot)

        // 5. 显示顶部导航栏（视图型：点击不收起菜单；**只切换光标所在屏**的顶栏）
        let topBarView = ToggleMenuItemView(
            title: "显示顶部导航栏",
            isOn: config.showTopBar(forScreen: activeScreen().displayID)
        ) { [weak self] in
            guard let self else { return }
            let sid = self.activeScreen().displayID
            self.setTopBarVisible(!self.config.showTopBar(forScreen: sid), onScreenID: sid)
            self.syncStickyViews()
        }
        self.topBarView = topBarView
        let topBarItem = NSMenuItem()
        topBarItem.view = topBarView
        menu.addItem(topBarItem)
        menu.addItem(.separator())

        // 6. 全局设置与备份
        menu.addItem(item("全局设置与备份...", #selector(openGlobalSettingsMenu)))
        menu.addItem(.separator())

        // 7. 退出 DeskIsle
        menu.addItem(item("退出 DeskIsle", #selector(quit)))
        menu.delegate = self
        // ⚠️ 多显示器下**不能**用 `status.menu = menu`：菜单由 AppKit 自行定位，
        // 在「先点过另一块屏」之后可能把菜单弹到那块屏上（实测：点 A 屏图标却弹在 B 屏）。
        // 改为自定义弹出，并以**状态栏按钮本身**为参照定位，菜单必定出现在图标所在菜单栏下方。
        self.statusMenu = menu
        status.button?.target = self
        status.button?.action = #selector(statusButtonClicked(_:))
        status.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = status
    }

    /// 点击菜单栏图标：同步勾选态后，按**光标所在屏**定位弹出菜单（多显示器锁定到被点的那块屏）。
    @objc private func statusButtonClicked(_ sender: NSStatusBarButton) {
        guard let menu = statusMenu else { return }
        syncStickyViews()
        NSApp.activate(ignoringOtherApps: true)
        // ⚠️ 多显示器下**不能**用 `sender.window` 定位：
        // 状态栏按钮的窗口属于「当前活跃屏」，点另一块屏的图标会先触发活跃屏切换，
        // 而本回调执行时窗口还没搬过去（实测日志：鼠标已在 B 屏 x=2792，窗口坐标仍是 A 屏的 853），
        // 于是菜单被算到上一块屏上 —— 这就是「点 B 屏图标却弹在 A 屏/干脆不弹」的根因。
        // 改为以**光标所在屏**的菜单栏为基准、在屏幕坐标系中定位。
        let anchor = menuAnchorPoint(for: sender)
        menu.popUp(positioning: nil, at: anchor, in: nil)
        // 兜底：若 mouseUp 被菜单跟踪循环吃掉，按钮可能残留「选中」高亮态，手动清掉。
        sender.highlight(false)
    }

    /// 状态栏菜单锚点（**屏幕坐标系**，左下原点）。
    ///
    /// 以**光标所在屏**为准，不依赖状态栏按钮窗口的坐标 —— 多显示器下点击另一块屏的图标时，
    /// 该窗口仍停留在上一块屏（系统先切活跃屏，回调早于窗口搬运），用它会算到错误的屏上。
    private func menuAnchorPoint(for sender: NSStatusBarButton) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        // 点击刚发生，光标必然落在被点的图标上 → 光标所在屏就是用户要操作的那块屏
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? activeScreen()
        // x：状态项左缘（原生菜单与状态项左对齐），由图标宽度反推光标下的图标左缘
        let iconWidth = sender.bounds.width > 0 ? sender.bounds.width : 24
        var x = mouse.x - iconWidth / 2
        // 兜底：菜单（≈200pt 宽）整体不越出本屏
        let menuWidth: CGFloat = 200
        x = min(x, screen.frame.maxX - menuWidth - 8)
        x = max(x, screen.frame.minX + 8)
        // y：菜单栏下沿再下移 6pt，使菜单紧贴菜单栏底部
        return NSPoint(x: x, y: screen.visibleFrame.maxY - 6)
    }

    @objc private func addMenu() { addPartition() }
    @objc private func menuSearch() { openGlobalSearch() }
    @objc private func openGlobalSettingsMenu() { openGlobalSettings() }
    @objc private func quit() { saveNow(); NSApp.terminate(nil) }
    @objc private func menuAutoFitAll(_ s: NSMenuItem) { autoFitAll() }

    /// 光标所在显示器的对齐模式（托盘菜单高亮、快捷键等全局入口以此为准）。
    /// 多显示器下对齐模式**按屏独立**，见 `Config.alignMode(forScreen:)`。
    private var alignMode: String { config.alignMode(forScreen: activeScreen().displayID) }
    /// 光标所在显示器的「锁定分区位置」状态（托盘菜单以此为准，多屏独立）。
    private var isLayoutLocked: Bool { config.isScreenLocked(activeScreen().displayID) }

    /// 把视图型切换项的勾选态与 config 对齐（菜单打开前 + 每次切换后调用）。
    /// 一律按**光标所在屏**取值 —— 除「全局设置与备份」外，所有操作都是按屏的。
    private func syncStickyViews() {
        let sid = activeScreen().displayID
        hidePartitionView?.isOn = !config.isScreenHidden(sid)
        lockView?.isOn = config.isScreenLocked(sid)
        for (mode, v) in alignViews { v.isOn = (config.alignMode(forScreen: sid) == mode) }
        topBarView?.isOn = config.showTopBar(forScreen: sid)
    }

    /// 菜单打开前同步勾选态（NSMenuDelegate），并按当前屏重建「布局预设」子菜单。
    func menuNeedsUpdate(_ menu: NSMenu) {
        syncStickyViews()
        if menu === layoutPresetMenu { rebuildLayoutPresetMenu(menu) }
    }

    /// 重建「布局预设」子菜单。
    ///
    /// 每次打开都重建而不是启动时一次建好：预设是**按屏**的，而菜单归属的屏幕取决于
    /// 用户点了哪块屏的图标（光标所在屏），启动时根本不知道。条目数量也随增删变化。
    private func rebuildLayoutPresetMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let sid = activeScreen().displayID
        let presets = config.layoutPresets(forScreen: sid)

        if presets.isEmpty {
            let empty = NSMenuItem(title: "（本屏暂无预设）", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let fmt = DateFormatter()
            fmt.dateFormat = "MM-dd HH:mm"
            for p in presets {
                let label = "\(p.name)　·　\(p.entries.count) 个分区　·　\(fmt.string(from: p.savedAt))"
                menu.addItem(item(label, #selector(menuApplyPreset(_:)), p.key))
            }
            menu.addItem(.separator())
            // 删除项放二级菜单，避免主菜单被「预设 × 删除」撑成两倍长
            let delRoot = NSMenuItem(title: "删除预设", action: nil, keyEquivalent: "")
            let delMenu = NSMenu()
            for p in presets {
                delMenu.addItem(item(p.name, #selector(menuDeletePreset(_:)), p.key))
            }
            delRoot.submenu = delMenu
            menu.addItem(delRoot)
            menu.addItem(.separator())
        }
        menu.addItem(item("保存当前布局为预设...", #selector(menuSavePreset(_:))))
    }

    @objc private func menuSavePreset(_ s: NSMenuItem) {
        let sid = activeScreen().displayID
        let alert = NSAlert()
        alert.messageText = "保存当前布局为预设"
        alert.informativeText = "记录这块显示器上所有分区的位置与尺寸，以及当前的对齐方式。\n同名的预设会被覆盖。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "如：工作 / 阅读 / 演示"
        let existing = config.layoutPresets(forScreen: sid)
        field.stringValue = existing.first?.name ?? "布局 \(existing.count + 1)"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard runAlert(alert, on: activeScreen()) == .alertFirstButtonReturn else { return }
        if saveLayoutPreset(named: field.stringValue, onScreenID: sid) == nil {
            NSLog("[DeskIsle] 布局预设保存失败：名称为空或本屏没有分区")
        }
    }

    @objc private func menuApplyPreset(_ s: NSMenuItem) {
        guard let key = s.representedObject as? String,
              let preset = config.allLayoutPresets.first(where: { $0.key == key }) else { return }
        applyLayoutPreset(preset)
    }

    @objc private func menuDeletePreset(_ s: NSMenuItem) {
        guard let key = s.representedObject as? String,
              let preset = config.allLayoutPresets.first(where: { $0.key == key }) else { return }
        deleteLayoutPreset(preset)
    }

    // MARK: - 菜单项辅助

    private func item(_ title: String, _ sel: Selector, _ id: String? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        i.representedObject = id
        return i
    }

    @objc private func menuRealign(_ s: NSMenuItem) { realign() }

    func setViewMode(_ id: String, _ mode: String) {
        // 刻意**不**做锁定拦截：视图/排序属于「分区内容区的日常使用」，
        // 与标题栏那排功能图标不是一类东西。见 blockedByLock 的说明。
        config.updateUI { raw in
            guard var parts = raw["partitions"] as? [[String: Any]],
                  let i = parts.firstIndex(where: { ($0["id"] as? String) == id }) else { return }
            parts[i]["viewMode"] = mode
            raw["partitions"] = parts
        }
        // 两种视图的行高差好几倍（网格 tile 74 / 列表 28），切过去不重算高度的话，
        // 用户看到的是「切完要么被裁掉大半、要么底下空一大截」——还得再手动点一次自适应。
        // 这里只调高度、保留用户拖好的宽度（同「所有分区自适应高度」的口径）。
        // ⚠️ 锁定的分区跳过重算：本函数刻意不拦锁定（视图属于日常使用），
        // 若照常调 autoFitHeight 会被 blockedByLock 弹一次「自适应高度」提示，很突兀。
        if !isLocked(id) { autoFitHeight(id, resetWidth: false) }
        saveSoon(0.2)
    }

    /// 「锁定分区位置」：只作用于**指定显示器**上的分区（默认 = 光标所在屏）。
    /// 多显示器下每屏独立锁定，互不影响。
    func toggleLock(onScreenID sid: CGDirectDisplayID? = nil) {
        let scr = resolvedScreen(sid)
        let target = scr.displayID
        let locked = !config.isScreenLocked(target)
        config.setScreenLocked(target, locked)
        applyLock(locked, to: scr)
        saveSoon(0.2)
    }

    /// 把「锁定分区位置」状态应用到指定显示器上的全部分区（叠加分区自身的 isLocked）。
    private func applyLock(_ locked: Bool, to screen: NSScreen) {
        for p in panels(on: screen) {
            p.applyLocked(locked || config.bool("isLocked", of: p.partitionID))
        }
        refreshHitTest()
    }

    /// 显示 / 隐藏**指定显示器**的顶部导航栏（默认 = 光标所在屏）。
    /// 每屏的顶栏独立存在或销毁，其他显示器的顶栏不受影响。
    func setTopBarVisible(_ visible: Bool, onScreenID sid: CGDirectDisplayID? = nil) {
        let scr = resolvedScreen(sid)
        let target = scr.displayID
        config.setShowTopBar(visible, forScreen: target)

        if visible {
            if topBars[target] == nil { topBars[target] = makeTopBar(for: scr) }
            topBars[target]?.orderFrontRegardless()
        } else {
            topBars[target]?.close()
            topBars.removeValue(forKey: target)
        }
        // 顶栏占位变化会影响可用上边距，顺带纠正越界
        ensurePartitionsInBounds()
        refreshHitTest()
        saveSoon(0.2)
    }

    private func alignTop() { align(mode: "top") }
    private func alignLeft() { align(mode: "left") }
    private func alignRight() { align(mode: "right") }
    private func alignGrid() { align(mode: "grid") }

    /// 分区对齐（对齐 Electron 的 alignPartitions）：
    /// top=顶部横向、left=左侧纵向、right=右侧纵向、grid=网格平铺。
    /// 只调整位置（x/y），不改变任何分区的宽高。
    /// **只重排指定显示器上的分区**（默认 = 光标所在屏），其他屏的分区完全不受影响。
    func align(mode: String, onScreenID sid: CGDirectDisplayID? = nil) {
        let screen = resolvedScreen(sid)
        // 真实视觉等距对称：顶层分区距离导航栏底部的可见间隙 = 导航栏距离菜单栏下沿的可见间隙
        let top: CGFloat = visualTopMargin(for: screen)
        let sw = screen.frame.width
        let sh = screen.frame.height

        // 读序怎么定、为什么 left/right 必须互为镜像、`top` 为何要脱离几何 ——
        // 这些踩坑注释已随逻辑一起搬进 `LayoutEngine.alignPlacements`（纯函数，
        // 于是它能被单测与跨端对拍覆盖；原先写在这里时 executable target 无法被测试导入）。
        // 本方法只剩一件事：把配置翻译成输入项。
        //
        // 仅取本屏分区：多显示器下各屏独立排版。
        let items = panels(on: screen).map { p -> LayoutEngine.AlignItem in
            let id = p.partitionID
            return LayoutEngine.AlignItem(
                id: id,
                x: config.num("x", of: id),
                y: config.num("y", of: id),
                width: config.num("width", of: id),
                height: config.num("height", of: id),
                isCollapsed: config.bool("isCollapsed", of: id),
                index: config.index(of: id) ?? 0)
        }

        // 坐标解算交给纯函数（LayoutEngine）—— 既可单测，也保证与拖动吸附共用同一套基准
        let placements = LayoutEngine.alignPlacements(
            items: items, mode: mode,
            screenWidth: Double(sw), screenHeight: Double(sh), top: Double(top),
            maxColumns: config.maxColumns,
            defaultWidth: Double(defaultPartitionWidth),
            topHeightOrder: config.topHeightOrder)

        let coords: [(id: String, x: Double, y: Double, w: Double, h: Double)] = placements.map {
            (id: $0.id, x: $0.x, y: $0.y, w: $0.width, h: $0.height)
        }
        applyPlacements(coords, on: screen, alignMode: mode)
    }

    /// 把一批「屏幕相对坐标」同时落到配置与真实窗口上。
    ///
    /// `align(mode:)` 与「应用布局预设」共用这一段：折叠高度怎么算、程序化移动标志何时置位、
    /// 「坐标没变就跳过 setFrame」这些细节，若两条路径各写一份，迟早会漂移出
    /// 「点对齐时窗口抖一下」「折叠分区在预设里高度算错」这类只出现在某一条路径上的怪问题。
    ///
    /// - Parameter alignMode: 非 nil 时记录为**该屏**的对齐模式。预设应用时传预设里存的那个，
    ///   否则顶栏高亮态会与实际布局不符。
    private func applyPlacements(_ coords: [(id: String, x: Double, y: Double, w: Double, h: Double)],
                                 on screen: NSScreen,
                                 alignMode: String? = nil) {
        guard !coords.isEmpty else { return }

        // 记录**本屏**的对齐模式（多显示器下每屏独立设置；全局 alignMode 同步更新作为默认值）
        if let alignMode { config.setAlignMode(alignMode, forScreen: screen.displayID) }

        config.updateUI { raw in
            guard var parts = raw["partitions"] as? [[String: Any]] else { return }
            for c in coords {
                if let i = parts.firstIndex(where: { ($0["id"] as? String) == c.id }) {
                    parts[i]["x"] = Int(c.x.rounded())
                    parts[i]["y"] = Int(c.y.rounded())
                    parts[i]["width"] = Int(c.w.rounded())
                    parts[i]["height"] = Int(c.h.rounded())
                }
            }
            raw["partitions"] = parts
        }
        // 程序重排：移动窗口期间置位，避免 didMove 触发「拖动停止后吸附」把刚排好的坐标改写偏
        isProgrammaticMove = true
        // 只移动本屏分区（其他显示器上的分区保持原位）
        for p in panels(on: screen) {
            let id = p.partitionID
            let nx = config.num("x", of: id); let ny = config.num("y", of: id)
            let nw = config.num("width", of: id); let nh = config.num("height", of: id)
            let collapsed = config.bool("isCollapsed", of: id)
            // 折叠分区：窗口实际高 44（标题栏），定位用 44 保证左边/顶部正确；
            // 布局占位（上面 curY 累加）仍用展开高度，下方分区以「展开后底部」为基准。
            let displayH: CGFloat = collapsed ? 44 : CGFloat(nh)
            let targetOrigin = nativeOrigin(screen, x: CGFloat(nx), y: CGFloat(ny), h: displayH)
            let targetSize = NSSize(width: CGFloat(nw), height: displayH)
            let curOrigin = p.frame.origin
            let curSize = p.frame.size

            // 判据直接对标窗口当前物理位置与尺寸，杜绝由于外部微调或配置落后导致的跳过复位
            let moved = (abs(curOrigin.x - targetOrigin.x) > 0.5 || abs(curOrigin.y - targetOrigin.y) > 0.5)
            let resized = (abs(curSize.width - targetSize.width) > 0.5 || abs(curSize.height - targetSize.height) > 0.5)
            guard moved || resized else { continue }
            if resized {
                p.setSize(width: CGFloat(nw), height: displayH)
            }
            p.setFrameOrigin(targetOrigin)
        }
        isProgrammaticMove = false
        saveSoon(0.2)
    }

    // MARK: - 布局预设

    /// 把**指定屏**当前的分区布局存成命名预设（同屏同名 = 覆盖，即「用当前布局更新」）。
    ///
    /// 存的是**展开高度**：折叠只是临时查看态，若把 44pt 也存进布局，
    /// 从折叠状态保存的预设会把所有分区压扁。
    @discardableResult
    func saveLayoutPreset(named rawName: String, onScreenID sid: CGDirectDisplayID? = nil) -> String? {
        let name = LayoutPreset.normalize(name: rawName)
        guard !name.isEmpty else { return nil }
        let screen = resolvedScreen(sid)
        let entries: [LayoutPreset.Entry] = panels(on: screen).compactMap { p in
            let id = p.partitionID
            guard config.partition(id) != nil else { return nil }
            return LayoutPreset.Entry(id: id,
                                      x: config.num("x", of: id),
                                      y: config.num("y", of: id),
                                      width: config.num("width", of: id),
                                      height: config.num("height", of: id))
        }
        guard !entries.isEmpty else { return nil }
        config.saveLayoutPreset(LayoutPreset(name: name,
                                             screenID: screen.displayID,
                                             alignMode: config.alignMode(forScreen: screen.displayID),
                                             entries: entries,
                                             savedAt: Date()))
        saveSoon(0.2)
        return name
    }

    /// 应用布局预设：把预设里**仍在本屏**的分区搬回原位，并恢复该屏的对齐模式。
    ///
    /// 只处理「当前就在预设那块屏上」的分区：坐标是屏幕相对的，把别的屏的分区硬搬过来
    /// 会连带触发跨屏 rebuild，而且用户多半并不想这样 —— 那种情况跳过即可。
    func applyLayoutPreset(_ preset: LayoutPreset) {
        guard let target = screen(id: preset.screenID) else {
            let alert = NSAlert()
            alert.messageText = "无法应用「\(preset.name)」"
            alert.informativeText = "该布局属于一块当前未连接的显示器。重新接入那块显示器后再试，或在它上面重新保存一份布局。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
            _ = runAlert(alert, on: activeScreen())
            return
        }

        let sw = Double(target.frame.width), sh = Double(target.frame.height)
        let present = Set(panels(on: target).map { $0.partitionID })
        var coords: [(id: String, x: Double, y: Double, w: Double, h: Double)] = []
        var missing: [String] = []
        for e in preset.entries {
            guard config.partition(e.id) != nil, present.contains(e.id) else {
                missing.append(e.id)
                continue
            }
            // 显示器分辨率/缩放变了（换屏、改缩放）时把尺寸与位置夹回可视范围，
            // 否则恢复出来的分区会有一部分跑到屏幕外，看起来像「预设坏了」。
            let w = min(e.width, sw), h = min(e.height, sh)
            let x = min(max(0, e.x), max(0, sw - w))
            let y = min(max(0, e.y), max(0, sh - h))
            coords.append((id: e.id, x: x, y: y, w: w, h: h))
        }

        guard !coords.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "「\(preset.name)」里没有可恢复的分区"
            alert.informativeText = "预设中的分区已被删除，或已被移到其他显示器。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
            _ = runAlert(alert, on: target)
            return
        }
        if !missing.isEmpty {
            NSLog("[DeskIsle] 布局预设「%@」跳过 %d 个已不存在/已换屏的分区",
                  preset.name, missing.count)
        }
        applyPlacements(coords, on: target, alignMode: preset.alignMode)
    }

    func deleteLayoutPreset(_ preset: LayoutPreset) {
        config.deleteLayoutPreset(named: preset.name, onScreen: preset.screenID)
        saveSoon(0.2)
    }

    // MARK: - 全局搜索

    /// 打开全局搜索面板（托盘菜单 / 顶栏按钮 / 全局快捷键三个入口共用）。
    func openGlobalSearch() {
        presentSettingsPanel(
            GlobalSearchView(config: config, onClose: { [weak self] in self?.closeSettings() }),
            on: activeScreen())
    }

    /// 打开搜索结果指向的文件/目录。
    func openSearchHit(_ hit: SearchHit) {
        guard let url = hit.url else { return }
        // 先确认还在（外部可能刚删掉），否则 NSWorkspace 会静默失败，看起来像点了没反应
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSLog("[DeskIsle] 搜索结果已不存在: %@", url.path)
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// 在访达中显示搜索结果指向的文件。
    func revealSearchHit(_ hit: SearchHit) {
        guard let url = hit.url,
              FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 把某个分区的窗口顶到最前（待办 / 便签类搜索结果的「定位」动作）。
    /// 顺带处理两种「窗口其实看不见」的情况：所在屏处于幽灵隐藏态、分区处于折叠态。
    func focusPartition(_ id: String) {
        guard let panel = panels.first(where: { $0.partitionID == id }) else { return }
        let sid = panel.screen?.displayID ?? 0
        if config.isScreenHidden(sid) { toggleGhost(onScreenID: sid) }
        if config.bool("isCollapsed", of: id) { toggleCollapse(id) }
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        flashPanel(panel)
    }

    /// 短暂闪烁提醒（alpha 两轮脉动），用于「定位到分区」后的视觉指引。
    /// 用 alpha 而不是移动窗口 —— 不会碰到用户自己摆好的布局。
    private func flashPanel(_ panel: NSPanel) {
        let original = panel.alphaValue
        let steps: [(Double, Double)] = [(0.35, 0), (1.0, 0.13), (0.35, 0.26), (1.0, 0.39)]
        for (alpha, delay) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak panel] in
                guard let panel else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.12
                    panel.animator().alphaValue = alpha
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak panel] in
            panel?.alphaValue = original
        }
    }

    // MARK: - 设置模态框

    private var settingsPanel: NSPanel?
    /// 模态面板「真的被关掉」的监听令牌（见 `presentSettingsPanel`）
    private var settingsCloseToken: NSObjectProtocol?
    /// 当前被临时抬到普通窗口层级（`.normal`）的分区 id。nil = 没有分区处于提升态。
    private(set) var raisedPanelID: String?

    /// **真的**有一个模态框开着吗？
    ///
    /// ⚠️ 判据必须是 `isVisible` 而不是「引用非空」—— 面板的 styleMask 带 `.closable`，
    /// 用户点左上角红叉（或按 ⌘W）关闭时**不会**走 SwiftUI 里的 `onClose` 回调，
    /// `settingsPanel` 会一直指向一个已经关闭的窗口。而「有模态开着就不降层」这道门禁
    /// 一旦卡死，未置顶分区被点过之后就再也回不到桌面层 —— 表现正是
    /// 「没设置置顶的分区一直浮在最前面，只能手动点一下置顶再点一下才降回来」。
    private var isModalOpen: Bool { settingsPanel?.isVisible == true }

    /// 所有设置类模态框的唯一出口：尺寸、层级、落位、替换旧面板的逻辑只此一份。
    /// `target` 决定面板落在哪块屏幕 —— 必须显式传入，不能依赖 `NSScreen.main`（随焦点漂移）。
    private func presentSettingsPanel<V: View>(_ view: V, on target: NSScreen) {
        let host = NSHostingController(rootView: view)
        let w = ModalPanelSize.width, h = ModalPanelSize.height
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                        styleMask: [.titled, .closable, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.contentViewController = host
        p.setContentSize(NSSize(width: w, height: h))
        p.isReleasedWhenClosed = false
        p.level = .modalPanel
        // 任何弹窗都要能跨 Space 出现，否则会「窗口存在但不可见」（落在别的屏的非当前 Space）
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.center()
        // center() 只会落在「当前主屏」，若目标屏不是主屏需手动平移
        if let main = NSScreen.main, main != target {
            p.setFrameOrigin(NSPoint(x: p.frame.origin.x + (target.frame.midX - main.frame.midX),
                                     y: p.frame.origin.y + (target.frame.midY - main.frame.midY)))
        }
        settingsPanel?.close()
        settingsPanel = p
        // 面板可能被红叉 / ⌘W 直接关掉 —— 那条路不走 SwiftUI 的 onClose，
        // 必须用窗口自己的 willClose 兜住，否则 `settingsPanel` 会变成一个
        // 「指向已关闭窗口」的僵尸引用，把所有降层门禁永久卡死（见 isModalOpen）。
        if let old = settingsCloseToken { NotificationCenter.default.removeObserver(old) }
        settingsCloseToken = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: p, queue: .main
        ) { [weak self, weak p] _ in
            guard let self, let p else { return }
            if self.settingsPanel === p { self.settingsPanel = nil }
            if let t = self.settingsCloseToken {
                NotificationCenter.default.removeObserver(t)
                self.settingsCloseToken = nil
            }
            self.deactivateNonPinnedPartitions()
        }
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }

    func openGlobalSettings() {
        // 与「新建分区」「分区设置」共用同一个面板工厂：尺寸、层级、落位逻辑只有一份
        presentSettingsPanel(
            GlobalSettingsView(config: config, onClose: { [weak self] in self?.closeSettings() }),
            on: activeScreen())
    }

    /// 新建分区模态框。
    func openNewPartitionModal(onScreenID sid: CGDirectDisplayID? = nil) {
        // 面板落在「触发它的那块屏幕」（顶栏所在屏）→ 新建的分区也归到该屏
        let target = resolvedScreen(sid)
        presentSettingsPanel(NewPartitionView(
            onSelectFolder: { [weak self] in self?.selectFolder() },
            onCreate: { [weak self] type, folderPath, title, exts in
                self?.closeSettings()
                self?.createPartition(type: type, folderPath: folderPath, title: title,
                                      extensions: exts, onScreenID: target.displayID)
            },
            onClose: { [weak self] in self?.closeSettings() }
        ), on: target)
    }

    /// 分区级设置模态框（补 Electron「分区个性化设置」的能力）。
    func openPartitionSettings(_ id: String) {
        guard config.partition(id) != nil else { return }
        // 面板里能改名称/映射目录/后缀规则/尺寸，锁定时整体拦住（而不是「让你改完再拒绝保存」）
        if blockedByLock(id, action: "打开分区设置") { return }
        let target = panels.first(where: { $0.partitionID == id })?.screen ?? activeScreen()
        presentSettingsPanel(PartitionSettingsView(
            id: id,
            config: config,
            onSelectFolder: { [weak self] in self?.selectFolder() },
            onSave: { [weak self] title, folderPath, exts, viewMode, width, height, style in
                self?.closeSettings()
                self?.applyPartitionSettings(id: id, title: title, folderPath: folderPath,
                                             extensions: exts, viewMode: viewMode,
                                             width: width, height: height,
                                             style: style)
            },
            onDelete: { [weak self] in
                self?.closeSettings()
                self?.confirmRemovePartition(id)
            },
            onClose: { [weak self] in self?.closeSettings() }
        ), on: target)
    }

    /// 应用分区级设置。只回写对该类型有意义的字段 ——
    /// 例如给 todo 分区塞 `folderPath` 会污染配置（并被导出到其他端）。
    func applyPartitionSettings(id: String, title: String, folderPath: String?,
                               extensions: [String]?, viewMode: String,
                               width: Int? = nil, height: Int? = nil,
                               style: [String: Any]? = nil) {
        // 面板打开**期间**才被锁上的情况：入口拦不到，这里再拦一次（此时面板已关，答案是「没保存」）
        if blockedByLock(id, action: "修改分区设置") { return }
        guard let type = config.str("type", of: id) else { return }
        let icon = PartitionSettingsView.typeMeta[type]?.emoji ?? ""
        let label = PartitionSettingsView.typeMeta[type]?.label ?? type
        let body = title.isEmpty ? label : title
        let newTitle = icon + String(body.prefix(10))

        let oldFolder = config.str("folderPath", of: id) ?? ""
        let folderChanged = (folderPath != nil) && (folderPath != oldFolder)

        // 尺寸：面板总是把当前值一起带回来，只有真变了才动窗口 ——
        // 否则每次改个标题都会 setSize 一次（视觉上会闪一下，也会多写一次配置）。
        let oldWidth = Int(config.num("width", of: id).rounded())
        let oldHeight = Int(config.num("height", of: id).rounded())
        let newWidth = width.flatMap { $0 > 0 ? $0 : nil }
        let newHeight = height.flatMap { $0 > 0 ? $0 : nil }
        let widthChanged = newWidth != nil && newWidth != oldWidth
        let heightChanged = newHeight != nil && newHeight != oldHeight

        config.updateUI { raw in
            guard var parts = raw["partitions"] as? [[String: Any]],
                  let i = parts.firstIndex(where: { ($0["id"] as? String) == id }) else { return }
            parts[i]["title"] = newTitle
            if let w = newWidth { parts[i]["width"] = w }
            if let h = newHeight { parts[i]["height"] = h }
            if let p = folderPath, !p.isEmpty, type == "portal" {
                parts[i]["folderPath"] = p
            }
            if type == "portal" {
                parts[i]["viewMode"] = viewMode
            }
            // 外观：整段替换 `style`。
            // 空字典 = 用户按了「恢复默认外观」→ 直接删字段（让分区变回跟随全局），
            // 而不是留个空字典占位置（导出到别的端时是个无意义的 {}）。
            if let st = style {
                if st.isEmpty { parts[i].removeValue(forKey: "style") }
                else {
                    // 只收 `styleKeys` 白名单内的键：面板将来加草稿字段时不会被误写进配置。
                    parts[i]["style"] = st.filter { Config.styleKeys.contains($0.key) }
                }
            }
            raw["partitions"] = parts
        }

        // 尺寸变更立即落到窗口上。
        // 注意重设 origin：AppKit 的 setFrame 以**左下角**为参照，只改 size 会让分区
        // 向下“长”（顶边不动）—— 用户要的是左上角锚定、向右下扩张。
        if (widthChanged || heightChanged), let p = panels.first(where: { $0.partitionID == id }) {
            let scr = p.screen ?? activeScreen()
            let collapsed = config.bool("isCollapsed", of: id)
            let w = CGFloat(config.num("width", of: id))
            let h = CGFloat(config.num("height", of: id))
            let shownH: CGFloat = collapsed ? PartitionMetrics.headerHeight : h
            isProgrammaticMove = true
            p.setSize(width: w, height: shownH)
            p.setFrameOrigin(nativeOrigin(scr, x: CGFloat(config.num("x", of: id)),
                                          y: CGFloat(config.num("y", of: id)),
                                          h: shownH))
            isProgrammaticMove = false
            // 变大后可能顶出屏幕右下角：这里只夹 x/y（不回头改宽高），
            // 否则用户输入 900pt 会被「夹回」成 700pt，看起来像设置没生效。
            ensurePartitionsInBounds()
        }

        if type == "portal" {
            // 目录换了：清掉该分区记住的浏览路径，否则会继续停在旧目录的子路径上
            if folderChanged { portalBrowsePaths.removeValue(forKey: id) }
            startFolderWatching()
            // 通知视图重新 load（比 rebuild 全窗口轻得多，且不闪）
            NotificationCenter.default.post(name: .portalFolderChanged, object: id)
            // 高度是用户在面板里明确改过的不再自适应 —— 否则「设定 300pt」保存后
            // 会被按内容算出来的值立刻覆盖，用户只会看到「设置根本不起作用」。
            if !heightChanged { autoFitHeight(id, resetWidth: false) }
        }
        saveSoon(0.2)
    }

    func closeSettings() {
        settingsPanel?.close()
        settingsPanel = nil
        // 关掉模态框的同时把「临时提升」一并收掉：用户已经结束了这次交互，
        // 不该让某个分区继续挂在普通窗口层级上。
        deactivateNonPinnedPartitions()
    }

    func updatePartition(_ id: String, key: String, value: Any) {
        config.updateUI { raw in
            guard var parts = raw["partitions"] as? [[String: Any]],
                  let i = parts.firstIndex(where: { ($0["id"] as? String) == id }) else { return }
            if Config.styleKeys.contains(key) {
                var st = parts[i]["style"] as? [String: Any] ?? [:]
                st[key] = value
                parts[i]["style"] = st
            } else if key == "title" {
                // 标题（包含 icon 前缀 + 最多 10 个字符）
                let s = (value as? String) ?? ""
                parts[i]["title"] = String(s.prefix(16))
            } else if key == "folderPath" {
                parts[i]["folderPath"] = value
                // portal 自动标题：当前标题是默认值时，用文件夹名
                let title = parts[i]["title"] as? String ?? ""
                if title.isEmpty || title == "📁 映射文件夹" || title == "新便签" {
                    let folderName = ((value as? String) as NSString?)?.lastPathComponent ?? ""
                    if !folderName.isEmpty {
                        parts[i]["title"] = "📁 " + String(folderName.prefix(10))
                    }
                }
            } else {
                parts[i][key] = value
            }
            raw["partitions"] = parts
        }
        // 窗口同步
        if let panel = panels.first(where: { $0.partitionID == id }) {
            switch key {
            case "width", "height":
                panel.setSize(width: CGFloat(config.num("width", of: id)),
                              height: CGFloat(config.num("height", of: id)))
            case "isCollapsed":
                panel.applyCollapsed(config.bool("isCollapsed", of: id),
                                     expandedHeight: CGFloat(config.num("height", of: id)))
            case "isAlwaysOnTop":
                panel.applyPinned(config.bool("isAlwaysOnTop", of: id))
                for (_, tb) in topBars { tb.applyFullScreenAuxiliary(config.hasPinned) }
            case "isLocked":
                panel.applyLocked(isLocked(id))
            default:
                break
            }
        }
        // folderPath 变了要重启文件监听（portal 自动刷新）
        if key == "folderPath" { startFolderWatching() }
        refreshHitTest()
        saveSoon(0.2)
    }

    func updateSetting(_ key: String, value: Any) {
        config.updateUI { raw in
            var s = raw["settings"] as? [String: Any] ?? [:]
            s[key] = value
            raw["settings"] = s
        }
        if key == "autoStart" {
            applyAutoLaunch(value as? Bool ?? false)
        }
        // 顶栏显隐（按屏）变化：按各屏自己的设置重建顶栏集合 + 纠正越界
        if key == "showTopBar" || key == "topBarByScreen" {
            rebuildTopBars()
            for (_, tb) in topBars { tb.orderFrontRegardless() }
            ensurePartitionsInBounds()
        }
        // 锁定分区位置（按屏）变化：重新应用各分区的可拖动状态
        if key == "isLayoutLocked" || key == "lockedByScreen" {
            for p in panels { p.applyLocked(isLocked(p.partitionID)) }
        }
        saveSoon(0.2)
    }

    /// 开机自启（macOS 13+ 用 SMAppService，需打包成 .app 才有效；失败静默）。
    private func applyAutoLaunch(_ enable: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("[DeskIsle] 设置开机自启失败（需打包成 .app）: %@", error.localizedDescription)
        }
    }

    // MARK: - 文件操作

    func openFile(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// **双击条目的统一入口**：按类型分派（进入目录 / 预览图片 / 外部打开）。
    ///
    /// 判据在 `FileKinds.doubleClickAction`（三端同源，有单测钉着）；这里只负责执行。
    /// 三个分支都走过这段代码，portal 各处才不会出现「同一份文件双击行为不同」。
    ///
    /// ⚠️ 图片走**内置预览**而不是 `NSWorkspace.open` —— 后者会把「预览」应用拉到前台，
    /// 用户只是想看一眼，整个前台却被换走了。
    func performDoubleClick(path: String, isDirectory: Bool) {
        switch FileKinds.doubleClickAction(isDirectory: isDirectory, path: path) {
        case .enterDirectory:  openFile(path)          // 网格 / 列表都是扁平视图：进目录 = 在访达打开
        case .previewImage:    QuickPreview.shared.show(path)
        case .openExternally:  openFile(path)
        }
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// 在原生终端中打开指定目录或文件所在目录。
    func openInTerminal(_ path: String) {
        let isDir = (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeDirectory
        let targetPath = isDir ? path : (path as NSString).deletingLastPathComponent
        let url = URL(fileURLWithPath: targetPath)
        if let terminalUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.open([url], withApplicationAt: terminalUrl, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// 当前系统是否安装了 Visual Studio Code。
    var isVSCodeAvailable: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") != nil
    }

    /// 在 VS Code 中打开指定路径。
    func openInVSCode(_ path: String) {
        let url = URL(fileURLWithPath: path)
        guard let vscodeUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") else { return }
        NSWorkspace.shared.open([url], withApplicationAt: vscodeUrl, configuration: NSWorkspace.OpenConfiguration())
    }

    func trashFile(_ path: String) {
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        } catch {
            NSLog("[DeskIsle] 移入废纸篓失败: %@", error.localizedDescription)
        }
    }

    /// 在 portal 分区的当前目录下新建文件夹。
    func createFolderInPortal(_ id: String, path: String, name: String) {
        let fm = FileManager.default
        var safe = name
        for ch in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"] {
            safe = safe.replacingOccurrences(of: ch, with: "_")
        }
        if safe.isEmpty { safe = "新建文件夹" }
        var full = (path as NSString).appendingPathComponent(safe)
        var i = 2
        while fm.fileExists(atPath: full) {
            full = (path as NSString).appendingPathComponent("\(safe) \(i)")
            i += 1
        }
        do {
            try fm.createDirectory(atPath: full, withIntermediateDirectories: false, attributes: nil)
            NotificationCenter.default.post(name: .portalFolderChanged, object: id)
        } catch {
            NSLog("[DeskIsle] 新建文件夹失败: %@", error.localizedDescription)
        }
    }

    /// 在 portal 分区的当前目录下新建文本文档。
    /// 默认名称 "新建文档.txt"，同名按访达规则自动递增 "新建文档 2.txt"、"新建文档 3.txt"。
    /// 创建成功返回新文件的完整路径。
    @discardableResult
    func createFileInPortal(_ id: String, path: String, baseName: String = "新建文档", ext: String = "txt") -> String? {
        let fm = FileManager.default
        let fileExt = ext.isEmpty ? "" : ".\(ext)"
        var candidate = "\(baseName)\(fileExt)"
        var full = (path as NSString).appendingPathComponent(candidate)
        var i = 2
        while fm.fileExists(atPath: full) {
            candidate = "\(baseName) \(i)\(fileExt)"
            full = (path as NSString).appendingPathComponent(candidate)
            i += 1
        }
        guard fm.createFile(atPath: full, contents: Data(), attributes: nil) else {
            NSLog("[DeskIsle] 新建文本文档失败: %@", full)
            return nil
        }
        NotificationCenter.default.post(name: .portalFolderChanged, object: id)
        return full
    }

    /// 把拖进 portal 分区的文件**移动**到目标目录。
    ///
    /// 三条硬规矩（都是踩过或必然会踩的）：
    /// 1. **绝不覆盖**：同名就按访达习惯自动加「 2」后缀。覆盖是不可撤销的，
    ///    而「多出来一个副本」用户一眼能看见、随手能删。
    /// 2. **不能把文件夹拖进它自己的子孙目录**（`/a` → `/a/b`）：`moveItem` 在部分系统版本上
    ///    会静默产出半截结果，必须显式拒绝。
    @discardableResult
    func moveFilesIntoPortal(_ id: String, paths: [String], directory: String) -> (moved: Int, failed: [String]) {
        let (done, failed, _) = relocateFiles(paths, into: directory, move: true)
        if done > 0 {
            NotificationCenter.default.post(name: .portalFolderChanged, object: id)
        }
        return (done, failed)
    }

    // MARK: 同名冲突三选一（移入 / 粘贴共用）

    /// 同名冲突的三种处理：保留两者（自动加「 2」）、停止（整体取消）、替换（覆盖）。
    enum MoveConflictDecision { case keepBoth, stop, replace }

    /// 把一批文件移入 / 贴入 `directory`（move=true 为移动，false 为复制）。
    ///
    /// 遇同名先弹三选一弹窗；「停止」则整体取消（返回 (0, [])）。
    /// 覆盖与 `moveFilesIntoPortal` 完全一致的三条规矩（不覆盖 / 不进子孙 / 同目录 no-op）。
    func relocateFiles(_ paths: [String], into directory: String, move: Bool) -> (done: Int, failed: [String], decision: MoveConflictDecision) {
        let fm = FileManager.default
        let dir = FileMove.normalize(directory)

        // 1. 冲突检测：只算 shouldMove 为真且目标目录已存在同名的项
        let conflictPaths = FileMove.conflicts(paths, directory: directory) { fm.fileExists(atPath: $0) }
        let decision: MoveConflictDecision
        if conflictPaths.isEmpty {
            decision = .keepBoth
        } else {
            let names = conflictPaths.map { ($0 as NSString).lastPathComponent }
            decision = resolveMoveConflict(names: names)
        }
        guard decision != .stop else { return (0, [], .stop) }

        var done = 0
        var failed: [String] = []

        for path in paths {
            let name = (path as NSString).lastPathComponent
            // 同目录 / 拖自己进自己 → 跳过（判定口径见 DeskIsleCore/FileMove.swift）
            guard FileMove.shouldMove(path, into: directory) else {
                if FileMove.isSelfOrDescendant(directory, of: path) { failed.append(name) }
                continue
            }

            let target: String
            if decision == .replace {
                // 替换：先删目标再落过去，绝不保留半截
                target = (dir as NSString).appendingPathComponent(name)
                if fm.fileExists(atPath: target) {
                    do { try fm.removeItem(atPath: target) } catch {
                        NSLog("[DeskIsle] 替换前删除失败 %@: %@", target, error.localizedDescription)
                        failed.append(name); continue
                    }
                }
            } else {
                // 保留两者：同名自动加「 2」（与访达一致）
                target = FileMove.destination(for: path, directory: directory) { fm.fileExists(atPath: $0) }
            }

            do {
                if move {
                    try fm.moveItem(atPath: path, toPath: target)
                } else {
                    try fm.copyItem(atPath: path, toPath: target)
                }
                done += 1
            } catch {
                NSLog("[DeskIsle] 移入分区失败 %@ → %@: %@", path, target, error.localizedDescription)
                failed.append(name)
            }
        }
        return (done, failed, decision)
    }

    /// 同名冲突弹窗：保留两者 / 停止 / 替换。返回用户的选择；取消（Esc）视为「停止」。
    private func resolveMoveConflict(names: [String]) -> MoveConflictDecision {
        let alert = NSAlert()
        alert.messageText = "目标文件夹中已有同名文件"
        let listed = names.prefix(5).map { "• \($0)" }.joined(separator: "\n")
        let more = names.count > 5 ? "\n…等 \(names.count) 个文件" : ""
        alert.informativeText = "以下文件已存在，如何处理？\n\(listed)\(more)"
        alert.alertStyle = .warning
        let keep = alert.addButton(withTitle: "保留两者")
        let stop = alert.addButton(withTitle: "停止")
        let replace = alert.addButton(withTitle: "替换")
        keep.keyEquivalent = "\r"        // 回车 = 保留两者（默认，最不易丢数据）
        stop.keyEquivalent = "\u{1b}"    // Esc = 停止（取消）
        replace.keyEquivalent = ""
        let resp = alert.runModal()
        switch resp {
        case .alertFirstButtonReturn:  return .keepBoth
        case .alertSecondButtonReturn: return .stop
        default:                      return .replace
        }
    }

    /// 重命名文件/文件夹：非法字符消毒 + 同目录重名自动递增（`名称 2`）。
    func renameFile(_ path: String, to newName: String) {
        let fm = FileManager.default
        var safe = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        for ch in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"] {
            safe = safe.replacingOccurrences(of: ch, with: "_")
        }
        guard !safe.isEmpty else { return }
        let dir = (path as NSString).deletingLastPathComponent
        var target = (dir as NSString).appendingPathComponent(safe)
        // 目标与自身相同时视为 no-op；否则重名递增
        if target != path {
            let ext = (safe as NSString).pathExtension
            let base = (safe as NSString).deletingPathExtension
            var i = 2
            while fm.fileExists(atPath: target) {
                let numbered = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
                target = (dir as NSString).appendingPathComponent(numbered)
                i += 1
            }
        }
        do {
            try fm.moveItem(atPath: path, toPath: target)
        } catch {
            NSLog("[DeskIsle] 重命名失败: %@", error.localizedDescription)
        }
    }

    // MARK: - 配置热重载（FSEvents 事件驱动 + 极低频兜底）

    private var configPoll: DispatchSourceTimer?
    private var configStream: FSEventStreamRef?
    private var lastKnownConfigMtime: Date?

    /// 事件驱动为主，轮询只作兜底。
    ///
    /// ## ⚠️ 历史结论的纠正（改这里前请先读完）
    /// 这里原先写着「目录监听不投递，故只能 1s mtime 轮询」。那个结论测的是
    /// **目录级 kevent / DispatchSource**，与 FSEvents 是两套彼此独立的机制。
    /// 2026-10-07 用最小用例复测 FSEvents（监听配置目录，模拟 save 的
    /// 「写 .tmp → rename」）：**全部投递**。同时 `FolderWatcher` 里的 portal 监听
    /// 早已跑在 FSEvents 上且工作正常 —— 同一台机器、同一个 API。
    /// 于是改为事件驱动，1s 轮询退为 15s 兜底（只防 FSEvents 在个别卷上不投递）。
    func startConfigWatching() {
        guard configPoll == nil, configStream == nil else { return }
        lastKnownConfigMtime = configFileMtime()
        let streamOK = installConfigStream()
        // 流在 = 15s 一次 stat（几乎永不触发，纯保险）；流不在 = 2s 轮询，行为与改造前一致。
        let interval: TimeInterval = streamOK ? 15 : 2
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in self?.reloadConfigIfChanged() }
        t.resume()
        configPoll = t
        if !streamOK {
            NSLog("[DeskIsle] 配置目录 FSEvents 创建失败 → 回退 %gs mtime 轮询", interval)
        }
    }

    /// 监听配置**所在目录**（不能监听文件本身：save 走 rename，inode 会被换掉，
    /// 文件级 watcher 在第一次保存后就永久失效）。
    private func installConfigStream() -> Bool {
        let dir = config.url.deletingLastPathComponent().path
        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes)
            | UInt32(kFSEventStreamCreateFlagFileEvents)
            | UInt32(kFSEventStreamCreateFlagNoDefer)
            | UInt32(kFSEventStreamCreateFlagWatchRoot)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault,
                                          configFSEventCallback,
                                          &context,
                                          [dir] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          0.2,
                                          FSEventStreamCreateFlags(flags)) else { return false }
        FSEventStreamSetDispatchQueue(s, .main)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            return false
        }
        configStream = s
        return true
    }

    /// FSEvents 回调（主队列）。只看配置文件自己 —— 目录里还有别的写入（历史记录等），
    /// 那些不该触发「重建全部窗口」。
    fileprivate func handleConfigEvent(paths: [String]) {
        let name = config.url.lastPathComponent
        let hit = paths.contains { p in
            let last = (p as NSString).lastPathComponent
            // save 是「写 name.tmp → rename 成 name」，两条事件都带上 name 前缀
            return last == name || last.hasPrefix(name)
        }
        guard hit else { return }
        reloadConfigIfChanged()
    }

    func stopConfigWatching() {
        configPoll?.cancel()
        configPoll = nil
        if let s = configStream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
        configStream = nil
    }

    private func configFileMtime() -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: config.url.path)
        return (attrs?[.modificationDate] as? Date)
    }

    private func reloadConfigIfChanged() {
        let mtime = configFileMtime()
        guard mtime != lastKnownConfigMtime else { return }
        lastKnownConfigMtime = mtime
        // 自己的 save() 也会改 mtime。距上次落盘 1.5 秒内的变更视为自己的
        // 写入，忽略——否则 save → reload → rebuild 的自触发死循环会把全部窗口
        // 反复重建（实测症状：窗口 id 变化、onscreen=false、分区闪没）。
        guard Date().timeIntervalSince(config.lastSaveTime) > 1.5 else { return }
        guard config.load() else { return }
        rebuild()
        syncHotkeysFromConfig()
        showAll()
    }

    // MARK: - 行为

    /// 置顶 / 取消置顶：只改该窗口的 level + collectionBehavior，内容不搬家、零闪烁。
    func setPinned(_ id: String, _ on: Bool) {
        // 置顶改的是窗口层级（可见行为的一部分），同样算「改变」——锁定时一并拦下
        if blockedByLock(id, action: on ? "置顶" : "取消置顶") { return }
        config.updateUI { raw in
            guard var parts = raw["partitions"] as? [[String: Any]],
                  let i = parts.firstIndex(where: { ($0["id"] as? String) == id }) else { return }
            parts[i]["isAlwaysOnTop"] = on
            raw["partitions"] = parts
        }
        panels.first(where: { $0.partitionID == id })?.applyPinned(on)
        for (_, tb) in topBars { tb.applyFullScreenAuxiliary(config.hasPinned) }
        saveSoon(0.2)
    }

    /// 折叠 / 展开：只改窗口高度（44 ↔ 原高度），内容不搬家。
    func toggleCollapse(_ id: String) {
        // 折叠会改几何，属于「锁定时不允许做任何改变」的核心一条
        if blockedByLock(id, action: config.bool("isCollapsed", of: id) ? "展开" : "折叠") { return }
        guard let panel = panels.first(where: { $0.partitionID == id }) else { return }
        let collapsed = !config.bool("isCollapsed", of: id)
        config.updateUI { raw in
            guard var parts = raw["partitions"] as? [[String: Any]],
                  let i = parts.firstIndex(where: { ($0["id"] as? String) == id }) else { return }
            parts[i]["isCollapsed"] = collapsed
            raw["partitions"] = parts
        }
        let expandedHeight = CGFloat(config.num("height", of: id))
        panel.applyCollapsed(collapsed, expandedHeight: expandedHeight)
        refreshHitTest()
        saveSoon(0.2)
    }

    /// 缩放进行中：更新窗口尺寸 + 静默写配置（节流保存）。
    /// 缩放期间必须临时关掉标题栏拖动（`canDragWindow`）：手柄的手势与窗口拖动
    /// 是两套系统（SwiftUI gesture vs 窗口拖动），不同步关会导致
    /// 「一边改尺寸一边挪位置」互相打架。
    func resizePartition(_ id: String, width: CGFloat, height: CGFloat) {
        guard !isLocked(id) else { return }
        guard let panel = panels.first(where: { $0.partitionID == id }) else { return }
        panel.canDragWindow = false
        panel.setSize(width: width, height: height)
        config.updateQuiet { raw in
            guard var parts = raw["partitions"] as? [[String: Any]],
                  let i = parts.firstIndex(where: { ($0["id"] as? String) == id }) else { return }
            parts[i]["width"] = Int(width.rounded())
            parts[i]["height"] = Int(height.rounded())
            raw["partitions"] = parts
        }
        saveSoon(0.4)
    }

    /// 当前正在缩放（或鼠标悬停在缩放手柄上）的分区 ID。
    /// 缩放期间 panel.canDragWindow 保持 false（标题栏也不许拖），且 hitTest 绝不穿透该窗口。
    private(set) var activeResizingID: String?

    func setResizing(_ id: String, active: Bool) {
        guard let panel = panels.first(where: { $0.partitionID == id }) else { return }
        if active {
            activeResizingID = id
            panel.canDragWindow = false
            panel.ignoresMouseEvents = false
        } else {
            if activeResizingID == id {
                activeResizingID = nil
            }
            panel.applyLocked(isLocked(id))
        }
    }

    /// 获取分区当前在屏幕相对坐标系下的实际 Frame
    func currentPartitionFrame(_ id: String) -> (x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat)? {
        guard let panel = panels.first(where: { $0.partitionID == id }) else { return nil }
        let screen = panel.screen ?? referenceScreen()
        let f = panel.frame
        let topY = screen.frame.origin.y + screen.frame.height - f.origin.y - f.height
        let relX = f.origin.x - screen.frame.origin.x
        return (relX, topY, f.width, f.height)
    }

    /// 从任意边/角缩放：同时改 origin 与 size（配置用左上原点坐标）。
    func resizePartitionFrame(_ id: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        guard !isLocked(id),
              let panel = panels.first(where: { $0.partitionID == id }) else { return }
        let screen = panel.screen ?? referenceScreen()
        activeResizingID = id
        panel.canDragWindow = false
        if panel.ignoresMouseEvents { panel.ignoresMouseEvents = false }
        // 高度下限同样跟随「分区最小高度」（与 PartitionPanel 拖边缩放同一口径）
        let w = max(120, width), h = max(max(64, effectiveMinPartitionHeight(on: screen)), height)
        let o = nativeOrigin(screen, x: x, y: y, h: h)
        panel.setFrame(NSRect(x: o.x, y: o.y, width: w, height: h), display: true, animate: false)
        config.updateQuiet { raw in
            guard var parts = raw["partitions"] as? [[String: Any]],
                  let i = parts.firstIndex(where: { ($0["id"] as? String) == id }) else { return }
            parts[i]["x"] = Int(x.rounded())
            parts[i]["y"] = Int(y.rounded())
            parts[i]["width"] = Int(w.rounded())
            parts[i]["height"] = Int(h.rounded())
            raw["partitions"] = parts
        }
    }

    /// 静默更新分区 Frame 坐标与尺寸（拖拽缩放期间高频调用，不触发重渲染）
    func updatePartitionFrameQuiet(_ id: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        activeResizingID = id
        config.updateQuiet { raw in
            guard var parts = raw["partitions"] as? [[String: Any]],
                  let i = parts.firstIndex(where: { ($0["id"] as? String) == id }) else { return }
            parts[i]["x"] = Int(x.rounded())
            parts[i]["y"] = Int(y.rounded())
            parts[i]["width"] = Int(width.rounded())
            parts[i]["height"] = Int(height.rounded())
            raw["partitions"] = parts
        }
    }

    /// 缩放结束：恢复窗口拖动 + 落盘 + 命中检测刷新。
    func finishResize(_ id: String) {
        activeResizingID = nil
        panels.first(where: { $0.partitionID == id })?.applyLocked(isLocked(id))
        // 拖动手势期间是静默更新（不触发重渲染），这里强制刷新一次，
        // 让 SwiftUI 用上新的 width/height——否则内容仍按旧尺寸布局。
        config.updateUI { _ in }
        saveNow()
        refreshHitTest()
    }

    /// 吸附：把分区贴到屏幕边缘或相邻分区边缘（阈值 16，Alt 键跳过）。
    private func snapPartition(_ id: String) {
        guard let panel = panels.first(where: { $0.partitionID == id }) else { return }
        let screen = panel.screen ?? referenceScreen()
        let sh = screen.frame.height
        let sw = screen.frame.width

        let f = panel.frame
        // ⚠️ 自身与「相邻分区」必须换算到**同一个坐标系**（屏幕相对、左上原点）。
        // 历史上这里自身用屏幕相对坐标，相邻分区却用 AppKit 全局坐标 ——
        // 二者在非原点屏上相差一个屏幕原点偏移（外接屏 origin 为 (1680, -30)），
        // 导致「外接屏上的分区拖动时吸附不到相邻分区」，只剩屏幕边缘吸附可用。
        let x = f.origin.x - screen.frame.origin.x
        let y = screen.frame.origin.y + sh - f.origin.y - f.height
        let w = f.width
        let h = f.height

        let others: [(x: Double, y: Double, w: Double, h: Double)] = panels
            .filter { $0.partitionID != id }
            .map { o in
                let of = o.frame
                return (x: Double(of.origin.x - screen.frame.origin.x),
                        y: Double(screen.frame.origin.y + sh - of.origin.y - of.height),
                        w: Double(of.width),
                        h: Double(of.height))
            }

        let topM = visualTopMargin(for: screen)
        let snapped = LayoutEngine.snappedPosition(
            x: Double(x), y: Double(y), w: Double(w), h: Double(h),
            screenWidth: Double(sw), screenHeight: Double(sh), others: others,
            topMargin: Double(topM))
        let nx = CGFloat(snapped.x)
        let ny = CGFloat(snapped.y)

        if nx != x || ny != y {
            let targetOrigin = nativeOrigin(screen, x: nx, y: ny, h: h)
            let targetFrame = NSRect(origin: targetOrigin, size: panel.frame.size)
            isProgrammaticMove = true
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(targetFrame, display: true)
            }, completionHandler: { [weak self] in
                self?.isProgrammaticMove = false
            })
            config.updateQuiet { raw in
                guard var parts = raw["partitions"] as? [[String: Any]],
                      let i = parts.firstIndex(where: { ($0["id"] as? String) == id }) else { return }
                parts[i]["x"] = Int(nx.rounded())
                parts[i]["y"] = Int(ny.rounded())
                raw["partitions"] = parts
            }
            saveSoon(0.2)
        }
    }

    /// hover 展开（hoverPeekCollapsed）：折叠分区悬停时临时展开预览。
    /// 不改 config.isCollapsed（折叠状态仍由 toggleCollapse 控制），只是临时改窗口高度；
    /// peek 期间的 didMove 被 isHoverPeeking 抑制，不写配置、不吸附、不保存。
    func hoverPeek(_ id: String, expanded: Bool) {
        guard let panel = panels.first(where: { $0.partitionID == id }) else { return }
        let h = CGFloat(config.num("height", of: id))
        isHoverPeeking = true
        panel.applyCollapsed(!expanded, expandedHeight: h)
        isHoverPeeking = false
        refreshHitTest()
    }

    /// 「显示/隐藏分区」：只作用于**指定显示器**上的分区（默认 = 光标所在屏）。
    /// 多显示器下每屏独立控制，互不干扰；顶栏显隐由 showTopBar 单独控制，不在此联动。
    func toggleGhost(onScreenID sid: CGDirectDisplayID? = nil) {
        let scr = resolvedScreen(sid)
        let target = scr.displayID
        config.toggleScreenHidden(target)
        let list = panels(on: scr)
        if config.isScreenHidden(target) {
            for p in list { p.orderOut(nil) }
        } else {
            for p in list { p.orderFrontRegardless() }
        }
        refreshHitTest()
    }

    func realign(onScreenID sid: CGDirectDisplayID? = nil) {
        // 用「目标屏自己的对齐模式」重排（每屏独立设置）
        let scr = resolvedScreen(sid)
        align(mode: config.alignMode(forScreen: scr.displayID), onScreenID: scr.displayID)
    }

    /// 打开「新建分区」模态框（在指定显示器上创建，默认 = 光标所在屏）。
    func addPartition(onScreenID sid: CGDirectDisplayID? = nil) {
        openNewPartitionModal(onScreenID: sid)
    }

    /// 弹系统文件夹选择器，返回选中的目录路径。
    func selectFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }

    /// 按类型创建分区（对齐 Electron 的 NewPartitionModal 默认内容）。
    func createPartition(type: String, folderPath: String?, title: String?,
                         extensions: [String] = [], onScreenID sid: CGDirectDisplayID? = nil) {
        let targetScreen = resolvedScreen(sid)
        let id = UUID().uuidString
        let style: [String: Any] = [:]   // 视觉类滑块已移除，新建分区不再写入 blurAmount/borderRadius 等死字段
        // 默认初始尺寸：宽 defaultPartitionWidth、高 max(默认高度, 最小高度)（均最低 140）。
        // ⚠️ 取较大值而不是直接用默认高度：用户把「最小高度」抬到默认高度之上时，
        // 新建分区若仍按默认高度生成，一落地就违反自己的下限设定（且右键「自适应」后会被撑大）。
        let defaultW = Int(defaultPartitionWidth)
        let defaultH = Int(max(effectiveDefaultPartitionHeight(on: targetScreen),
                               effectiveMinPartitionHeight(on: targetScreen)))
        let w = CGFloat(defaultW)
        let h = CGFloat(defaultH)
        let slot = findFreeSlot(width: w, height: h, on: targetScreen)

        let defaultTitle: String
        var part: [String: Any] = [
            "id": id, "type": type,
            // 记录所属显示器：坐标是相对该屏的，重启后分区回到这块屏
            "screenId": Int(targetScreen.displayID),
            "x": Int(slot.x), "y": Int(slot.y), "width": defaultW, "height": defaultH,
            "isCollapsed": false, "isLocked": false,
            "style": style, "sortBy": "name", "sortOrder": "asc",
            "viewMode": "grid", "files": [], "isAlwaysOnTop": false
        ]
        switch type {
        case "portal":
            defaultTitle = "📁 映射文件夹"
            part["folderPath"] = folderPath ?? ""
        case "todo":
            defaultTitle = "✅ 今日待办清单"
            part["todos"] = [
                ["id": "todo-1", "text": "整理桌面核心工作文件", "completed": false, "priority": "high"],
                ["id": "todo-2", "text": "规划项目迭代功能", "completed": true, "priority": "medium"]
            ]
        default:
            defaultTitle = "📝 随手便签"
            part["noteContent"] = "在此输入便签备忘内容..."
        }
        let rawTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedTitle = rawTitle.isEmpty ? defaultTitle : rawTitle
        part["title"] = String(resolvedTitle.prefix(10))

        config.updateUI { raw in
            var parts = raw["partitions"] as? [[String: Any]] ?? []
            parts.append(part)
            raw["partitions"] = parts
        }
        let panel = PartitionPanel(config: config, id: id, screen: targetScreen)
        panels.append(panel)
        panel.orderFrontRegardless()
        addPanelObservers(panel)
        if type == "portal" { startFolderWatching() }
        GlobalSearch.invalidateCache()   // 新分区可能指向一个刚创建/刚选的目录
        // 新建分区后按**该屏自己的对齐方式**自动重排 —— 只重排新分区所在的那块屏幕，
        // 其他显示器上的分区保持原位不动。
        align(mode: config.alignMode(forScreen: targetScreen.displayID),
              onScreenID: targetScreen.displayID)
        saveSoon(0.2)
    }

    /// 删除前确认（Electron 用原生消息框，明示「不删除本地源文件」）。
    /// 统一弹出模态框：置入所有 Space，并**落位到指定屏幕中心**。
    /// ⚠️ `NSAlert` 默认弹在主屏 —— 多显示器下若目标分区在副屏，
    /// 用户会看到「点了没反应」（窗口其实开在另一块屏上）。
    @discardableResult
    private func runAlert(_ alert: NSAlert, on screen: NSScreen?) -> NSApplication.ModalResponse {
        let target = screen ?? referenceScreen()
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        NSApp.activate(ignoringOtherApps: true)
        alert.window.setFrameOrigin(NSPoint(x: target.frame.midX - alert.window.frame.width / 2,
                                            y: target.frame.midY - alert.window.frame.height / 2))
        return alert.runModal()
    }

    /// 用最近一份历史快照覆盖当前配置。
    /// 当前状态会先被存成一份新快照，所以这一步本身也是可回滚的。
    func restoreLatestHistory() {
        let history = config.availableHistory()
        guard let latest = history.first else {
            let alert = NSAlert()
            alert.messageText = "还没有可用的历史快照"
            alert.informativeText = "快照会在每次保存配置时自动生成（同一分钟内只留一份，最多保留 20 份）。\n改动过设置或拖动分区之后，这里就会出现可恢复的版本。"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "好")
            runAlert(alert, on: nil)
            return
        }

        let stamp = latest.deletingPathExtension().lastPathComponent
        let alert = NSAlert()
        alert.messageText = "恢复到历史快照？"
        alert.informativeText = """
        将用快照 \(stamp) 覆盖当前配置，并立即重建全部分区窗口。
        当前状态会先另存为一份新快照，之后仍可再恢复回来。
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "恢复")
        alert.addButton(withTitle: "取消")
        guard runAlert(alert, on: nil) == .alertFirstButtonReturn else { return }

        saveNow()   // 把「当前状态」也留在历史里，保证本次操作可回滚
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: latest),
              (try? JSONSerialization.jsonObject(with: data)) != nil else {
            NSLog("[DeskIsle] 历史快照不可读: %@", latest.path)
            return
        }
        do {
            try? fm.removeItem(at: config.url)
            try fm.copyItem(at: latest, to: config.url)
        } catch {
            NSLog("[DeskIsle] 恢复历史快照失败: %@", error.localizedDescription)
            return
        }
        config.load()
        rebuild()
        showAll()
        NSLog("[DeskIsle] 已从历史快照恢复: %@", latest.lastPathComponent)
    }

    func confirmRemovePartition(_ id: String) {
        if blockedByLock(id, action: "删除") { return }
        let title = config.str("title", of: id) ?? "该分区"
        let alert = NSAlert()
        alert.messageText = "移除分区「\(title)」？"
        alert.informativeText = "仅从 DeskIsle 中解绑，不会删除本地源文件。"
        alert.addButton(withTitle: "移除分区")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        // 落位到分区所在屏幕（NSAlert 默认弹在主屏，多显示器下会「看不见」）
        let aScreen = panels.first(where: { $0.partitionID == id })?.screen
        guard runAlert(alert, on: aScreen) == .alertFirstButtonReturn else { return }
        removePartition(id)
    }

    func removePartition(_ id: String) {
        portalBrowsePaths.removeValue(forKey: id)   // 顺手清掉浏览路径的内存记录
        config.updateUI { raw in
            raw["partitions"] = (raw["partitions"] as? [[String: Any]] ?? []).filter { ($0["id"] as? String) != id }
        }
        // 分区集合变了：视图侧缓存（徽标计数等）整批作废
        config.invalidateAllViewCaches()
        if let i = panels.firstIndex(where: { $0.partitionID == id }) {
            removePanelObservers(panels[i])
            panels[i].close()
            panels.remove(at: i)
            if raisedPanelID == id { raisedPanelID = nil }
        }
        for (_, tb) in topBars { tb.applyFullScreenAuxiliary(config.hasPinned) }
        startFolderWatching()   // 重建探测目标，移掉被删分区的残留监听
        GlobalSearch.invalidateCache()   // 搜索的目录缓存可能仍留着这个已删分区的文件
        saveSoon(0.2)
    }

    // MARK: - 配置备份（导出 / 导入）

    func exportConfigBackup() {
        saveNow()
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        let name = "deskisle_backup_\(fmt.string(from: Date())).json"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [.json]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let dst = panel.url else { return }
        try? FileManager.default.copyItem(at: config.url, to: dst)
        NSWorkspace.shared.activateFileViewerSelecting([dst])
    }

    func importConfigBackup() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let src = panel.url,
              let data = try? Data(contentsOf: src),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let parts = obj["partitions"] as? [[String: Any]] else {
            let alert = NSAlert()
            alert.messageText = "导入失败"
            alert.informativeText = "文件解析失败，未做任何改动。"
            alert.runModal()
            return
        }
        config.updateUI { raw in
            raw["partitions"] = parts
            if let s = obj["settings"] as? [String: Any] {
                var merged = raw["settings"] as? [String: Any] ?? [:]
                for (k, v) in s { merged[k] = v }
                raw["settings"] = merged
            }
        }
        // 分区集合整个换了：视图侧缓存要一起作废，
        // 否则列表会继续显示导入前那份配置里的旧条目（缓存键没变 → 命中旧缓存）
        config.invalidateAllViewCaches()
        rebuild()
        showAll()
        GlobalSearch.invalidateCache()   // 分区集合整个换了，搜索的目录缓存全部作废
        if let str = config.globalShortcutPersisted, let sc = Shortcut(persisted: str) {
            _ = installHotkey(sc)
        }
        // 导入的配置里可能带着另一套搜索热键，一并生效（否则界面显示的和实际按的不同）
        if let str = config.searchShortcutPersisted, let sc = Shortcut(persisted: str) {
            _ = installSearchHotkey(sc)
        }
        saveNow()
    }

    // MARK: - 自动适应内容宽高

    /// 分区默认基准宽度：根据设置（自适应均分或固定宽度）动态得出
    func standardPartitionWidth(for screen: NSScreen? = nil) -> CGFloat {
        if config.partitionWidthMode == "custom" {
            return config.customPartitionWidth
        }
        let scr = screen ?? referenceScreen()
        let cols = CGFloat(config.maxColumns)
        let gap: CGFloat = 16.0
        let totalGaps = (cols + 1) * gap
        let availableWidth = scr.frame.width > 0 ? scr.frame.width : 1920
        let calculated = floor((availableWidth - totalGaps) / cols)
        return max(200.0, calculated)
    }

    var defaultPartitionWidth: CGFloat {
        standardPartitionWidth(for: referenceScreen())
    }

    /// 「分区最小高度」的**实际生效值**：用户设定值再夹一层上限（屏幕可用高 - 60）。
    ///
    /// 只有下限没有上限时，填个 5000 就会让自适应结果 = 5000，窗口比屏幕还高，
    /// 而 `windowHeight` 的「屏幕可用高」那道夹取此时反而不起作用（两个下限取较大值）。
    func effectiveMinPartitionHeight(on screen: NSScreen? = nil) -> CGFloat {
        let scr = screen ?? referenceScreen()
        return PartitionMetrics.clampedUserMinHeight(config.minPartitionHeight,
                                                     visibleScreenHeight: scr.visibleFrame.height)
    }

    /// 设置面板写「分区最小高度」的唯一入口：夹到 `[140, 屏幕可用高 - 60]`。
    /// 与 `effectiveMinPartitionHeight` 同一套夹取口径 —— 否则会出现
    /// 「界面显示 5000、实际生效 990」这种对不上的情况。
    func setMinPartitionHeight(_ value: Int) {
        let scr = NSScreen.main ?? referenceScreen()
        let capped = PartitionMetrics.clampedUserMinHeight(CGFloat(value),
                                                           visibleScreenHeight: scr.visibleFrame.height)
        updateSetting("minPartitionHeight", value: Int(capped.rounded()))
    }

    /// 「分区默认高度」的**实际生效值**：同样夹一层上限（屏幕可用高 - 60）。
    ///
    /// ⚠️ 此前只有「最小高度」夹上限、默认高度不夹，于是填 5000 时
    /// 「最小高度 990 / 默认高度 5000」自相矛盾 —— 新建的分区照样比屏幕还高。
    /// 两个高度偏好必须共用 `clampedPartitionHeight` 这一条口径。
    func effectiveDefaultPartitionHeight(on screen: NSScreen? = nil) -> CGFloat {
        let scr = screen ?? referenceScreen()
        return PartitionMetrics.clampedPartitionHeight(config.defaultPartitionHeight,
                                                       visibleScreenHeight: scr.visibleFrame.height)
    }

    /// 设置面板写「分区默认高度」的唯一入口（与 `setMinPartitionHeight` 同口径）。
    func setDefaultPartitionHeight(_ value: Int) {
        let scr = NSScreen.main ?? referenceScreen()
        let capped = PartitionMetrics.clampedPartitionHeight(CGFloat(value),
                                                             visibleScreenHeight: scr.visibleFrame.height)
        updateSetting("defaultPartitionHeight", value: Int(capped.rounded()))
    }

    // MARK: - portal 当前浏览目录（内存态，不落盘）

    /// 每个 portal 分区**当前正在浏览**的目录。
    ///
    /// 子文件夹浏览是 `PortalView` 内部的 `@State`，AppDelegate 看不到；而「自适应宽高」
    /// 必须按**用户当前看到的内容**度量，否则在子文件夹里点自适应会拿根目录的条目数去算。
    /// 因此由 PortalView 在进入 / 退出子文件夹时上报，值为根目录时不留条目。
    private var portalBrowsePaths: [String: String] = [:]

    /// PortalView 上报的**文件操作上下文**（可见条目 / 选中条目 / 当前目录）。
    ///
    /// 键盘意图判据需要「当前选中了几个」才能回答，而选中态是 `PortalView` 内部的
    /// `@State`，AppDelegate 看不到 —— 所以由视图在选区变化时上报一份快照。
    /// 详见 `FileOperations.swift`。
    var portalContexts: [String: FileOpContext] = [:]

    /// PortalView 上报当前浏览路径（传根目录或空串 = 清除记录）。
    func setPortalBrowsePath(_ id: String, _ path: String) {
        let norm = normalizePath(path)
        if norm.isEmpty || norm == normalizePath(browseRootPath(id)) {
            portalBrowsePaths.removeValue(forKey: id)
        } else {
            portalBrowsePaths[id] = norm
        }
    }

    private func normalizePath(_ p: String) -> String {
        guard !p.isEmpty else { return "" }
        return (p as NSString).standardizingPath
    }

    /// 分区的内容根目录：portal = `folderPath`。
    func browseRootPath(_ id: String) -> String {
        return config.str("folderPath", of: id) ?? ""
    }

    /// 内容度量（自适应宽高）应采用的目录：正在浏览子文件夹时用子文件夹，否则用根目录。
    /// 记录失效（目录被删 / 映射路径被改 / 已不在根目录之下）时自动回退根目录。
    func effectiveBrowsePath(_ id: String) -> String {
        let root = browseRootPath(id)
        guard let sub = portalBrowsePaths[id], !sub.isEmpty else { return root }
        let rootNorm = normalizePath(root)
        guard !rootNorm.isEmpty, sub != rootNorm,
              sub.hasPrefix(rootNorm.hasSuffix("/") ? rootNorm : rootNorm + "/"),
              FileManager.default.fileExists(atPath: sub)
        else { return root }
        return sub
    }

    /// 自适应高度与宽高：
    /// - resetWidth 为 true 时（点击标题栏「自适应」按钮 / 双击右下角）：同时将宽度重置为初始宽度（280）；
    /// - resetWidth 为 false 时（双击分区底部）：仅自适应内容高度，保持当前宽度不变。
    ///
    /// ⚠️ 对 portal 必须按 `effectiveBrowsePath`（当前浏览目录）而不是配置里的根目录计数，
    /// 否则进入子文件夹后点自适应，会用最外层的条目数来设置高度。
    /// - parameter expandIfCollapsed: 折叠中的分区是否**顺势展开**。
    ///   只有「用户显式点自适应」的入口才传 true（标题栏按钮 / 双击底边 / 双击右下角）——
    ///   他想看内容，展开是符合预期的；而隐式触发（切网格⇄列表后重算、设置面板保存、
    ///   「所有分区自适应高度」批量）必须保持折叠，否则批量一次会把所有折叠分区全展开。
    func autoFitHeight(_ id: String, resetWidth: Bool = true, expandIfCollapsed: Bool = false) {
        // 双保险：双击底边/右下角的入口已在 PartitionPanel.sendEvent 里按锁提前 return，
        // 这里再拦一次是为了挡住标题栏按钮、托盘菜单与「全部/批量自适应」等其余入口。
        if blockedByLock(id, action: "自适应高度") { return }
        guard let panel = panels.first(where: { $0.partitionID == id }) else { return }
        let screen = panel.screen ?? referenceScreen()
        let targetW = resetWidth ? defaultPartitionWidth : CGFloat(config.num("width", of: id))
        let type = config.str("type", of: id) ?? ""

        // 内容高度口径全部集中在 PartitionMetrics（与视图侧的 padding / 行高一一对应）
        var contentH: CGFloat = 120
        switch type {
        case "notes":
            contentH = PartitionMetrics.notesContentHeight(
                text: config.str("noteContent", of: id) ?? "", width: targetW)
        case "todo":
            let todos = config.todos(of: id)
            let mode = config.str("todoFilterMode", of: id) ?? "all"
            let isExpanded = config.bool("isCompletedExpanded", of: id)

            let uncTodos: [TodoVM]
            let compTodos: [TodoVM]
            switch mode {
            case "active":
                uncTodos = todos.filter { !$0.completed }
                compTodos = []
            case "high":
                uncTodos = todos.filter { !$0.completed && $0.priority == "high" }
                compTodos = todos.filter { $0.completed && $0.priority == "high" }
            default:
                uncTodos = todos.filter { !$0.completed }
                compTodos = todos.filter { $0.completed }
            }

            // ⚠️ 判定折行必须用**实测字宽**（半角 7.2 / 全角 12.9），不能用「字符数 ÷ 13」：
            // 13 只对中文碰巧成立，英文/数字实际只有 7.2，每行容量被低估约 1.8 倍，
            // 于是没折行的英文待办会被误判成折行，每条多算 16pt。口径收在 PartitionMetrics。
            let multilineCount = PartitionMetrics.todoMultilineCount(
                texts: uncTodos.map { $0.text }, width: targetW)

            contentH = PartitionMetrics.todoContentHeight(
                uncompletedCount: uncTodos.count,
                completedCount: compTodos.count,
                isCompletedCollapsed: !isExpanded,
                multilineCount: multilineCount
            )
        case "portal":
            let path = effectiveBrowsePath(id)   // 子文件夹浏览中 → 用当前目录，而不是根目录
            let n = portalEntryCount(path)
            // ⚠️ 列表视图「一行一条」、网格视图「按 tile 宽换行」，两种布局的行数差好几倍 ——
            // 一律按网格算，会让列表视图下的自适应高度严重偏离（内容被裁或空出一大截）。
            let isList = (config.str("viewMode", of: id) ?? "grid") == "list"
            contentH = isList ? PartitionMetrics.listContentHeight(count: n)
                              : PartitionMetrics.gridContentHeight(count: n, width: targetW)
        default:
            contentH = 120
        }

        // 夹取口径走 `PartitionMetrics.windowHeight` —— 不再在这里手抄一遍。
        // ⚠️ 这里曾自己写 `min(max(header + contentH, minHeight), visibleFrame.height - 60)`，
        // 与 `windowHeight` 差一个 `max(minHeight, …)`，于是**单测覆盖的是另一条分支**
        // （测的是 `windowHeight`，跑的是这行手抄版）。同一口径只能有一处实现。
        let h = PartitionMetrics.windowHeight(contentHeight: contentH,
                                              visibleScreenHeight: screen.visibleFrame.height,
                                              minimumHeight: effectiveMinPartitionHeight(on: screen))

        // ⚠️ 折叠态默认**保持折叠**：此前这里无条件写 `isCollapsed = false`，
        // 于是跑一次「所有分区自适应高度」会把所有折叠中的分区一次性全部展开 ——
        // 折叠本来就是为了省地方。保持折叠时只更新「存储的展开高度」（下次展开即生效），
        // 屏幕上的窗口仍保持标题栏高度（44）；只有显式入口才顺势展开。
        let wasCollapsed = config.bool("isCollapsed", of: id)
        let collapsed = wasCollapsed && !expandIfCollapsed
        // 夹取位置要按**实际显示高度**算，折叠时用 44，否则会把折叠分区无谓地上移
        let displayH = collapsed ? PartitionMetrics.headerHeight : h

        // 越过屏幕右边缘时左移 x
        let curX = CGFloat(config.num("x", of: id))
        let maxX = screen.frame.width - targetW - 16
        let finalX = max(16, min(curX, maxX))

        // 越过屏幕底部时上移 y
        let curY = CGFloat(config.num("y", of: id))
        let maxY = screen.visibleFrame.height - displayH - 16
        let finalY = min(curY, max(24, maxY))

        config.updateUI { raw in
            guard var parts = raw["partitions"] as? [[String: Any]],
                  let i = parts.firstIndex(where: { ($0["id"] as? String) == id }) else { return }
            if resetWidth {
                parts[i]["width"] = Int(targetW.rounded())
            }
            parts[i]["height"] = Int(h.rounded())
            parts[i]["x"] = Int(finalX.rounded())
            parts[i]["y"] = Int(finalY.rounded())
            if wasCollapsed && expandIfCollapsed { parts[i]["isCollapsed"] = false }
            raw["partitions"] = parts
        }

        let o = nativeOrigin(screen, x: finalX, y: finalY, h: displayH)
        panel.setFrame(NSRect(x: o.x, y: o.y, width: targetW, height: displayH),
                       display: true, animate: false)
        refreshHitTest()
        saveSoon(0.2)
    }

    /// 初始化分区宽度（双击分区右边）：将宽度重置为初始宽度（280），保持高度不变。
    func resetPartitionWidth(_ id: String) {
        guard let panel = panels.first(where: { $0.partitionID == id }) else { return }
        let screen = panel.screen ?? referenceScreen()
        let targetW = defaultPartitionWidth
        let isCollapsed = config.bool("isCollapsed", of: id)
        let h = CGFloat(config.num("height", of: id))
        let displayH = isCollapsed ? 44 : h

        // 越过屏幕右边缘时左移 x
        let curX = CGFloat(config.num("x", of: id))
        let maxX = screen.frame.width - targetW - 16
        let finalX = max(16, min(curX, maxX))
        let curY = CGFloat(config.num("y", of: id))

        config.updateUI { raw in
            guard var parts = raw["partitions"] as? [[String: Any]],
                  let i = parts.firstIndex(where: { ($0["id"] as? String) == id }) else { return }
            parts[i]["width"] = Int(targetW.rounded())
            parts[i]["x"] = Int(finalX.rounded())
            raw["partitions"] = parts
        }

        let o = nativeOrigin(screen, x: finalX, y: curY, h: displayH)
        panel.setFrame(NSRect(x: o.x, y: o.y, width: targetW, height: displayH), display: true, animate: false)
        refreshHitTest()
        saveSoon(0.2)
    }

    private func portalEntryCount(_ path: String) -> Int {
        // 口径与 PortalView 的网格、标题栏徽标**同一份**（DirectoryScan）。
        // 这里手动写第二遍过滤规则，就是「网格 10 项、徽标 11」那类不一致的源头。
        DirectoryScan.visibleCount(in: path)
    }

    /// 「所有分区自适应高度」：只作用于**指定显示器**上的分区（默认 = 光标所在屏）。
    /// 多显示器下每屏独立，其他屏的分区保持原样。
    ///
    /// ⚠️ `resetWidth` 必须是 **false**：菜单名写的是「高度」，走默认的 true 会把每个分区的
    /// 宽度一并重置成标准宽度 —— 用户手工拖出来的宽度被一次批量操作抹掉，属于名实不符。
    /// 只在这个入口「只调高度」，标题栏「自适应**宽高**」按钮与双击右下角仍照旧重置宽度
    /// （那两个入口名字里就带"宽"，重置是它们的本意）。
    func autoFitAll(onScreenID sid: CGDirectDisplayID? = nil) {
        let scr = resolvedScreen(sid)
        let ids = partitionIDs(on: scr)
        let skipped = lockedOnes(ids)
        for id in ids where !isLocked(id) { autoFitHeight(id, resetWidth: false) }
        noteSkippedLocked(skipped.count, action: "自适应高度")
    }

    // MARK: - 待办增删改

    func addTodo(_ pid: String, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        config.updateUI { raw in
            guard var parts = raw["partitions"] as? [[String: Any]],
                  let i = parts.firstIndex(where: { ($0["id"] as? String) == pid }) else { return }
            var todos = parts[i]["todos"] as? [[String: Any]] ?? []
            todos.append(["id": UUID().uuidString, "text": t, "completed": false, "priority": "medium"])
            parts[i]["todos"] = todos
            raw["partitions"] = parts
        }
        saveSoon(0.2)
    }

    func removeTodo(_ pid: String, _ tid: String) {
        config.updateUI { raw in
            guard var parts = raw["partitions"] as? [[String: Any]],
                  let i = parts.firstIndex(where: { ($0["id"] as? String) == pid }),
                  var todos = parts[i]["todos"] as? [[String: Any]] else { return }
            todos.removeAll { ($0["id"] as? String) == tid }
            parts[i]["todos"] = todos
            raw["partitions"] = parts
        }
        saveSoon(0.2)
    }

    func setTodoText(_ pid: String, _ tid: String, _ text: String) {
        config.updateUI { raw in
            guard var parts = raw["partitions"] as? [[String: Any]],
                  let i = parts.firstIndex(where: { ($0["id"] as? String) == pid }),
                  var todos = parts[i]["todos"] as? [[String: Any]] else { return }
            for j in 0..<todos.count where (todos[j]["id"] as? String) == tid { todos[j]["text"] = text }
            parts[i]["todos"] = todos
            raw["partitions"] = parts
        }
        saveSoon(0.4)
    }

    func cycleTodoPriority(_ pid: String, _ tid: String) {
        config.updateUI { raw in
            guard var parts = raw["partitions"] as? [[String: Any]],
                  let i = parts.firstIndex(where: { ($0["id"] as? String) == pid }),
                  var todos = parts[i]["todos"] as? [[String: Any]] else { return }
            let order = ["high", "medium", "low"]
            for j in 0..<todos.count where (todos[j]["id"] as? String) == tid {
                let cur = (todos[j]["priority"] as? String) ?? "medium"
                let idx = order.firstIndex(of: cur) ?? 1
                todos[j]["priority"] = order[(idx + 1) % order.count]
            }
            parts[i]["todos"] = todos
            raw["partitions"] = parts
        }
        saveSoon(0.2)
    }

    func setTodoPriority(_ pid: String, _ tid: String, priority: String) {
        config.updateUI { raw in
            guard var parts = raw["partitions"] as? [[String: Any]],
                  let i = parts.firstIndex(where: { ($0["id"] as? String) == pid }),
                  var todos = parts[i]["todos"] as? [[String: Any]] else { return }
            for j in 0..<todos.count where (todos[j]["id"] as? String) == tid {
                todos[j]["priority"] = priority
            }
            parts[i]["todos"] = todos
            raw["partitions"] = parts
        }
        saveSoon(0.2)
    }

    func clearCompletedTodos(_ pid: String) {
        config.updateUI { raw in
            guard var parts = raw["partitions"] as? [[String: Any]],
                  let i = parts.firstIndex(where: { ($0["id"] as? String) == pid }),
                  var todos = parts[i]["todos"] as? [[String: Any]] else { return }
            todos.removeAll { ($0["completed"] as? Bool) == true }
            parts[i]["todos"] = todos
            raw["partitions"] = parts
        }
        saveSoon(0.2)
    }

    /// 待办事项拖拽重排序：把 sourceId 移动到 targetId 的位置
    func moveTodo(_ pid: String, from sourceId: String, to targetId: String) {
        guard sourceId != targetId else { return }
        config.updateUI { raw in
            guard var parts = raw["partitions"] as? [[String: Any]],
                  let i = parts.firstIndex(where: { ($0["id"] as? String) == pid }),
                  var todos = parts[i]["todos"] as? [[String: Any]] else { return }
            guard let fromIdx = todos.firstIndex(where: { ($0["id"] as? String) == sourceId }),
                  let toIdx = todos.firstIndex(where: { ($0["id"] as? String) == targetId }) else { return }
            let item = todos.remove(at: fromIdx)
            todos.insert(item, at: toIdx)
            parts[i]["todos"] = todos
            raw["partitions"] = parts
        }
        saveSoon(0.2)
    }

    // MARK: - 分区锁定

    /// 任一锁定生效（全局排版锁 or 本分区锁）→ 禁止拖动/缩放、隐藏缩放手柄。
    /// 分区是否被锁定 = **它所在显示器**的「锁定分区位置」 ‖ 分区自身的 `isLocked`。
    /// 全局锁按屏独立，所以这里要看分区所在屏，而不是某个全局开关。
    func isLocked(_ id: String) -> Bool {
        if let scr = panels.first(where: { $0.partitionID == id })?.screen,
           config.isScreenLocked(scr.displayID) {
            return true
        }
        return config.bool("isLocked", of: id)
    }

    func togglePartitionLock(_ id: String) {
        let next = !config.bool("isLocked", of: id)
        updatePartition(id, key: "isLocked", value: next)
    }

    // MARK: - 锁定拦截（锁定时不允许做任何改变）

    /// 被锁定时统一拦截：**弹一句结果提示 + 返回 true**，调用方直接 `return`。
    ///
    /// **拦截范围**（锁定 = 分区本身不可改）：
    /// 拖动、缩放（已在 `PartitionPanel` 层拦掉）、置顶、折叠/展开、高度自适应、
    /// 行内重命名、分区设置面板、删除，以及托盘菜单与批量操作里的同类条目。
    ///
    /// **不拦截**（属于「分区内容区的日常使用」，不是改分区自己）：
    /// 解锁本身、便签正文编辑、待办勾选与增删、排序与网格/列表切换、分区内文件拖出。
    /// 这条界线是刻意划的 —— 锁的目的防的是「手滑把分区挪了/缩了/折叠了」，
    /// 不是把分区变成只读板砖。
    ///
    /// - Parameter action: 用户能读懂的动作名（如「折叠/展开」），会拼进提示语里 ——
    ///   只说「已锁定」用户不知道**哪件事**没做成，会以为是自己点歪了。
    @discardableResult
    func blockedByLock(_ id: String, action: String) -> Bool {
        guard isLocked(id) else { return false }
        presentLockedHint(id, action: action)
        return true
    }

    /// 锁定时点任何功能按钮的提示。**要说清是哪一层锁** ——
    /// 分区锁和屏幕锁的解法完全不同，只提示「已锁定」会把用户引到解不开的地方。
    func presentLockedHint(_ id: String, action: String) {
        let screenLocked = panels.first(where: { $0.partitionID == id })?.screen
            .map { config.isScreenLocked($0.displayID) } ?? false
        let partitionLocked = config.bool("isLocked", of: id)

        let text: String
        let detail: String
        if screenLocked && partitionLocked {
            text = "本屏与分区均已锁定，无法\(action)"
            detail = "请先解锁本屏，再点标题栏的 🔓 解锁分区"
        } else if screenLocked {
            text = "本屏已锁定，无法\(action)"
            detail = "请先在导航栏或托盘菜单解锁本屏"
        } else {
            text = "分区已锁定，无法\(action)"
            detail = "请先点击标题栏的 🔓 解锁该分区"
        }

        let panel = panels.first(where: { $0.partitionID == id })
        Toast.shared.show(text, detail: detail, icon: "lock.fill",
                          on: panel?.screen, above: panel?.frame)
    }

    /// 批量 / 全局操作里被锁定的分区**静默跳过**，只提示一次总数 ——
    /// 逐个弹提示会把界面刷屏，用户反而看不清到底哪些没生效。
    private func noteSkippedLocked(_ count: Int, action: String) {
        guard count > 0 else { return }
        Toast.shared.show("已跳过 \(count) 个锁定分区",
                          detail: "解锁后才会\(action)",
                          icon: "lock.fill",
                          on: activeScreen())
    }

    /// 本屏分区里被锁定的那几个（供 `autoFitAll` / 批量操作跳过）。
    private func lockedOnes(_ ids: [String]) -> [String] { ids.filter { isLocked($0) } }

    // MARK: - 屏幕变化：把越界分区拉回可视区

    private var screenChangeDebounceWork: DispatchWorkItem? = nil

    private func startScreenObservation() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(screenParametersChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self,
                                                          selector: #selector(workspaceDidWake),
                                                          name: NSWorkspace.didWakeNotification,
                                                          object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self,
                                                          selector: #selector(workspaceDidWake),
                                                          name: NSWorkspace.screensDidWakeNotification,
                                                          object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self,
                                                          selector: #selector(workspaceWillSleep),
                                                          name: NSWorkspace.willSleepNotification,
                                                          object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self,
                                                          selector: #selector(workspaceScreensDidSleep),
                                                          name: NSWorkspace.screensDidSleepNotification,
                                                          object: nil)
    }

    @objc private func workspaceWillSleep() {
        // 系统即将休眠：主动修剪内存与缓存（AppIcons 缩略图、全局搜索目录、视图缓存）
        AppIcons.pruneCache()
        GlobalSearch.invalidateCache()
        config.invalidateAllViewCaches()
    }

    @objc private func workspaceScreensDidSleep() {
        AppIcons.pruneCache()
        GlobalSearch.invalidateCache()
    }

    @objc private func workspaceDidWake() {
        // 外接显示器休眠唤醒：硬件握手（EDID Handshake）需要 1.0~1.8 秒，
        // 延迟触发自愈以避免在中间态被挤压到内置屏幕
        screenChangeDebounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performScreenStabilizationAndHeal()
        }
        screenChangeDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    @objc private func screenParametersChanged() {
        screenChangeDebounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performScreenStabilizationAndHeal()
        }
        screenChangeDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func performScreenStabilizationAndHeal() {
        let alive = Set(NSScreen.screens.map { $0.displayID })
        guard !alive.isEmpty else { return }

        // 显示器插拔后清理失效的按屏状态（隐藏态、按屏对齐模式），避免 ID 被复用导致误判
        config.pruneHiddenScreens(keeping: alive)
        config.pruneScreenSettings(keeping: alive)
        // 布局预设的坐标是「相对某块屏」的，屏没了这份预设也就无法套用
        config.pruneLayoutPresets(keeping: alive)

        // 纠正/归位已归属到具体显示器的分区（外接屏断开拉回主屏，重连后归位）
        isProgrammaticMove = true
        let primary = referenceScreen()
        for panel in panels {
            let pid = panel.partitionID
            let sid = config.screenId(of: pid)
            let targetScr: NSScreen
            if let s = sid, alive.contains(s), let found = self.screen(id: s) {
                targetScr = found
            } else {
                targetScr = primary
                updatePartition(pid, key: "screenId", value: Int(primary.displayID))
            }

            if panel.screen?.displayID != targetScr.displayID {
                let x = CGFloat(config.num("x", of: pid))
                let y = CGFloat(config.num("y", of: pid))
                let h = CGFloat(config.num("height", of: pid))
                let collapsed = config.bool("isCollapsed", of: pid)
                let displayH: CGFloat = collapsed ? 44 : h
                let origin = nativeOrigin(targetScr, x: x, y: y, h: displayH)
                panel.setFrame(NSRect(origin: origin, size: panel.frame.size), display: true)
            }
        }
        isProgrammaticMove = false

        ensurePartitionsInBounds()
        // 顶栏与屏幕集合一一对应：按当前屏幕重建（新增屏补顶栏、拔掉的屏移除顶栏）
        rebuildTopBars()
        for (_, tb) in topBars { tb.orderFrontRegardless() }
        refreshHitTest()
    }

    /// 分辨率/显示器变化后，把跑到屏幕外的分区拉回来（只纠正越界，不动正常分区）。
    func ensurePartitionsInBounds() {
        let side: CGFloat = 16, bottom: CGFloat = 16

        var changed: [(String, CGFloat, CGFloat, NSScreen)] = []
        config.updateQuiet { raw in
            guard var parts = raw["partitions"] as? [[String: Any]] else { return }
            for i in 0..<parts.count {
                let id = (parts[i]["id"] as? String) ?? ""
                // 每个分区用「它自己所在屏幕」做越界纠正；
                // 全部钳到某一个屏幕会破坏多显示器布局（实测踩坑）。
                let screen = panels.first(where: { $0.partitionID == id })?.screen
                    ?? config.screenId(of: id).flatMap { self.screen(id: $0) }
                    ?? referenceScreen()
                let vf = screen.visibleFrame
                let w = Config.num(parts[i]["width"])
                let h = Config.num(parts[i]["height"])
                let collapsed = (parts[i]["isCollapsed"] as? Bool) ?? false
                // 折叠分区按实际高 44 做越界判断/定位（此函数只纠正越界，不参与布局占位）
                let displayH = collapsed ? 44 : h
                let x = Config.num(parts[i]["x"])
                let y = Config.num(parts[i]["y"])
                // visibleFrame 是 AppKit 左下原点；配置坐标是「屏幕左上原点」的相对距离，
                // 所以横向可用范围 = vf.width，纵向可用高度 = vf.height。
                let minX = side
                let maxX = vf.width - w - side
                let maxY = vf.height - displayH - bottom
                // 上边距按「该分区所在屏幕」计算（各屏顶栏位置一致，但保持同源）
                let top = visualTopMargin(for: screen)
                let nx = min(max(x, minX), max(minX, maxX))
                let ny = min(max(y, top), max(top, maxY))
                if nx != x || ny != y {
                    parts[i]["x"] = Int(nx.rounded())
                    parts[i]["y"] = Int(ny.rounded())
                    changed.append((id, CGFloat(nx), CGFloat(ny), screen))
                }
            }
            raw["partitions"] = parts
        }
        guard !changed.isEmpty else { return }
        // 同样是程序性移动：抑制 didMove 的吸附副作用
        isProgrammaticMove = true
        for (id, nx, ny, screen) in changed {
            guard let p = panels.first(where: { $0.partitionID == id }) else { continue }
            let h = CGFloat(config.num("height", of: id))
            let collapsed = config.bool("isCollapsed", of: id)
            let displayH: CGFloat = collapsed ? 44 : h
            let targetOrigin = nativeOrigin(screen, x: nx, y: ny, h: displayH)
            p.setFrame(NSRect(origin: targetOrigin, size: p.frame.size), display: true)
        }
        isProgrammaticMove = false
        saveSoon(0.3)
    }

    /// 新建分区时找一个不与现有分区重叠的空位（Electron 的自动避让）。
    /// 按**目标屏当前的对齐模式**找无重叠空位：top/grid 行优先（左上→右下）、
    /// left 列优先（排满一列再换列）、right 从右往左列优先。兜底级联偏移。
    func findFreeSlot(width w: CGFloat, height h: CGFloat,
                      on target: NSScreen? = nil) -> (x: CGFloat, y: CGFloat) {
        let screen = target ?? referenceScreen()
        let mode = config.alignMode(forScreen: screen.displayID)
        let margin = Layout.margin, gap = Layout.gap
        let top: CGFloat = visualTopMargin(for: screen)
        let maxX = screen.frame.width - margin
        let maxY = screen.frame.height - 40
        // 只统计**本屏**分区占位：其他屏的坐标是相对它们自己屏幕的，混进来会误判重叠
        let localIDs = Set(partitionIDs(on: screen))
        let rects: [NSRect] = config.partitions.compactMap {
            guard let id = $0["id"] as? String, localIDs.contains(id) else { return nil }
            return NSRect(x: Config.num($0["x"]), y: Config.num($0["y"]),
                          width: Config.num($0["width"]), height: Config.num($0["height"]))
        }
        let occupied: (NSRect) -> Bool = { cand in rects.contains { $0.intersects(cand) } }

        switch mode {
        case "left":
            var colX = margin
            while colX + w <= maxX {
                var y = top
                while y + h <= maxY {
                    if !occupied(NSRect(x: colX, y: y, width: w, height: h)) { return (colX, y) }
                    y += gap
                }
                colX += gap
            }
        case "right":
            var colX = maxX - w
            while colX >= margin {
                var y = top
                while y + h <= maxY {
                    if !occupied(NSRect(x: colX, y: y, width: w, height: h)) { return (colX, y) }
                    y += gap
                }
                colX -= gap
            }
        default:
            var y = top
            while y + h <= maxY {
                var x = margin
                while x + w <= maxX {
                    if !occupied(NSRect(x: x, y: y, width: w, height: h)) { return (x, y) }
                    x += gap
                }
                y += gap
            }
        }
        // 兜底：级联偏移
        let n = config.partitions.count
        return (x: margin + CGFloat(n % 8) * 40, y: top + CGFloat(n % 8) * 30)
    }

    func updateNote(_ id: String, _ text: String) {
        config.updateUI { raw in
            guard var parts = raw["partitions"] as? [[String: Any]],
                  let i = parts.firstIndex(where: { ($0["id"] as? String) == id }) else { return }
            parts[i]["noteContent"] = text
            raw["partitions"] = parts
        }
        saveSoon(0.5)
    }

    func toggleTodo(_ pid: String, _ tid: String) {
        config.updateUI { raw in
            guard var parts = raw["partitions"] as? [[String: Any]],
                  let i = parts.firstIndex(where: { ($0["id"] as? String) == pid }),
                  var todos = parts[i]["todos"] as? [[String: Any]] else { return }
            for j in 0..<todos.count where (todos[j]["id"] as? String) == tid {
                todos[j]["completed"] = !(todos[j]["completed"] as? Bool ?? false)
            }
            parts[i]["todos"] = todos
            raw["partitions"] = parts
        }
        saveSoon(0.2)
    }

    // MARK: - 拖动落盘

    @objc private func panelDidMove(_ n: Notification) {
        // hover 展开（hoverPeek）或正在缩放分区、或程序性重排移动窗口时：
        // 都不触发布局吸附与坐标覆写（程序重排的坐标已由 align 写入，且不该被吸附改写）。
        guard !isHoverPeeking && activeResizingID == nil && !isProgrammaticMove else { return }
        guard let panel = n.object as? PartitionPanel else { return }
        let id = panel.partitionID
        // 锁定分区不写位置、不吸附
        guard !isLocked(id) else { return }
        let screen = panel.screen ?? referenceScreen()
        let f = panel.frame
        // 窗口原生坐标 → 屏幕相对坐标（左上原点）
        let topY = screen.frame.origin.y + screen.frame.height - f.origin.y - f.height
        let relX = f.origin.x - screen.frame.origin.x
        // 分区被拖到另一块显示器时，同步更新它的屏幕归属
        // （坐标本身已按 panel.screen 换算，这里只补 screenId，保证重启后回到正确的屏）
        let newSid = screen.displayID
        let ownsScreen = (config.screenId(of: id) == newSid)
        config.updateQuiet { raw in
            guard var parts = raw["partitions"] as? [[String: Any]],
                  let i = parts.firstIndex(where: { ($0["id"] as? String) == id }) else { return }
            parts[i]["x"] = Int(relX.rounded())
            parts[i]["y"] = Int(topY.rounded())
            if !ownsScreen { parts[i]["screenId"] = Int(newSid) }
            raw["partitions"] = parts
        }
        saveSoon(0.4)

        // 拖动停止后 250ms 吸附（Alt/Option 键按住时跳过，允许自由摆放）。
        let snapEnabled = (config.settings["snapToEdges"] as? Bool) ?? true
        guard snapEnabled else { return }
        snapWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            if !NSEvent.modifierFlags.contains(.option) { self?.snapPartition(id) }
        }
        snapWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    // MARK: - 保存节流

    private func saveSoon(_ delay: TimeInterval) {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.config.save() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }
    private func saveNow() {
        saveWork?.cancel()
        config.save()
    }

    // MARK: - 分区图层动态切换与激活

    /// 点击选中指定分区：将该分区动态提升至普通窗口层级（.normal），其他未置顶分区降回桌面底层（.desktopLevel），
    /// 并激活应用使之成为 key window；置顶分区保持 .floating 始终在普通窗口和普通应用之上。
    func activatePartition(_ target: PartitionPanel) {
        for p in panels {
            if p === target {
                p.activateAsNormalWindow()
                p.orderFrontRegardless()
                p.makeKey()
            } else {
                p.deactivateToDesktop()
            }
        }
        // 记下「谁被临时抬起来了」：只有被记录的那一个会在失去 key 时自己降回去
        raisedPanelID = target.partitionID
        NSApp.activate(ignoringOtherApps: true)
        // 选区只活在「正在操作的那个分区」里：其余分区收到后各自清空自己的选中
        // （判据是纯函数 `FileSelectionScope.shouldClear`，别在这里手写比较）。
        NotificationCenter.default.post(name: .portalActivePartitionChanged,
                                        object: target.partitionID)
    }

    /// 依据分区 ID 激活分区（供菜单动作如重命名/新建文件夹激活键盘焦点）
    func activatePartition(_ id: String) {
        if let p = panels.first(where: { $0.partitionID == id }) {
            activatePartition(p)
        }
    }

    /// 将所有未置顶分区降回桌面底层（.desktopLevel）
    func deactivateNonPinnedPartitions() {
        for p in panels {
            p.deactivateToDesktop()
        }
        raisedPanelID = nil
        // ⚠️ object 传 nil = 「活跃的不在任何分区里」：点到桌面 / 别的应用 / 应用退活。
        // 此时**所有**分区的选区都失效 —— 不再有「某个分区还亮着一片选中」的错觉。
        NotificationCenter.default.post(name: .portalActivePartitionChanged, object: nil)
    }

    /// 分区窗口失去 key → 临时提升到此为止。
    ///
    /// 这条是**每个窗口自己**的不变量，与「应用是否退活」「模态框是否开着」这些外部状态无关。
    /// 之所以必须补上它：原来只有「应用退活」和「点到别处」两条路会降层，
    /// 两条路都要求应用级的事件流是通的 —— 一旦哪条被卡住（历史上就是被一个
    /// 已关闭的模态框引用卡死），提升态就再也没人收，用户看到的就是「分区莫名一直置顶」。
    @objc private func panelDidResignKey(_ note: Notification) {
        guard let panel = note.object as? PartitionPanel else { return }
        // ⚠️ 快速预览打开期间，分区失焦不降层，避免预览连播时界面闪烁和图层下沉
        if QuickPreview.shared.isShowing { return }
        if raisedPanelID == panel.partitionID { raisedPanelID = nil }
        panel.deactivateToDesktop()
    }

    @objc private func appDidResignActive() {
        if !isModalOpen {
            deactivateNonPinnedPartitions()
        }
        // 退活正是「窗口 active 状态变化」的时点：在此补一次 tooltip 策略
        applyToolTipPolicy()
    }

    // MARK: - 鼠标命中（点击穿透）

    /// 全局 / 本地两条鼠标监视链共用的事件类型。
    private static let mouseMonitorMask: NSEvent.EventTypeMask =
        [.mouseMoved, .leftMouseDown, .rightMouseDown, .leftMouseUp, .leftMouseDragged]

    /// （重新）安装全局鼠标监视器：管「光标在别的应用上移动 / 点击」时的命中裁决与降层。
    ///
    /// ⚠️ 授权状态变化后**必须重装**：未获辅助功能授权时 `addGlobalMonitorForEvents` 同样返回
    /// 非 nil 对象（只是不派发 mouseMoved），而拿到授权后这个旧对象不会自动开始工作 ——
    /// 只有重新注册才会真正收到事件。这也是 `refreshMouseMonitoring()` 存在的理由。
    private func installGlobalMouseMonitor() {
        if let old = globalMouse { NSEvent.removeMonitor(old); globalMouse = nil }
        globalMouse = NSEvent.addGlobalMonitorForEvents(matching: Self.mouseMonitorMask) { [weak self] e in
            guard let self else { return }
            self.refreshHitTest()
            if e.type == .leftMouseDown || e.type == .rightMouseDown {
                // ⚠️ globalMonitor 只会接收派发给「外部其它应用」的事件，绝不会收到发给 DeskIsle 自身窗口的事件。
                // 因此只要进入这里，就表明用户点击的是外部应用（如全屏/普通窗口 Chrome、终端等）或原生桌面。
                // 绝对不能在此处调用 activatePartition 抢焦点，否则外部应用覆盖分区时，点击重叠区域会误激活底层分区！
                if !self.isModalOpen {
                    let pt = NSEvent.mouseLocation
                    let hitTopBar = self.topBars.values.contains { self.shapeContains($0, pt) }
                    let hitPreview = QuickPreview.shared.isShowing && (QuickPreview.shared.panelFrame?.contains(pt) == true)
                    if !hitTopBar && !hitPreview {
                        self.deactivateNonPinnedPartitions()
                    }
                }
            }
        }
    }

    private func startMouseMonitors() {
        installGlobalMouseMonitor()
        localMouse = NSEvent.addLocalMonitorForEvents(matching: Self.mouseMonitorMask) { [weak self] e in
            self?.refreshHitTest()
            if e.type == .leftMouseDown, let w = e.window as? PartitionPanel {
                // 左键点击分区：激活应用并动态切换图层，使选中的未置顶分区升至 normal 覆盖普通应用，置顶分区依然在其上
                self?.activatePartition(w)
            } else if e.type == .rightMouseDown, let w = e.window as? PartitionPanel {
                // 右键点击分区：仅提升图层以防被遮挡，绝不能在此执行 makeKey / NSApp.activate，
                // 否则会触发应用激活和 key 窗口焦点切换，打断刚刚建立的上下文菜单追踪循环（产生菜单闪现）。
                w.activateAsNormalWindow()
                w.orderFrontRegardless()
                self?.raisedPanelID = w.partitionID
            }
            return e
        }
        // ⚠️ 全局监视器装不上或未获辅助功能授权时，必须启动光标轮询兜底，否则整个应用会点不动：
        // 未被命中的分区是 `ignoresMouseEvents = true`（穿透，桌面挂件本分），
        // 唯有 `refreshHitTest()` 能将其切回可交互。
        // 在 macOS 中，即使没有辅助功能授权，`addGlobalMonitorForEvents` 也会返回非空对象（但不会派发 mouseMoved），
        // 因此不能单凭 `globalMouse == nil` 判断，必须叠加 `AXIsProcessTrusted()`。
        if globalMouse == nil || !AXIsProcessTrusted() {
            startCursorFallbackPoll()
        }
    }

    /// 授权状态可能已变化（用户在系统设置里勾选 / 取消辅助功能）→ 重装全局监视器，
    /// 并据此重新决定还要不要轮询兜底。
    ///
    /// 这是**根治**路径：拿到授权后命中裁决转为纯事件驱动，轮询被 `stopCursorFallbackPoll()`
    /// 关掉，常驻唤醒归零；拿不到授权时至少回到自适应轮询（静止 1s / 活动 100ms）。
    func refreshMouseMonitoring() {
        installGlobalMouseMonitor()
        if AXIsProcessTrusted(), globalMouse != nil {
            stopCursorFallbackPoll()
        } else {
            startCursorFallbackPoll()
        }
    }

    /// 兜底：没有全局鼠标监视器或缺授权时，用轮询顶上命中裁决。
    ///
    /// ## ⚠️ 这里为什么只能是轮询（NSTrackingArea 结构性不可用）
    /// 未被命中的分区是 `ignoresMouseEvents = true`（穿透，桌面挂件本分），
    /// 而**穿透窗口收不到任何鼠标事件** —— 包括 tracking area 的 `mouseEntered`。
    /// 于是「光标从桌面进入分区」这个最该被感知的时刻，恰恰是窗口听不见的时刻。
    /// 真要事件驱动只能靠全局监视器，而那需要辅助功能授权。
    /// 所以轮询是**无授权时唯一可行的路径**，能做到的是让它尽可能便宜（见下）。
    ///
    /// ## 两档周期（自适应）
    /// 裁决结果只取决于「光标位置 + 窗口几何 + 隐藏屏集合」。三者都没变时
    /// 任何计算都是纯浪费（实测静止占绝大多数时间）：
    /// - 任一在变 → 100ms（保持手感）
    /// - 全部静止 → 1s（每秒确认一次「确实什么都没变」）
    /// 于是常驻唤醒从每秒 10 次降到 1 次；且静止那次是早退，几乎不耗 CPU。
    private var cursorPollWork: DispatchWorkItem?

    /// 快档周期（光标 / 窗口正在变化）
    private static let cursorPollActive: TimeInterval = 0.1
    /// 慢档周期（一切静止，只做「确认没变」）
    private static let cursorPollIdle: TimeInterval = 1.0

    private func startCursorFallbackPoll() {
        guard cursorPollWork == nil else { return }
        NSLog("[DeskIsle] 未获辅助功能/输入监控授权或全局监视器不可用 → 已启用光标轮询兜底（活动 %gs / 静止 %gs）",
              Self.cursorPollActive, Self.cursorPollIdle)
        scheduleCursorPoll(Self.cursorPollActive)
    }

    /// ⚠️ 用 `DispatchWorkItem` 递归调度而不是 `DispatchSourceTimer`：
    /// 周期要按「当前是否在动」逐次变化，而 timer 的 repeating 周期是创建时定死的，
    /// 改档必须销毁重建。递归 asyncAfter 每轮自选下一档，没有这个问题。
    private func scheduleCursorPoll(_ interval: TimeInterval) {
        cursorPollWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let changed = self.refreshHitTest()
            // 若后续获得了授权且全局监视器有效，平滑关闭轮询
            if self.globalMouse != nil && AXIsProcessTrusted() {
                self.stopCursorFallbackPoll()
                return
            }
            self.scheduleCursorPoll(changed ? Self.cursorPollActive : Self.cursorPollIdle)
        }
        cursorPollWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
    }

    private func stopCursorFallbackPoll() {
        cursorPollWork?.cancel()
        cursorPollWork = nil
        NSLog("[DeskIsle] 已检测到辅助功能授权就位 → 已关闭光标轮询兜底，转为纯事件驱动")
    }

    /// 命中裁决的**全部输入**。三者一致 ⇒ 裁决结果必然一致 ⇒ 可以早退。
    private struct HitState: Equatable {
        var point: NSPoint
        var frames: [CGRect]
        var levels: [Int]
        var hiddenScreens: Set<CGDirectDisplayID>
    }

    private var lastHitState: HitState?

    /// 重新裁决「光标现在压在哪个窗口上」，并据此切换各窗口的穿透态。
    ///
    /// - Returns: 是否真的做了计算。`false` = 早退（输入与上次逐项相同）。
    @discardableResult
    private func refreshHitTest() -> Bool {
        let pt = NSEvent.mouseLocation
        // 顶栏按 displayID 排序：字典遍历顺序不定，不排序的话几何签名会无故抖动，永远命中不了早退
        let bars = topBars.keys.sorted().compactMap { topBars[$0] }
        var frames: [CGRect] = []
        var levels: [Int] = []
        frames.reserveCapacity(bars.count + panels.count)
        levels.reserveCapacity(bars.count + panels.count)
        for tb in bars { frames.append(tb.frame); levels.append(tb.level.rawValue) }
        for p in panels { frames.append(p.frame); levels.append(p.level.rawValue) }

        let state = HitState(point: pt, frames: frames, levels: levels, hiddenScreens: config.hiddenScreens)
        if let last = lastHitState, last == state { return false }
        lastHitState = state

        // 顶栏恒参与命中：其显隐由 showTopBar 独立控制，与分区显隐无关。
        var ordered: [NSWindow] = bars
        // 分区按屏独立显隐：跳过「所在显示器当前已隐藏」的分区，
        // 其余屏幕的分区照常参与命中（不再用全局 guard 一刀切）。
        let sortedPanels = panels.enumerated()
            .filter { !config.isScreenHidden($0.element.screen?.displayID ?? 0) }
            .sorted { a, b in
                if a.element.level.rawValue != b.element.level.rawValue {
                    return a.element.level.rawValue > b.element.level.rawValue
                }
                return a.offset < b.offset
            }
            .map(\.element)
        ordered.append(contentsOf: sortedPanels)

        var hit: NSWindow?
        for w in ordered where shapeContains(w, pt) { hit = w; break }

        for p in panels {
            let isHidden = config.isScreenHidden(p.screen?.displayID ?? 0)
            if p.ignoresMouseEvents != isHidden {
                p.ignoresMouseEvents = isHidden
            }
        }
        for tb in bars {
            let should = (hit === tb)
            if tb.ignoresMouseEvents == should { tb.ignoresMouseEvents = !should }
        }
        return true
    }

    /// 光标是否落在窗口的**可见形状**内（圆角矩形 + 四角缩放手柄）。
    ///
    /// ⚠️ 刻意不建 `NSBezierPath`：命中裁决每秒要跑 10 次 × 窗口数，建对象 + 曲线求值
    /// 比闭式解高一个量级。圆角矩形有闭式解 —— 四个角各自只需一次「到圆心距离 ≤ 半径」。
    private func shapeContains(_ w: NSWindow, _ pt: NSPoint) -> Bool {
        let r = w.frame
        guard r.contains(pt) else { return false }
        let corner: CGFloat = (w as? PartitionPanel)?.cornerRadius ?? Look.cornerRadius
        // 窗口比两个圆角还小时四角区域会重叠，闭式解的分角判定不再可靠 → 退化为矩形
        guard corner > 0, r.width > corner * 2, r.height > corner * 2 else { return true }

        let x = pt.x - r.minX
        let y = pt.y - r.minY
        let right = r.width - corner
        let top = r.height - corner
        let inCorner = { (dx: CGFloat, dy: CGFloat) -> Bool in dx * dx + dy * dy <= corner * corner }

        let inside: Bool
        if x < corner && y < corner { inside = inCorner(corner - x, corner - y) }
        else if x > right && y < corner { inside = inCorner(x - right, corner - y) }
        else if x < corner && y > top { inside = inCorner(corner - x, y - top) }
        else if x > right && y > top { inside = inCorner(x - right, y - top) }
        else { inside = true }
        if inside { return true }

        // 四角 16px 方形（8 向缩放手柄的角手柄区域）：角手柄落在圆角**切掉**的那部分，
        // 若不额外命中，光标从桌面进入角手柄时 shapeContains=false → 窗口穿透 → 手柄不触发。
        // ⚠️ 这条只能作为「圆角之外的叠加命中区」，不能并进上面的闭式解 —— 那是取反关系。
        let c: CGFloat = 16
        let gripCorners: [NSRect] = [
            NSRect(x: 0, y: 0, width: c, height: c),
            NSRect(x: r.width - c, y: 0, width: c, height: c),
            NSRect(x: 0, y: r.height - c, width: c, height: c),
            NSRect(x: r.width - c, y: r.height - c, width: c, height: c),
        ]
        return gripCorners.contains { $0.contains(NSPoint(x: x, y: y)) }
    }

    // MARK: - 全局快捷键（`settings.globalShortcut`，默认 ⌘⌥D）

    /// 当前生效的快捷键。注册失败会回退到上一个可用值。
    private(set) var currentShortcut: Shortcut = .default

    /// 从当前配置重新同步全局快捷键（初次注册或配置热重载时调用）
    func syncHotkeysFromConfig() {
        if let s = config.globalShortcutPersisted, let parsed = Shortcut(persisted: s) {
            currentShortcut = parsed
        } else {
            currentShortcut = .default
        }
        installHotkey(currentShortcut)

        // 搜索快捷键用**另一个热点 ID**，与「显示/隐藏」区分开。
        // 两个键各占一个 id，回调里按 id 分派（见 hotKeyHandler）。
        if let s = config.searchShortcutPersisted, let parsed = Shortcut(persisted: s) {
            searchShortcut = parsed
        } else {
            searchShortcut = .searchDefault
        }
        installSearchHotkey(searchShortcut)
    }

    private func registerHotkey() {
        syncHotkeysFromConfig()

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &spec, nil, nil)
    }

    @discardableResult
    private func installHotkey(_ sc: Shortcut) -> Bool {
        if let old = hotKeyRef { UnregisterEventHotKey(old); hotKeyRef = nil }
        var ref: EventHotKeyRef?
        let st = RegisterEventHotKey(sc.keyCode, sc.carbonMods,
                                     EventHotKeyID(signature: OSType(0x44494B31), id: 1),
                                     GetApplicationEventTarget(), 0, &ref)
        if st == noErr { hotKeyRef = ref; currentShortcut = sc; return true }
        return false
    }

    // MARK: - 搜索快捷键（`settings.searchShortcut`，默认 ⌘⌥F）

    /// 当前生效的搜索快捷键。注册失败会回退到上一个可用值。
    private(set) var searchShortcut: Shortcut = .searchDefault

    @discardableResult
    private func installSearchHotkey(_ sc: Shortcut) -> Bool {
        if let old = searchHotKeyRef { UnregisterEventHotKey(old); searchHotKeyRef = nil }
        var ref: EventHotKeyRef?
        let st = RegisterEventHotKey(sc.keyCode, sc.carbonMods,
                                     EventHotKeyID(signature: OSType(0x44494B31), id: 2),
                                     GetApplicationEventTarget(), 0, &ref)
        if st == noErr { searchHotKeyRef = ref; searchShortcut = sc; return true }
        return false
    }

    /// 设置搜索快捷键：注册失败则回滚旧键并回传错误文案（与主快捷键一致）。
    @discardableResult
    func setSearchShortcut(_ sc: Shortcut) -> (ok: Bool, message: String) {
        let previous = searchShortcut
        if installSearchHotkey(sc) {
            updateSetting("searchShortcut", value: sc.persisted)
            return (true, "已设置为 \(sc.display)")
        }
        _ = installSearchHotkey(previous)
        return (false, "快捷键 \(sc.display) 注册失败（可能被系统或其他应用占用），已保留 \(previous.display)")
    }

    /// 设置新快捷键：注册失败则回滚旧键并回传错误文案（与 Electron 的回滚行为一致）。
    @discardableResult
    func setGlobalShortcut(_ sc: Shortcut) -> (ok: Bool, message: String) {
        let previous = currentShortcut
        if installHotkey(sc) {
            updateSetting("globalShortcut", value: sc.persisted)
            return (true, "已设置为 \(sc.display)")
        }
        _ = installHotkey(previous)
        return (false, "快捷键 \(sc.display) 注册失败（可能被系统或其他应用占用），已保留 \(previous.display)")
    }

    // MARK: - 内容探测（portal 自动刷新）
    //
    // 全应用只跑**一个**定时器（FolderWatcher，2s 节拍）。
    // 历史上这里是各分区各自轮询，分区越多定时器越多，已合并到一处。

    private let folderWatcher = FolderWatcher()

    /// 重建探测目标。portal 提供映射目录（另有 30s 低频指纹层，见 FolderWatcher）。
    func startFolderWatching() {
        folderWatcher.isActive = { [weak self] id in
            self?.isPartitionWorthWatching(id) ?? false
        }
        folderWatcher.onChange = { [weak self] id in
            // 目录内容变了 → 标题栏徽标的数字大概率也变了。
            // **先作废缓存再发通知**：视图收到通知重算 body 时就能拿到新数字，
            // 否则它只会命中旧缓存，要等 5s 兜底 TTL 到期才更新。
            self?.config.invalidateBadge(id)
            NotificationCenter.default.post(name: .portalFolderChanged, object: id)
        }
        // 事件相关性判据要的是「当前正在显示哪个目录」——现取，所以进出子目录
        // 不需要重建监听（重建会白跑一遍指纹）。
        folderWatcher.displayedPath = { [weak self] id in
            self?.effectiveBrowsePath(id) ?? ""
        }
        folderWatcher.update(partitions: config.partitions) { [weak self] id, type in
            guard let self = self else { return "" }
            return self.config.str("folderPath", of: id) ?? ""
        }
        folderWatcher.start()
    }

    /// 列表重读后同步刷新标题栏徽标。
    ///
    /// 徽标显示的就是这份列表的条目数，列表重读了它必须跟着重算 ——
    /// 只清缓存不触发重画是无效的（原因见 `Config.invalidateBadge` 的注释），
    /// 那正是「上面写 11、下面列 10」能一直挂着的成因。
    func refreshPortalBadge(_ id: String) {
        config.invalidateBadge(id)
    }

    /// 该分区当前是否值得做内容探测。
    /// 已折叠（内容不显示）、所在屏处于隐藏态（幽灵模式）的分区一律跳过 —— 省电。
    private func isPartitionWorthWatching(_ id: String) -> Bool {
        guard let p = config.partition(id) else { return false }
        if Config.bool(p["isCollapsed"]) { return false }
        if let sid = p["screenId"] as? Int, config.isScreenHidden(CGDirectDisplayID(sid)) {
            return false
        }
        return true
    }

    private func stopFolderWatching() {
        folderWatcher.stop()
    }
}

/// Carbon 全局热键回调。
///
/// 两个热键共用一个回调，靠 `EventHotKeyID.id` 区分：1 = 显示/隐藏分区，2 = 全局搜索。
/// 不按 id 分派的话，按搜索键会去切换显隐 —— 症状轻微但很莫名其妙。
private func hotKeyHandler(_ callRef: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    var hkID = EventHotKeyID()
    let err = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                EventParamType(typeEventHotKeyID), nil,
                                MemoryLayout<EventHotKeyID>.size, nil, &hkID)
    guard err == noErr else {
        AppDelegate.shared?.toggleGhost()
        return noErr
    }
    switch hkID.id {
    case 2:  AppDelegate.shared?.openGlobalSearch()
    default: AppDelegate.shared?.toggleGhost()
    }
    return noErr
}

/// 配置目录的 FSEvents 回调。
///
/// 与 `FolderWatcher` 那支同理：回调必须是 C 函数指针、不能捕获上下文，
/// 因此做成文件作用域常量，靠 `context.info` 把 AppDelegate 实例带回来。
private let configFSEventCallback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
    guard let info, numEvents > 0 else { return }
    let app = Unmanaged<AppDelegate>.fromOpaque(info).takeUnretainedValue()
    let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
    app.handleConfigEvent(paths: paths)
}
