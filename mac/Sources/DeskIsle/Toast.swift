import AppKit
import SwiftUI

/// 轻量瞬时提示：一个无边框小胶囊，1.8s 后自动淡出；同一时刻只存在一个。
///
/// **为什么不用 `NSAlert`**：锁定拦截属于「高频误触」场景 —— 用户会连点好几个图标，
/// 每次都弹模态框既打断操作又必须手动关掉，比「什么都没发生」还烦。
/// **为什么不能只靠 `.help`**：系统气泡提示要悬停约 1 秒才出现，
/// 用户点完没反应就已经认定「这个按钮坏了」，不会再去悬停。
///
/// 窗口本身 `ignoresMouseEvents = true`，纯展示、不吃点击 —— 提示盖在分区上也不会
/// 挡住下面的标题栏按钮（用户可以立刻补点一次「解锁」）。
final class Toast {

    static let shared = Toast()

    /// 提示内容。用 ObservableObject 而不是每次重建 hostingView：
    /// 连续点击时只是**改文字并重置倒计时**，窗口不重建，不会出现「淡出淡入闪一下」。
    final class Model: ObservableObject {
        @Published var icon = "lock.fill"
        @Published var text = ""
        @Published var detail = ""
        @Published var emphasized = true   // 图标用橙色（警示）还是灰色（普通说明）
    }

    private let model = Model()
    private var panel: NSPanel?
    private var host: NSHostingView<AnyView>?
    private var dismissWork: DispatchWorkItem?

    /// 固定尺寸 + 透明：胶囊本体按内容自适应并居中，外面的多余留白不可见也不吃点击，
    /// 于是不需要（也无法可靠地）在 SwiftUI 状态刚写入的同一帧里量出真实尺寸
    /// —— ObservableObject 的变更要到下一个 runloop 才反映到 `fittingSize` 上。
    private static let panelSize = NSSize(width: 420, height: 76)
    private static let linger: TimeInterval = 1.8

    private init() {}

    /// 在 `anchor`（AppKit **全局**坐标）所在位置下方弹出。
    /// - Parameters:
    ///   - anchor: 一般是分区窗口的 `frame`；传 nil 则落在屏幕可视区顶部居中。
    ///   - screen: 目标屏；nil 时用锚点所在屏，再退回主屏。
    func show(_ text: String,
              detail: String = "",
              icon: String = "lock.fill",
              emphasized: Bool = true,
              on screen: NSScreen? = nil,
              above anchor: NSRect? = nil) {
        model.text = text
        model.detail = detail
        model.icon = icon
        model.emphasized = emphasized

        let p = ensurePanel()
        let size = Self.panelSize
        p.setContentSize(size)
        p.setFrameOrigin(origin(for: size, anchor: anchor, screen: screen))
        p.alphaValue = 0
        p.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            p.animator().alphaValue = 1
        }

        // 连续触发时重置倒计时（而不是叠出多个提示）
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.linger, execute: work)
    }

    /// 立刻收起（例如打开设置面板、开始拖拽时）。
    func hide() {
        dismissWork?.cancel()
        dismissWork = nil
        guard let p = panel, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            p.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
        }
    }

    // MARK: - 内部

    private func ensurePanel() -> NSPanel {
        if let p = panel { return p }

        let host = NSHostingView(rootView: AnyView(ToastView(model: model)))
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        p.contentView = host
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.ignoresMouseEvents = true        // 纯提示：不吃点击，下面的按钮照常可点
        p.hidesOnDeactivate = false
        p.animationBehavior = .none
        p.level = .statusBar               // 高于置顶分区（.floating）与设置面板（.modalPanel）
        // 全屏 Space 与所有桌面都要能看到（与项目内其他弹窗的约定一致）
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        self.host = host
        panel = p
        return p
    }

    private func origin(for size: NSSize, anchor: NSRect?, screen: NSScreen?) -> NSPoint {
        let scr = screen
            ?? anchor.flatMap { a in NSScreen.screens.first { $0.frame.intersects(a) } }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visible = scr?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var x: CGFloat
        var y: CGFloat
        if let a = anchor {
            // 贴着分区**顶边下方**：提示正好落在刚点的那排按钮下面，视线不用移开
            x = a.midX - size.width / 2
            y = a.maxY - size.height - 10
        } else {
            x = visible.midX - size.width / 2
            y = visible.maxY - size.height - 24
        }
        // 夹回可视区（分区贴着屏幕边缘时提示不能被推到屏幕外）
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)
        return NSPoint(x: x, y: y)
    }
}

// MARK: - 视图

private struct ToastView: View {
    @ObservedObject var model: Toast.Model

    var body: some View {
        VStack {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: model.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(model.emphasized ? Color.orange : Color.secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(model.text)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !model.detail.isEmpty {
                        Text(model.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
            )
            // 胶囊按内容自适应，而不是被外面的固定窗口尺寸拉伸
            .fixedSize()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
