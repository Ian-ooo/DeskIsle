import AppKit

/// 包（应用 / `.pages` / `.bundle` …）的**真实图标**。
///
/// SF Symbols 只能表达「这是个包」，表达不了「这是**哪个**应用」——
/// 而映射文件夹里常常排着一整列应用，用户正是靠图标一眼认出目标。
/// 访达同理：`.app` 显示应用自己的图标，而不是一个通用方块。
///
/// 实现要点：
/// - 走 `NSWorkspace.icon(forFile:)`：按**路径**取图标，对 `.app` 就是应用图标，
///   对 `.pages` / `.numbers` 是文档图标，对 `.bundle` 等是各自注册的图标 ——
///   一份实现覆盖所有包类型，不必自己维护映射。
/// - 外面再套一层 `NSCache`：`NSWorkspace` 内部虽有缓存，每次调用仍要走一遍
///   LaunchServices 查表；而 SwiftUI 的 `body` 会在**任何**状态变化时重算，
///   「一个分区里 10 个应用 × 每次重绘查表 10 次」累积起来是能感觉到的卡顿。
/// - 缓存键带上尺寸：图标对象按尺寸设好逻辑大小后缓存，避免把大位图
///   在每次绘制时重新缩放进 14pt 的列表行。
enum AppIcons {

    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        // 按内存而非数量淘汰：大图标（512px²）与小图标（14px²）占内存相差约 1300 倍，
        // 纯按数量淘汰时大图标会把小图标全挤走，导致反复取小图标时 cache miss 率很高。
        // 40 MB 能覆盖约 500 张 28×28 RGBA 图标，远超实际分区条目数，且对系统内存无感知压力。
        c.totalCostLimit = 40 * 1024 * 1024   // 40 MB
        return c
    }()

    /// 取某个路径的图标，并按请求尺寸设好逻辑大小。
    ///
    /// 取不到（路径为空 / 系统没有该类型的图标）时返回 `nil`，
    /// 由调用方退回 SF Symbol —— 至少风格仍是 DeskIsle 自己的。
    static func icon(forPath path: String, size: CGFloat) -> NSImage? {
        guard !path.isEmpty, size > 0 else { return nil }
        let key = "\(Int(size.rounded()))|\(path)" as NSString
        if let hit = cache.object(forKey: key) { return hit }

        let source = NSWorkspace.shared.icon(forFile: path)
        guard source.isValid, source.size.width > 0 else { return nil }
        // 复制一份再改 size：`icon(forFile:)` 返回的对象可能被系统在多处共享，
        // 就地改它的 `size` 会波及别的使用者（例如访达自己的图标缓存）。
        guard let copy = source.copy() as? NSImage else { return nil }
        copy.size = NSSize(width: size, height: size)
        // cost = 逻辑像素面积 × 4 字节/像素（RGBA），让 totalCostLimit 能精确核算内存。
        // NSWorkspace 内部图标原始尺寸通常是 512×512（`size` 字段是逻辑大小，与此无关），
        // 这里用请求的 `size` 估算：实际渲染尺寸与 DPI 有关，估算值已足够用于淘汰决策。
        let cost = Int(size * size) * 4
        cache.setObject(copy, forKey: key, cost: cost)
        return copy
    }

    /// 修剪/清空图标缓存（系统休眠、内存告警时自动释放内存）。
    static func pruneCache() {
        cache.removeAllObjects()
    }
}
