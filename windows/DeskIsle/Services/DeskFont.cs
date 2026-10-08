namespace DeskIsle.Services
{
    /// <summary>
    /// 顶栏与分区标题栏的**唯一字号来源**。
    ///
    /// 与 mac 的 <c>DeskFont</c>（<c>PartitionPanel.swift</c>）、Electron 的 <c>utils/deskFont.ts</c>
    /// 三端同口径 —— 值都一样，改一处必须三端同改。
    ///
    /// 为什么要抽出来：这两排 UI 在视觉上是同一条水平带（顶栏胶囊 / 各分区标题栏），
    /// 但分居两个 XAML 文件，各写一个 <c>FontSize</c> 时极易悄悄分叉（一个 12、一个 12.5，
    /// 差 0.5pt 也看得出「不齐」），而改一处根本不会想起另一处。
    ///
    /// ⚠️ 本端图标是 Segoe MDL2 Assets，mac 是 SF Symbols —— **同一数值下字形的视觉大小并不相同**；
    /// 而且单位本身也不同（WPF 是 DIP = 1/96 英寸，mac 是排版 pt = 1/72 英寸，严格换算要 ×1.3333）。
    /// **这里刻意按 1:1 沿用 mac 的数值**：历史散落值（图标 11/13、标题 12、品牌图标 15）与 mac 的
    /// 10/11.5/12.5 本就互有参差，统一成同一组数字后，要让两端视觉对齐**只需在这一处微调**，
    /// 而不用回到两个 XAML 里逐个改。要在真机上微调时，改这里。
    ///
    /// ⚠️ 刻意**不引入任何 WPF 类型**（不用 <c>FontWeight</c>）：
    /// <c>tests/DeskIsle.Tests</c> 是 <c>net8.0</c>（无 Windows 基金会程序集），
    /// 链了 WPF 类型就编译不过，三端契约断言也就没法写了。
    /// </summary>
    public static class DeskFont
    {
        /// <summary>顶栏品牌名、分区标题正文（mac：12.5 semibold）。</summary>
        public static double Header => 12.5;

        /// <summary>顶栏图标按钮（mac：11.5）。</summary>
        public static double TopIcon => 11.5;

        /// <summary>分区标题栏图标按钮（mac：10 semibold，比顶栏更小 —— 标题栏按钮更密）。</summary>
        public static double HeaderIcon => 10;

        /// <summary>顶栏品牌图标、分区标题前的类型 emoji（mac：12.5）。</summary>
        public static double Glyph => 12.5;

        /// <summary>分区标题右侧的数字徽标（mac：10 medium）。</summary>
        public static double Badge => 10;
    }
}
