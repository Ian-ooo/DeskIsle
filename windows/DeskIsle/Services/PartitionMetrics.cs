using System;

namespace DeskIsle.Services
{
    /// <summary>
    /// 分区内容高度的计算口径。
    ///
    /// ⚠️ **算法与 mac 的 `DeskIsleLayout/PartitionMetrics`、Electron 的
    /// `utils/partitionMetrics.ts` 三端同源**（逐行硬换行 + 全角/半角差异权重）。
    /// 但**常数必须按各端自己的渲染参数标定** —— 三端编辑器的字号与留白本来就不同，
    /// 硬套同一组数会算不准：
    ///
    /// | | mac（TextEditor） | Electron（textarea） | Windows（TextBox） |
    /// |---|---|---|---|
    /// | 字号 | 13pt 系统字体 | 12px `text-xs` + `font-mono` | 12px Segoe UI |
    /// | 行高 | 16（实测 15.31 向上取整） | 19.5（`leading-relaxed`） | 16 |
    /// | 每侧留白 | 13 | 12 | 17 |
    ///
    /// 本端常数按 <c>Controls/NotesView.xaml</c> 的样式推算：
    /// <c>FontSize=12</c> · <c>TextBox Padding=8</c> · 外层 <c>Grid Margin="8,4,8,8"</c> · <c>Border 1px</c>。
    /// **改了 NotesView.xaml 的这几项就必须回头同步这里**，否则「自适应宽高」会留白过多或被裁切。
    ///
    /// ⚠️ 历史坑（修复前 <c>AutoFit</c> 对便签是写死的 <c>Math.Clamp(180, 160, 600)</c>，
    /// 压根不看内容）：一份 21 行的账号清单点「自适应宽高」永远只有 180 高，内容被裁掉大半。
    /// </summary>
    public static class PartitionMetrics
    {
        /// <summary>分区标题栏高度（折叠态窗口高度也是它）。</summary>
        public const double HeaderHeight = 44;

        /// <summary>分区最小高度。</summary>
        public const double MinHeight = 140;

        // ── 待办（todo）度量 ──────────────────────────────────────────────
        // 按 Controls/TodoView.xaml 推算：
        // - 顶部输入框行（Border Padding 4×2 + TextBox 16 + Border 2 + Margin 4）≈ 30
        // - 筛选栏（StackPanel Margin + RadioButton 18 + Margin 2）≈ 24
        // - ScrollViewer 留白（Margin 8,2,8,4）≈ 6
        // 固定开销 TodoChromeHeight = 30 + 24 + 6 = 60
        // 条目 ItemBorder（内容 16~18 + Padding 4×2 + Margin 2×2 + Border 2 ⇒ 30）
        // 折叠分组条「已完成 (N)」：26
        // 空状态占位高度：64

        /// <summary>顶部输入行 + 筛选栏 + 列表外边距固定总高度。</summary>
        public const double TodoChromeHeight = 60;

        /// <summary>待办单条目高度（Border 30px）。</summary>
        public const double TodoRowHeight = 30;

        /// <summary>折叠的「已完成 (N)」分组头高度。</summary>
        public const double TodoCompletedHeaderHeight = 26;

        /// <summary>空状态占位高度。</summary>
        public const double TodoEmptyContentHeight = 64;

        /// <summary>待办内容区高度（支持未完成数、已完成数与折叠状态）。</summary>
        public static double TodoContentHeight(int uncompletedCount, int completedCount = 0, bool isCompletedCollapsed = true)
        {
            int unc = Math.Max(0, uncompletedCount);
            int comp = Math.Max(0, completedCount);
            if (unc == 0 && comp == 0)
            {
                return TodoChromeHeight + TodoEmptyContentHeight;
            }

            double h = TodoChromeHeight + unc * TodoRowHeight;
            if (comp > 0)
            {
                h += TodoCompletedHeaderHeight;
                if (!isCompletedCollapsed)
                {
                    h += comp * TodoRowHeight;
                }
            }
            return h;
        }

        /// <summary>待办内容区简易版本（全部按单行未完成项计算，兼容旧签名）。</summary>
        public static double TodoContentHeight(int count)
        {
            int c = Math.Max(0, count);
            if (c == 0) return TodoChromeHeight + TodoEmptyContentHeight;
            return TodoChromeHeight + c * TodoRowHeight;
        }

