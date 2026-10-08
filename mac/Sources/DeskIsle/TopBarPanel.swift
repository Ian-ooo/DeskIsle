import AppKit
import Combine
import SwiftUI

/// 顶栏窗口：常驻浮层，承载导航栏（新建 / 搜索 / 显隐 ｜ 对齐 ｜ 隐藏导航栏 / 设置 / 退出）。
final class TopBarPanel: NSPanel {
    /// 顶栏胶囊高度。
    static let height: CGFloat = 44
    /// 顶栏顶部离屏幕顶端的固定偏移：必须 > 菜单栏高度，保证普通桌面顶栏落在
    /// 菜单栏下方（可见），且与全屏 Space 中「离物理顶端同样距离」绝对位置一致。
    static let topInset: CGFloat = 40

    /// 顶栏胶囊宽度**下界**：内容更窄也不缩到这个值以下（否则品牌名一被压短、
    /// 整条顶栏跟着缩，每次状态变化都会左右跳一下，反而更扎眼）。
    static let minWidth: CGFloat = 460
    /// 左右至少留出的空间，防止顶栏在窄屏上贴边。
    static let maxWidthInset: CGFloat = 40

    /// 本顶栏所属显示器。多显示器下每屏一个顶栏实例，各自只控制本屏分区。
    let screenID: CGDirectDisplayID

    /// 订阅配置变化以重算宽度（按钮增减会改变内容宽度）。
    private var fitObserver: AnyCancellable?

    init(screen: NSScreen, hasPinned: Bool, config: Config,
         onToggleHide: @escaping () -> Void,
         onAlign: @escaping (String) -> Void,
         onAdd: @escaping () -> Void,
         onSettings: @escaping () -> Void,
         onHideTopBar: @escaping () -> Void,
         onQuit: @escaping () -> Void) {
        self.screenID = screen.displayID
        // 先用下界建窗口，真正的宽度在 contentView 挂上后由 refreshFit() 按内容算。
        let w = TopBarPanel.minWidth
        let h = TopBarPanel.height
        // 悬浮胶囊：屏幕顶部居中、离顶端固定 topInset（普通桌面与全屏 Space 位置一致）
        let frame = NSRect(x: screen.frame.origin.x + (screen.frame.width - w) / 2,
                           y: screen.frame.origin.y + screen.frame.height - h - TopBarPanel.topInset,
                           width: w, height: h)

        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = false

        // 与 PartitionPanel 同源：顶栏是用户「不点击也会悬停」的地方，
        // 必须让 tooltip 在应用位于后台时也能显示（默认 false，见 PartitionPanel 的说明）。
        allowsToolTipsWhenApplicationIsInactive = true

        // 顶栏窗口语义与分区完全对齐（level 也由这里统一设置）：
        // 有置顶分区 → .floating + fullScreenAuxiliary，跟随进入全屏 Space 浮在其上；
        // 无置顶分区 → .desktopLevel + canJoinAllSpaces，与未置顶分区一样在全屏 Space 让位。
        // （实测：仅移除 fullScreenAuxiliary 对 accessory 应用不生效——floating 层级照样
        //  进全屏 Space 并浮在其上；必须把 level 一并降回桌面层才能让位。）
        applyFullScreenAuxiliary(hasPinned)

        contentView = NSHostingView(rootView: TopBarView(config: config,
                                                         screenID: screen.displayID,
                                                         onToggleHide: onToggleHide,
                                                         onAlign: onAlign,
                                                         onAdd: onAdd,
                                                         onSettings: onSettings,
                                                         onHideTopBar: onHideTopBar,
                                                         onQuit: onQuit))

        refreshFit()

        // 配置一变就重算：按钮个数、品牌文案长度都会影响宽度。
        // 用 receive(on: RunLoop.main) 延到下一个 runloop —— objectWillChange 在**值写入前**发出，
        // 当场算会拿到旧数据。
        fitObserver = config.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshFit() }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// 置顶态联动：顶栏是否跟随进入全屏 Space 由「是否存在置顶分区」决定，
    /// level 与 collectionBehavior 一起切换（与分区 applyPinned 同一套语义）。
    func applyFullScreenAuxiliary(_ on: Bool) {
        level = on ? .floating : .desktopLevel
        collectionBehavior = on
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.canJoinAllSpaces]
    }

    /// 按内容重算顶栏宽度并保持顶部居中。
    ///
    /// 固定宽度是历史遗留：按钮从 4 个长到 13 个后，SwiftUI 只能去压缩品牌名 ——
    /// 实测理想宽 475pt > 固定 460pt，多出来的 15pt 就把「DeskIsle」挤成了两行。
    /// 改为自适应后，再往顶栏加按钮也不用回来改常量。
    func refreshFit() {
        guard let host = contentView else { return }
        host.layoutSubtreeIfNeeded()
        let ideal = host.fittingSize.width
        // 视图还没完成布局（或测量异常）时保持原状，等下一次配置变化再算。
        guard ideal > 40 else { return }
        guard let scr = NSScreen.screens.first(where: { $0.displayID == screenID }) ?? NSScreen.main
        else { return }

        let w = min(max(ideal.rounded(.up), TopBarPanel.minWidth),
                    max(TopBarPanel.minWidth, scr.frame.width - TopBarPanel.maxWidthInset))
        let h = TopBarPanel.height
        let target = NSRect(x: scr.frame.origin.x + (scr.frame.width - w) / 2,
                            y: scr.frame.origin.y + scr.frame.height - h - TopBarPanel.topInset,
                            width: w, height: h)

        // 宽度没变就不动窗口：拖动分区时配置会被频繁写入，避免顶栏跟着连续 setFrame 抖动。
        let moved = abs(frame.width - target.width) > 0.5
            || abs(frame.origin.x - target.origin.x) > 0.5
            || abs(frame.origin.y - target.origin.y) > 0.5
        guard moved else { return }
        setFrame(target, display: true)
    }
}
