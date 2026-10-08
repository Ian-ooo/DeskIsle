import CoreGraphics

/// 「拖拽调整大小」时那个显示 `宽 × 高` 的胶囊的落位规格。
///
/// **为什么要抽成纯函数**：桌面自上而下挂满 IDE / 聊天窗口时，真机上的桌面挂件
/// （layer 为负，永远在最底下）根本没法用合成鼠标去拖 —— 目标点顶层是 IntelliJ IDEA，
/// 合成点击会打到它的窗口上（实测受阻，见本轮验证）。
/// 而「贴哪个角、留多少边距」恰恰是**一眼可见却最容易写错**的部分：
/// `contentView` 是**左下原点**，右下角很容易被算成左上角。
/// 把这部分唯一的算术抽出来单测，就把「看不见画面」造成的损失压到最小。
public enum SizeHUD {
    public static let padX: CGFloat = 7
    public static let padY: CGFloat = 3
    /// 胶囊距分区边缘的内缩，取 10pt（与标题栏常用内边距同量级，观感不挤）
    public static var margin: CGFloat { 10 }

    /// - Note: `contentView` 坐标系是**左下原点**，所以「右下角」= x 靠右、**y 靠下**。
    /// - Returns: 胶囊的 frame（内容过小时宽度/高度会被夹住，保证不越出分区）。
    public static func frame(contentWidth: CGFloat, contentHeight: CGFloat,
                             labelWidth: CGFloat, labelHeight: CGFloat) -> CGRect {
        let w = labelWidth + padX * 2
        let h = labelHeight + padY * 2
        let x = max(0, min(contentWidth - w - margin, contentWidth - w))
        return CGRect(
            x: x,
            y: min(margin, max(0, contentHeight - h)),
            width: min(w, max(0, contentWidth - margin * 2)),
            height: min(h, max(0, contentHeight - margin * 2))
        )
    }

    /// 胶囊内文字 label 的 frame（相对胶囊自身）。
    public static func labelFrame(labelWidth: CGFloat, labelHeight: CGFloat) -> CGRect {
        CGRect(x: padX, y: padY, width: labelWidth, height: labelHeight)
    }
}