        // ── 目录类（portal）度量 ─────────────────────
        //
        // 按 <c>Controls/PortalView.xaml</c> 推算：面包屑行（≈20 + Margin 4）+ 工具栏行（24 + Margin 6）
        // + 条目行（内容 16 + Padding 4×2 + Margin 2×2 ⇒ 28）+ 外层 Grid 下 Margin 8。
        //
        // ⚠️ **本端目前只有列表一种条目布局**（「网格」按钮只切换字形，不改 ItemsPanel），
        // 所以是「一行一条」；mac 的 <c>gridContentHeight</c> 会按 tile 宽算每行列数，
        // 两端行数不同是**布局差异**而非口径差异 —— 别把 mac 的 gridTileWidth 抄过来。
        //
        // ⚠️ 也因此：mac 的 AutoFit **必须按 viewMode 分派**（grid 用 gridContentHeight、
        // list 用 listContentHeight），本端则恒定用列表口径。若将来本端引入真正的网格布局，
        // 记得同步加分派 —— 否则网格下会按列表行数算，高度差好几倍。

        /// <summary>目录类分区的面包屑 + 工具条总高。</summary>
        public const double ListChromeHeight = 54;

        /// <summary>目录类分区单条目行高。</summary>
        public const double ListRowHeight = 28;

        /// <summary>目录类分区底部留白（外层 Grid 的 Margin 下 8）。</summary>
        public const double ListBottomPadding = 8;

        /// <summary>目录类分区**内容区**高度（不含标题栏）。</summary>
        public static double ListContentHeight(int count)
        {
            return ListChromeHeight + Math.Max(0, count) * ListRowHeight + ListBottomPadding;
        }

        /// <summary>
        /// 用户可填的**任一分区高度**的统一夹取：硬下限 140，上限 = 屏幕可用高 - 60。
        ///
        /// 「分区默认高度」与「分区最小高度」共用这一条 —— 只给最小高度夹上限、默认高度不管时，
        /// 填 5000 会出现「最小高度 990 / 默认高度 5000」的自相矛盾：新建的分区照样比屏幕还高。
        /// 与 mac 的 <c>PartitionMetrics.clampedPartitionHeight</c> 同源。
        /// </summary>
        public static double ClampedPartitionHeight(double value, double visibleScreenHeight)
        {
            double cap = Math.Max(140.0, visibleScreenHeight - 60);
            return Math.Min(Math.Max(140.0, value), cap);
        }

        /// <summary>
        /// 用户「分区最小高度」的**上限夹取**：不得超过屏幕可用高 - 60；硬下限 140。
        ///
        /// 没有这条时，用户填 5000 就会让自适应结果 = 5000、窗口比屏幕还高，
        /// 而 <see cref="WindowHeight"/> 那道「屏幕可用高」夹取此时反而不起作用
        /// （两个下限取较大值，5000 反而成了结果）。与 mac 的
        /// <c>PartitionMetrics.clampedUserMinHeight</c> 同源。
        /// </summary>
        public static double ClampedUserMinHeight(double userMin, double visibleScreenHeight)
            => ClampedPartitionHeight(userMin, visibleScreenHeight);

        /// <summary>
        /// 窗口高度 = 标题栏 + 内容，并夹在 <c>[下限, 屏幕可用高 - 60]</c> 之间。
        ///
        /// ⚠️ **「自适应高度」只能用这一个夹取口径**（mac 同名函数、Electron
        /// <c>partitionMetrics.windowHeight</c> 同）。历史上调用方自己手抄一遍公式，
        /// 与这里差一个 <c>max(MinHeight, …)</c>，结果单测覆盖的和实际跑的不是同一条分支。
        /// </summary>
        /// <param name="minimumHeight">用户设置的下限（全局偏好「分区最小高度」）；省略时退回基准 <see cref="MinHeight"/>。</param>
        /// <remarks>
        /// ⚠️ 内外两个下限是分开的：<see cref="MinHeight"/> 是渲染上的物理底线（再矮内容就画不下了），
        /// <paramref name="minimumHeight"/> 是用户偏好。用户可以把下限抬高到 400，但压不到 100 ——
        /// 夹取时取两者**较大值**，因此「最小高度」只能往上收紧，不会把窗口压坏。
        /// </remarks>
        public static double WindowHeight(double contentHeight, double visibleScreenHeight, double? minimumHeight = null)
        {
            double floor = Math.Max(MinHeight, minimumHeight ?? MinHeight);
            double maxAllowed = Math.Max(floor, visibleScreenHeight - 60);
            return Math.Min(Math.Max(HeaderHeight + contentHeight, floor), maxAllowed);
        }

        // ── 便签（notes）度量 ──────────────────────────────────────────────

        /// <summary>便签行高：12px Segoe UI ≈ 16。</summary>
        public const double NotesLineHeight = 16;

        /// <summary>便签文本**每侧**留白：Grid 8 + TextBox Padding 8 + Border 1。</summary>
        public const double NotesSidePadding = 17;

        /// <summary>便签文本上下留白：Grid 上 4 / 下 8 + Padding 16 + Border 2。</summary>
        public const double NotesVerticalPadding = 30;

        /// <summary>12px Segoe UI 下的**半角**字符平均宽度。</summary>
        public const double NotesHalfWidth = 6.6;

        /// <summary>12px 下的**全角**字符宽度（CJK 由系统字体回退渲染，约 1em）。</summary>
        public const double NotesFullWidth = 12.0;

        /// <summary>便签**内容区**高度（不含标题栏）。</summary>
        public static double NotesContentHeight(string? text, double width)
        {
            return NotesVisualLineCount(text, width) * NotesLineHeight + NotesVerticalPadding;
        }

        /// <summary>
        /// 便签文本在给定宽度下占用的**视觉行数**（硬换行 + 自动折行，空行也占一行）。
        ///
        /// ⚠️ 两个坑，缺一都会让「自适应宽高」形同虚设：
        /// 1. **<c>\n</c> 是硬换行**，必须一行算一行。用「总字符数 ÷ 每行容量」滚动估算
        ///    会把多行清单（如账号列表）压成两三行；
        /// 2. **中文（全角）宽度约为半角的 1.8 倍**，统一按半角算会让中文段落严重低估。
        /// </summary>
        public static int NotesVisualLineCount(string? text, double width)
        {
            if (string.IsNullOrEmpty(text)) return 1;

            double available = Math.Max(NotesFullWidth, width - 2 * NotesSidePadding);
            int lines = 0;
            foreach (var raw in text!.Split('\n'))
            {
                // 兼容 Windows 换行：尾部 `\r` 不是可见字符，不能计宽
                var line = raw.EndsWith("\r", StringComparison.Ordinal)
                    ? raw.Substring(0, raw.Length - 1)
                    : raw;
                lines += WrappedLineCount(line, available);
            }
            return Math.Max(1, lines);
        }

        /// <summary>单行（无 <c>\n</c>）占用的视觉行数：空行也占 1 行。</summary>
        private static int WrappedLineCount(string line, double available)
        {
            if (line.Length == 0) return 1;
            double w = VisualWidth(line);
            if (w <= 0) return 1;
            return Math.Max(1, (int)Math.Ceiling(w / available));
        }

        /// <summary>按「半角 6.6 / 全角 12.0」累加出的显示宽度（DIP）。</summary>
        private static double VisualWidth(string line)
        {
            double w = 0;
            for (int i = 0; i < line.Length; i++)
            {
                char c = line[i];
                // 代理对（Emoji / CJK 扩展 B）：按**一个**全角宽计，且只前进一格
                if (char.IsHighSurrogate(c) && i + 1 < line.Length && char.IsLowSurrogate(line[i + 1]))
                {
                    w += NotesFullWidth;
                    i++;
                    continue;
                }
                w += IsFullWidth(c) ? NotesFullWidth : NotesHalfWidth;
            }
            return w;
        }

        /// <summary>
        /// 是否按「全角」计宽：CJK / 假名 / 韩文 / 全角标点。
        /// 用的是常见 East Asian Width 区段近似 —— 只用于高度估算，不必逐字符精确。
        /// 注：CJK 扩展 B 与 Emoji 以代理对出现，已在 <see cref="VisualWidth"/> 里单独处理。
        /// </summary>
        public static bool IsFullWidth(char c)
        {
            int v = c;
            return (v >= 0x1100 && v <= 0x115F)      // 韩文字母
                || (v >= 0x2E80 && v <= 0x33FF)      // CJK 部首 · 康熙部首 · 中日韩符号 · 假名 · 注音
                || (v >= 0x3400 && v <= 0x4DBF)      // CJK 扩展 A
                || (v >= 0x4E00 && v <= 0x9FFF)      // CJK 统一表意
                || (v >= 0xA000 && v <= 0xA4CF)      // 彝文
                || (v >= 0xAC00 && v <= 0xD7A3)      // 韩文音节
                || (v >= 0xF900 && v <= 0xFAFF)      // CJK 兼容表意
                || (v >= 0xFE30 && v <= 0xFE6F)      // CJK 兼容形式
                || (v >= 0xFF00 && v <= 0xFF60)      // 全角 ASCII / 全角标点
                || (v >= 0xFFE0 && v <= 0xFFE6);     // 全角货币符号等
        }
    }
}
