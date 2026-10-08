import Foundation
import CoreGraphics

/// 三端共享的排版基准。
///
/// ⚠️ **`align` / `snapPartition` / `findFreeSlot` / `ensurePartitionsInBounds` 必须全部引用这里**，
/// 不允许任何一处自己写数值 —— 历史上 `snapPartition` 曾自用 `margin=24 / gap=12`，
/// 直接导致「新建分区间隔偏小、换行后与左侧间隔偏大」。
public enum Layout {
    public static let margin: CGFloat = 16
    public static let gap: CGFloat = 16
}

/// 分区尺寸与内容高度的计算口径。
/// 全部为纯函数（无副作用、不读全局状态），因此可以直接单测 —— 见 `Tests/DeskIsleLayoutTests`。
///
/// ⚠️ 这里的常数同时被**视图布局**（`PartitionView` 的 padding / 行高）与
/// **自适应高度**（`AppDelegate.autoFitHeight`）使用。改任意一个都必须同步另一边，
/// 否则会出现「点了自适应，但内容还是被裁剪 / 留白过多」。
public enum PartitionMetrics {
    /// 标题栏固定高度（折叠态窗口高度也是它）
    public static let headerHeight: CGFloat = 44
    /// 分区最小高度
    public static let minHeight: CGFloat = 150
    /// 网格视图内边距（上下各一半，见 `gridContentHeight` 的 `2 × gridPadding`）
    public static let gridPadding: CGFloat = 10
    /// 网格单行高度（tile 高 64 + 行间距 10，见 `PartitionView` 的 grid）
    public static let gridRowHeight: CGFloat = 74
    /// 网格 tile 的最小宽度（决定每行几列）
    public static let gridTileWidth: CGFloat = 82
    /// 内容区顶部的工具栏高度
    public static let gridToolbarHeight: CGFloat = 28

    // MARK: 便签（notes）度量
    //
    // 下面这几个常数是**在 13pt 系统字体下实测标定**的（不是拍脑袋）：
    //   · 行高：`ascent(12.568) − descent(−2.742) = 15.31`，向上取整 **16**；
    //     实测 21 行文本排版高度 = 336 = 21 × 16，逐行相加与整段一致（无额外段间距）。
    //   · 半角：`192.168.102.193` 实测 6.52/字符、`root oFcHQb3Z` 7.26、字母 a 7.10 → 取 **7.2**。
    //   · 全角：汉字「字」实测 12.90/字符（≈ 字号 13 × 0.99）→ 取 **12.9**。
    //
    // ⚠️ 曾经这里只有一个 `charWidth = 7.2` 并按 `text.count / 每行容量` 估算，
    // 于是中文被低估 1.79 倍、**硬换行 `\n` 被完全忽略**：一份 21 行的账号清单
    // 被算成 4 行 → 高度 104 → 被 `minHeight`(150) 夹住 → 用户点「自适应宽高」**一个像素都不动**。

    /// 便签文本左右留白（`TextEditor` 的 `.padding(8)` + `NSTextView` 的 `lineFragmentPadding`）
    public static let notesSidePadding: CGFloat = 13
    /// 便签行高（13pt 系统字体实测 15.31，向上取整）
    public static let notesLineHeight: CGFloat = 16
    /// 便签文本上下留白与底部字数状态栏固定高度（留白 16 + 底部状态栏 18 = 34）
    public static let notesVerticalPadding: CGFloat = 34
    /// 13pt 下**半角**字符平均宽度（实测）
    public static let notesHalfWidth: CGFloat = 7.2
    /// 13pt 下**全角**字符宽度（实测）
    public static let notesFullWidth: CGFloat = 12.9

    /// 每行能放几个 tile：可用宽度 ÷ tile 最小宽度，向下取整，至少 1 列。
    public static func gridColumns(width: CGFloat) -> Int {
        max(1, Int((width - 2 * gridPadding) / gridTileWidth))
    }

    /// portal 的内容高度 = 工具栏 + 行数 × 行高 + 上下留白。
    public static func gridContentHeight(count: Int, width: CGFloat) -> CGFloat {
        let cols = gridColumns(width: width)
        let rows = Int(ceil(Double(max(0, count)) / Double(cols)))
        return gridToolbarHeight + CGFloat(rows) * gridRowHeight + 2 * gridPadding
    }

    /// 列表视图单行高度：行内容（12pt 文本行高 ≈ 15 + 上下 padding 5×2 = 25）
    /// + `VStack(spacing: 2)` ⇒ 27，向上取整 **28**（与 Windows `ListRowHeight` 同值）。
    ///
    /// ⚠️ 列表是「一行一条」，网格是「按 tile 宽换行」—— 两者行数差好几倍。
    /// 自适应时按错了视图口径，就会出现「30 个文件只给了 3 行的高度 / 空出一大截」。
    public static let listRowHeight: CGFloat = 28

    /// portal **列表视图**的内容高度 = 工具栏 + 条目数 × 行高 + 上下留白（与网格同为 10×2）。
    public static func listContentHeight(count: Int) -> CGFloat {
        gridToolbarHeight + CGFloat(max(0, count)) * listRowHeight + 2 * gridPadding
    }

    /// 用户可填的**任一分区高度**的统一夹取：硬下限 140，上限 = 屏幕可用高 - 60。
    ///
    /// 「分区默认高度」与「分区最小高度」共用这一条 —— 只给最小高度夹上限、默认高度不管时，
    /// 填 5000 会出现「最小高度被夹成 990、默认高度仍是 5000」的自相矛盾：
    /// 新建的分区照样比屏幕还高，而「未设置时最小高度跟随默认高度」这条承诺也对不上。
    public static func clampedPartitionHeight(_ value: CGFloat, visibleScreenHeight: CGFloat) -> CGFloat {
        let cap = max(140.0, visibleScreenHeight - 60)
        return min(max(140.0, value), cap)
    }

    /// 用户「分区最小高度」的**上限夹取**：不得超过屏幕可用高 - 60。
    ///
    /// 没有这条时，用户填 5000 就会让自适应把窗口顶得比屏幕还高（且此时 `windowHeight`
    /// 的上限也失效 —— 两个下限取较大值，5000 反而成了结果）。
    /// 硬下限 140 与「分区默认高度」的可输入下限一致，两端同值。
    public static func clampedUserMinHeight(_ userMin: CGFloat, visibleScreenHeight: CGFloat) -> CGFloat {
        clampedPartitionHeight(userMin, visibleScreenHeight: visibleScreenHeight)
    }

    /// 便签内容高度：**先按 `\n` 硬换行拆行，再对每行按显示宽度估算折行数**。
    ///
    /// ⚠️ 两个历史坑，缺一都会让「自适应宽高」形同虚设：
    /// 1. **`\n` 是硬换行**，必须一行算一行。用 `text.count / 每行容量` 滚动估算会把
    ///    多行清单（如账号列表）压成两三行；
    /// 2. **中文（全角）宽度是半角的 1.79 倍**，统一按 7.2 算会让中文段落严重低估。
    public static func notesContentHeight(text: String, width: CGFloat) -> CGFloat {
        let lines = notesVisualLineCount(text: text, width: width)
        return CGFloat(lines) * notesLineHeight + notesVerticalPadding
    }

    /// 便签文本在给定宽度下占用的**视觉行数**（硬换行 + 自动折行，空行也占一行）。
    public static func notesVisualLineCount(text: String, width: CGFloat) -> Int {
        let available = max(notesFullWidth, width - 2 * notesSidePadding)
        var lines = 0
        for raw in text.components(separatedBy: "\n") {
            // 兼容从别处粘进来的 CRLF —— 尾部的 `\r` 不是可见字符，不能计宽
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            lines += wrappedLineCount(line, available: available)
        }
        return max(1, lines)
    }

    /// 单行（无 `\n`）占用的视觉行数：空行也占 1 行。
    static func wrappedLineCount(_ line: String, available: CGFloat) -> Int {
        if line.isEmpty { return 1 }
        let w = visualWidth(of: line)
        guard w > 0 else { return 1 }
        return max(1, Int(ceil(Double(w) / Double(available))))
    }

    /// 按「半角 7.2 / 全角 12.9」累加出的显示宽度（点）。
    static func visualWidth(of line: String) -> CGFloat {
        var w: CGFloat = 0
        for scalar in line.unicodeScalars {
            w += isFullWidth(scalar.value) ? notesFullWidth : notesHalfWidth
        }
        return w
    }

    /// 是否按「全角」计宽：CJK / 假名 / 韩文 / 全角标点 / Emoji。
    /// 用的是常见 East Asian Width 区段近似 —— 只用于高度估算，不必逐字符精确。
    static func isFullWidth(_ value: UInt32) -> Bool {
        switch value {
        case 0x1100...0x115F,      // 韩文字母
             0x2E80...0x33FF,      // CJK 部首 · 康熙部首 · 中日韩符号 · 假名 · 注音
             0x3400...0x4DBF,      // CJK 扩展 A
             0x4E00...0x9FFF,      // CJK 统一表意
             0xA000...0xA4CF,      // 彝文
             0xAC00...0xD7A3,      // 韩文音节
             0xF900...0xFAFF,      // CJK 兼容表意
             0xFE30...0xFE6F,      // CJK 兼容形式
             0xFF00...0xFF60,      // 全角 ASCII / 全角标点
             0xFFE0...0xFFE6,      // 全角货币符号等
             0x1F000...0x1FAFF,    // Emoji（13pt 下约合一个全角宽）
             0x20000...0x3FFFD:    // CJK 扩展 B 及以后
            return true
        default:
            return false
        }
    }

    // ── 待办（todo）度量 ──────────────────────────────────────────────
    // 按 TodoView.swift 实测渲染：
    // - 顶部输入框行：TextField 18 + padding 12 = 30
    // - 筛选栏：按钮 16 + padding 4 + bottom 4 = 24
    // - 分割线与间距：1
    // - ScrollView 垂直边距：8
    // 固定开销 todoChromeHeight = 30 + 24 + 1 + 8 = 63
    // 单条目 TodoRow：字号 13 (行高 18) + padding 8 + VStack spacing 2 = 28
    // 折叠分组条「已完成 (N)」：26
    // 空状态「暂无待办」图表：68

    /// 待办内容区固定组件总高度（输入栏 + 筛选栏 + 分割线 + 列表留白）
    public static let todoChromeHeight: CGFloat = 63

    /// 待办单条目高度
    public static let todoRowHeight: CGFloat = 28

    /// 待办长文本多行额外高度（折行 2 行时）
    public static let todoMultilineExtraHeight: CGFloat = 16

    /// 折叠的「已完成 (N)」分组头高度
    public static let todoCompletedHeaderHeight: CGFloat = 26

    /// 空状态占位高度
    public static let todoEmptyContentHeight: CGFloat = 68

    /// 待办条目里**文本能用**的宽度 = 整行宽 − 勾选框 / 优先级点 / 间距 / 外边距等固定占位。
    ///
    /// 原先这个 77 是写在 `AppDelegate.autoFitHeight` 里的裸数字，改视图就要回去翻调用点。
    /// 收在这里是为了让「待办」这一块的所有度量和「便签 / 网格 / 列表」一样有单一来源。
    public static let todoRowReservedWidth: CGFloat = 77

    /// 待办条目里**会折成两行**的条数（`TodoRow` 是 `.lineLimit(2)`，最多两行）。
    ///
    /// ⚠️ 判定必须用**实测字宽**（半角 7.2 / 全角 12.9），不能像原先那样
    /// 用「字符数 > 可用宽 ÷ 13」。13 只对中文碰巧成立（全角实测 12.9），
    /// 英文 / 数字实际只有 7.2 —— 每行容量被低估约 1.8 倍，
    /// 于是大量**根本没折行的英文待办被误判成折行**，每条多算 16pt，自适应出来底部空一大截。
    ///
    /// Windows 侧不参与：它的 `DisplayText` 是 `TextTrimming="CharacterEllipsis"`
    /// 单行截断，本来就不会折行，不需要这项补偿。
    public static func todoMultilineCount(texts: [String], width: CGFloat) -> Int {
        let available = max(notesFullWidth, width - todoRowReservedWidth)
        return texts.filter { visualWidth(of: $0) > available }.count
    }

    /// 待办内容高度完整计算（支持区分未完成数、已完成数与折叠状态）
    public static func todoContentHeight(
        uncompletedCount: Int,
        completedCount: Int = 0,
        isCompletedCollapsed: Bool = true,
        multilineCount: Int = 0
    ) -> CGFloat {
        let unc = max(0, uncompletedCount)
        let comp = max(0, completedCount)

        if unc == 0 && comp == 0 {
            return todoChromeHeight + todoEmptyContentHeight
        }

        var h = todoChromeHeight + CGFloat(unc) * todoRowHeight + CGFloat(max(0, multilineCount)) * todoMultilineExtraHeight
        if comp > 0 {
            h += todoCompletedHeaderHeight
            if !isCompletedCollapsed {
                h += CGFloat(comp) * todoRowHeight
            }
        }
        return h
    }

    /// 待办内容高度简易版本（兼容单参数调用与基准测试）
    public static func todoContentHeight(count: Int) -> CGFloat {
        let c = max(0, count)
        if c == 0 {
            return todoChromeHeight + todoEmptyContentHeight
        }
        return todoChromeHeight + CGFloat(c) * todoRowHeight
    }

    /// 窗口高度 = 标题栏 + 内容，并夹在 [下限, 屏幕可用高 - 60] 之间。
    ///
    /// - parameter minimumHeight: **用户设置的下限**（全局偏好「分区最小高度」）。
    ///   省略时退回内置基准 `minHeight`。
    ///
    /// ⚠️ 内外两个下限是分开的：`minHeight` 是渲染上的物理底线（再矮内容就画不下了），
    /// `minimumHeight` 是用户偏好。用户可以把下限抬高到 400，但压不到 100 ——
    /// 夹取时取两者**较大值**，因此「最小高度」只能往上收紧，不会把窗口压坏。
    public static func windowHeight(contentHeight: CGFloat,
                                    visibleScreenHeight: CGFloat,
                                    minimumHeight: CGFloat = PartitionMetrics.minHeight) -> CGFloat {
        let floorH = max(minHeight, minimumHeight)
        return min(max(headerHeight + contentHeight, floorH), max(floorH, visibleScreenHeight - 60))
    }
}

/// 对齐排版的坐标解算。
///
/// 拆出来的理由：这是项目的核心逻辑，且**历史上出过两次坐标类回归**
/// （排版基准不一致、程序性移动被拖动吸附改写），必须有可断言、可回归的纯函数。
/// 本类型不接触窗口、不读写配置 —— 输入「条目 + 尺寸 + 屏幕」，输出「坐标」。
public enum LayoutEngine {

    public struct Placement: Equatable {
        public let id: String
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double

        public init(id: String, x: Double, y: Double, width: Double, height: Double) {
            self.id = id
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    /// 分区底部保留的安全边距
    public static let bottomInset: Double = 40
    /// 折叠分区在纵向布局里的占位高度（= 标题栏）
    public static let collapsedHeight: Double = 44
    /// 高度未知时的兜底值
    public static let fallbackHeight: Double = 200
    /// 纵向布局的最小可用高度
    public static let minAvailHeight: Double = 200

    /// 单列宽度 = 该列**最宽**的分区；若最宽值非正（宽度缺失或被写成 0）则用默认宽兜底。
    ///
    /// ⚠️ **三端必须同此规则**。mac 原写法是 `max() ?? defaultWidth`（只在集合为空时兜底），
    /// 于是「分区宽度被写成 0」时 mac 得到 0、Windows / Electron 得到默认宽 —— 同一份配置
    /// 在两端会算出不同的列 X。真实窗口宽度不会是 0，属边角情况，但跨端必须收敛。
    private static func columnWidth<C: Collection>(
        _ ids: C, width: (String) -> Double, defaultWidth: Double
    ) -> Double where C.Element == String {
        let widest = ids.map(width).max() ?? 0
        return widest > 0 ? widest : defaultWidth
    }

    /// 横向网格 / 顶部横排：**行优先**分配。
    /// 同一排内所有分区的 Y 严格相同，排间以「该排最大有效高度」换行；
    /// 同一列内所有分区的 X 严格相同。
    public static func gridPlacements(
        ids: [String],
        effectiveHeight: (String) -> Double,
        width: (String) -> Double,
        height: (String) -> Double,
        screenWidth: Double,
        top: Double,
        maxColumns: Int,
        defaultWidth: Double
    ) -> [Placement] {
        guard !ids.isEmpty else { return [] }
        let margin = Double(Layout.margin)
        let gap = Double(Layout.gap)
        let availW = screenWidth - 2 * margin

        // 1. 实际能容纳的列数（逐步递减直到总宽放得下）
        var numCols = max(1, min(ids.count, max(1, maxColumns)))
        while numCols > 1 {
            var maxWidthPerCol = Array(repeating: 0.0, count: numCols)
            for (idx, id) in ids.enumerated() {
                let c = idx % numCols
                maxWidthPerCol[c] = max(maxWidthPerCol[c], width(id))
            }
            // ⚠️ 宽度非正的列用默认宽兜底 —— 与 Windows / Electron 的 `宽度 > 0 ? : 默认宽` 一致
            let totalW = maxWidthPerCol.reduce(0.0) { $0 + ($1 > 0 ? $1 : defaultWidth) }
                + Double(numCols - 1) * gap
            if totalW <= availW { break }
            numCols -= 1
        }

        // 2. 行优先切分
        var rows: [[String]] = []
        var currentRow: [String] = []
        for id in ids {
            currentRow.append(id)
            if currentRow.count == numCols {
                rows.append(currentRow)
                currentRow = []
            }
        }
        if !currentRow.isEmpty { rows.append(currentRow) }

        // 3. 列 X 坐标（取该列所有分区宽度的最大值，保证同列严格对齐）
        var colWidths = Array(repeating: defaultWidth, count: numCols)
        for c in 0 ..< numCols {
            let colItems = rows.compactMap { r in c < r.count ? r[c] : nil }
            colWidths[c] = columnWidth(colItems, width: width, defaultWidth: defaultWidth)
        }
        var colX = Array(repeating: margin, count: numCols)
        for c in 1 ..< numCols { colX[c] = colX[c - 1] + colWidths[c - 1] + gap }

        // 4. 逐排摆放
        var result: [Placement] = []
        var curY = top
        for rowItems in rows {
            let rowMaxH = rowItems.map { effectiveHeight($0) }.max() ?? fallbackHeight
            for (c, id) in rowItems.enumerated() {
                result.append(Placement(id: id, x: colX[c], y: curY, width: width(id), height: height(id)))
            }
            curY += rowMaxH + gap
        }
        return result
    }

    /// 列数策略 —— 三种「列式」对齐模式共用同一段排布，只在列数上分道扬镳。
    public enum ColumnCountMode {
        /// 尽量多列：列数取 `maxColumns` 与分区数的小者，再用可用宽度夹一次。
        /// 「顶部横向排序」用 —— 整体最紧凑、最矮。
        case atMost(Int)
        /// 最少列数：刚好做到「每一列高度都不超过可用高度」。
        /// 「左侧 / 右侧对齐」用 —— 列更少、每列更长，是几条纵向长列。
        case minimumFeasible
    }

    /// 列高的**方向** —— 只在 DP 内部做**并列取舍**（极差并列时沿哪个方向摆更好看）。
    ///
    /// ⚠️ 它**不参与「哪一侧最高」的判定**：那件事由「各列按列高降序摆开」
    /// （`columnPlacements` 的 `sortColumnsByHeight`）**恒等保证**，
    /// 「顶部横向排序」的方向只决定整块贴左还是贴右（`fromRight`）。
    /// 历史教训：曾让方向参与分组（两方向各解一次 DP），结果两个方向不再是镜像 ——
    /// 见 `sortColumnsByHeight` 的注释。
    ///
    /// ⚠️⚠️ **`left` / `right` 必须都用 `.nonIncreasing`，绝不能给 `right` 传 `.nonDecreasing`。**
    /// 直觉上「right 的列高自左向右是递增的，似乎该用 `.nonDecreasing`」—— 但这是错的：
    /// `left` 与 `right` 拿到的是**同一条序列**（见 AppDelegate 的读序），`order` 一旦不同，
    /// 同一个 DP 在「极差并列」时就会替两边挑出**不同的分组**，镜像当场失效。
    /// 也就是说：**「right 看起来是递增」是镜像的果，不是该传的方向**。
    public enum ColumnHeightOrder {
        /// 自左向右**非递增**：左侧最高，向右依次递减或相等。对应「从左到右」。
        case nonIncreasing
        /// 自左向右**非递减**：右侧最高，向左依次递减或相等。对应「从右到左」。
        case nonDecreasing

        /// 从「上一列高度」到「本列高度」这一步的**违例量**（逆着方向的那一段）。
        /// 相邻两列相等时恒为 0 —— 「递减**或相等**」里的「相等」是允许的。
        func violation(from prev: Double, to cur: Double) -> Double {
            switch self {
            case .nonIncreasing: return max(0, cur - prev)
            case .nonDecreasing: return max(0, prev - cur)
            }
        }
    }

    /// 各列高度 = 列内条目高度之和 + 组内间隔（`(条数 − 1) × gap`）。
    public static func columnHeights(
        ranges: [Range<Int>], heights: [Double], gap: Double
    ) -> [Double] {
        ranges.map { r in
            r.reduce(0.0) { $0 + heights[$1] } + Double(max(0, r.count - 1)) * gap
        }
    }

    /// 列式排布（`left` / `right` / `top` 共用）。
    ///
    /// ⚠️ `left` / `right` 必须按**列优先读序**传入 `ids`（先一列自上而下、再下一列），
    /// 而且两者必须拿到**同一条序列** —— 这是「互为镜像」的前提：
    /// 分组只取决于序列；序列相同 ⇒ 分组相同 ⇒ `fromRight` 的结果就是 `false` 的
    /// **严格几何镜像**（列宽不相等时也成立，因为列坐标本身就是镜像算出来的）。
    ///
    /// 分组用**保序连续分组 DP**，目标键固定为「极差 → 方向违例 → 平方和」。
    ///
    /// ⚠️ **方向（`ColumnHeightOrder`）绝不在这里参与分组**：读序由「当前布局贴哪一边」
    /// 推出、而 `fromRight` 同时决定「第一组放哪边」，一旦方向也参与分组，
    /// 两个方向就不再互为镜像、来回切还会互相污染。
    ///
    /// - Parameters:
    ///   - fromRight: true 时整块贴右边，且**第一组放在最右**。
    ///   - columns: 列数策略。
    ///     `.minimumFeasible` = 每列都不超过可用高度的**最少**列数；
    ///     `.atMost(n)` = 尽量取 n 列，**但若 n 列在高度上装不下会向上加列**（详见分支内注释），
    ///     再按实际分组结果逐级验证宽度往下减 —— 两种模式都**不会让列高超出屏幕**。
    ///   - sortColumnsByHeight: 「顶部横向排序」传 true —— 见下方注释。
    public static func columnPlacements(
        ids: [String],
        effectiveHeight: (String) -> Double,
        width: (String) -> Double,
        height: (String) -> Double,
        screenWidth: Double,
        screenHeight: Double,
        top: Double,
        defaultWidth: Double,
        fromRight: Bool,
        columns: ColumnCountMode,
        sortColumnsByHeight: Bool = false
    ) -> [Placement] {
        guard !ids.isEmpty else { return [] }
        let margin = Double(Layout.margin)
        let gap = Double(Layout.gap)
        let heights = ids.map { effectiveHeight($0) }
        let availH = max(minAvailHeight, screenHeight - top - bottomInset)

        // 1. 定列数，并按该列数做一次保序均衡分组
        var ranges: [Range<Int>] = [0 ..< ids.count]
        switch columns {
        case .atMost(let limit):
            // ⚠️ 「尽量多列」与「每列不超出屏幕」可能冲突，而两者的对策方向**相反**：
            // 列越多每列越矮 —— 所以**高度超了要加列，宽度超了才减列**。
            // 于是先把目标列数用「高度可行所需的最少列数」顶上去，再按宽度逐级往下减，
            // 但**不减到该下界以下**（否则刚才压下去的高度又会冒出来）。
            let target = max(1, min(ids.count, max(1, limit)))
            let minCols = minimumFeasibleColumnCount(
                heights: heights, gap: gap, maxGroupHeight: availH)
            var numCols = min(ids.count, max(target, minCols))
            let availW = screenWidth - 2 * margin
            while true {
                let candidate = balancedColumnRanges(
                    heights: heights, columns: numCols, gap: gap, maxGroupHeight: availH)
                // ⚠️ 必须用**实际分组结果**逐级验证总宽：均衡分组打乱了「哪些分区同列」，
                // `idx % numCols` 那类估算不再成立。
                let totalW = candidate.reduce(0.0) {
                    $0 + columnWidth($1.map { ids[$0] }, width: width, defaultWidth: defaultWidth) + gap
                }
                ranges = candidate
                if totalW - gap <= availW || numCols <= minCols { break }
                numCols -= 1
            }
        case .minimumFeasible:
            // 「左侧 / 右侧纵向对齐」= **逐列填满**：先把最靠边的那一列自上而下塞满，
            // 塞不下才往内开新列。方向由 `placeColumns` 的 `fromRight` 决定 ⇒ 两向严格镜像。
            //
            // ⚠️ 这里刻意**不用** `balancedColumnRanges`：那套保序 DP 的目标是
            // 「各列尽量等高」，为了压极差会把本该留在第一列的分区挪到后面去 ——
            // 真实配置实测（3 个分区 428 / 316 / 314，可用高 1060）：
            // 第一列本可装 2 个（428+16+316 = 760），但均衡分组为了把极差从 446 压到 218，
            // 把第一列拆得只剩 1 个 ⇒ 用户看到「没有优先填充完最左侧的列」。
            //
            // ⚠️ 「填满优先」与「等高优先」不可兼得：代价是最后一列可能明显偏短。
            // 2026-09-30 用户明确选择前者（此前 09-28 曾反向选择过后者，见测试里的历史注释）。
            ranges = greedyFillColumnRanges(
                heights: heights, gap: gap, maxGroupHeight: availH)
        }

        // 1.5 「顶部横向排序」：把各列**按列高降序**摆开
        //
        // 这是让「左侧最高，向右依次递减或相等」**恒成立**的唯一办法：
        // 保序分组得到的列高沿读序并不单调 —— 真实配置实测（7 分区 / 5 列）
        // 各列是 316 / 316 / 480 / 428 / 610，第 3、4 列是**上凸**的（480 排在 428 左边）。
        // 按高矮排开后就是严格阶梯 610 / 480 / 428 / 316 / 316。
        //
        // ⚠️ 为什么不能靠「让方向参与分组」来代替：试过 —— 两方向各解一次 DP，
        // 结果两个方向**不再互为镜像**（同一批分区被切成了不同的两组），
        // 而镜像正是用户明确要求保住的（见 README「镜像与单侧最高」）。
        //
        // ⚠️⚠️ 打开后**列序不再等于读序**，因此调用方**必须**传入与布局无关的稳定序列
        // （`top` 传配置顺序）。否则「排完 → 按贴边读回 → 再分组」读到的已经是另一条序列，
        // 分组随之漂移，连点会越排越歪 —— 实测（7 分区 / 3 列）会一路漂成
        // 1054/646/482 → 978/776/428 → 1220/482/480 …
        if sortColumnsByHeight {
            let groupH = columnHeights(ranges: ranges, heights: heights, gap: gap)
            ranges = ranges.enumerated()
                .sorted { a, b in
                    // 并列时保持原读序 —— 保证结果稳定（不依赖排序算法是否稳定）
                    groupH[a.offset] != groupH[b.offset]
                        ? groupH[a.offset] > groupH[b.offset]
                        : a.offset < b.offset
                }
                .map(\.element)
        }

        // 2. 落位
        return placeColumns(
            ranges: ranges, ids: ids, effectiveHeight: effectiveHeight,
            width: width, height: height, fromRight: fromRight,
            screenWidth: screenWidth, top: top, defaultWidth: defaultWidth)
    }

    /// 给定**分组**与**落位方向**，算出每个分区的坐标（列 X + 列内自上而下的 Y）。
    ///
    /// 「同一套分组 + 只把 `fromRight` 取反」得到的必然是**严格几何镜像**：
    /// 列坐标本身就是镜像算出来的（`colX[0]` 贴另一侧的 margin，随后逐列反向累加），
    /// 列宽也只取决于分组，与方向无关。
    private static func placeColumns(
        ranges: [Range<Int>],
        ids: [String],
        effectiveHeight: (String) -> Double,
        width: (String) -> Double,
        height: (String) -> Double,
        fromRight: Bool,
        screenWidth: Double,
        top: Double,
        defaultWidth: Double
    ) -> [Placement] {
        let margin = Double(Layout.margin)
        let gap = Double(Layout.gap)
        guard !ranges.isEmpty else { return [] }

        // 列 X：取该列最宽的分区，保证同列边缘严格对齐
        let colWidths = ranges.map {
            columnWidth($0.map { ids[$0] }, width: width, defaultWidth: defaultWidth)
        }
        var colX = [Double](repeating: margin, count: ranges.count)
        if fromRight {
            colX[0] = (screenWidth - margin) - colWidths[0]
            for c in 1 ..< ranges.count { colX[c] = colX[c - 1] - gap - colWidths[c] }
        } else {
            for c in 1 ..< ranges.count { colX[c] = colX[c - 1] + colWidths[c - 1] + gap }
        }

        // 逐列自上而下摆放，每列都从 top 起（顶部对齐）
        var result: [Placement] = []
        for (c, r) in ranges.enumerated() {
            var curY = top
            for i in r {
                let id = ids[i]
                let w = width(id)
                let x = fromRight ? colX[c] + (colWidths[c] - w) : colX[c]
                result.append(Placement(id: id, x: x, y: curY, width: w, height: height(id)))
                curY += effectiveHeight(id) + gap
            }
        }
        return result
    }

    /// 把 `heights` 切成 `columns` 个**连续**分组（保序）。目标按字典序，三键固定为：
    /// ①「最高列 − 最矮列」最小 → ② 方向违例最小 → ③ 平方和最小。
    /// 即「各列尽量等高」第一位，方向只在**极差并列时**取舍。
    ///
    /// 「违例」= 相邻两列中**逆着方向**的那一段高度差之和（见 `ColumnHeightOrder.violation`）。
    /// 它与极差同量纲（都是点），所以「违例」作第二键不会失真。
    ///
    /// ⚠️ **没有「违例优先」这一档，是有意为之**：曾有一档把违例提到第一键，
    /// 但它需要**两个方向各解一次 DP**，于是同一批分区被切成两套不同的
    /// 分组 —— 两个方向**不再互为镜像**，而镜像正是用户明确要求保住的。
    /// 「左侧最高、向右递减或相等」现在由**落位时按列高降序摆开**恒等保证
    /// （见 `columnPlacements` 的 `sortColumnsByHeight`），不需要方向参与分组。
    ///
    /// **为什么用 DP 而不是贪心**：贪心（「累计超过可用高度就换列」）在单条高度
    /// 远大于均值时会**过早换列**，把余量丢给后面的列。实测 10 条等高短分区、
    /// 可用高 1060：贪心给出 912 / 216（极差 696），DP 给出 564 / 564（极差 0）。
    ///
    /// **状态为什么带上「本组起点」**：违例与极差都要知道**上一列**的高度，
    /// 而上一列的高度由它的起止下标决定，塞不进 `(列数, 已用条数)` 这个二元状态。
    /// 于是状态取 `(列数, 本组起点, 本组终点)`，代价 O(k·n³) ——
    /// 分区数是几十的量级、只在点击对齐时跑一次，可忽略。
    ///
    /// - Parameters:
    ///   - maxGroupHeight: 单列高度上限（`.infinity` = 不限）。单条本身就超高时放行，
    ///     否则会有分区永远排不进去。
    ///   - order: 列高沿读序应当满足的单调方向 —— 只在极差并列时取舍。
    public static func balancedColumnRanges(
        heights: [Double],
        columns: Int,
        gap: Double,
        maxGroupHeight: Double = .infinity,
        order: ColumnHeightOrder = .nonIncreasing
    ) -> [Range<Int>] {
        let n = heights.count
        guard n > 0 else { return [] }
        let k = max(1, min(columns, n))
        if k == 1 { return [0 ..< n] }
        if k == n { return (0 ..< n).map { $0 ..< ($0 + 1) } }

        // 前缀和：分组 [i, j) 的高度 = Σh + (条数 − 1) × gap
        var prefix = [Double](repeating: 0, count: n + 1)
        for i in 0 ..< n { prefix[i + 1] = prefix[i] + heights[i] }
        func groupHeight(_ i: Int, _ j: Int) -> Double {
            prefix[j] - prefix[i] + Double(j - i - 1) * gap
        }
        func feasible(_ i: Int, _ j: Int) -> Bool {
            j - i == 1 || groupHeight(i, j) <= maxGroupHeight + 1e-9
        }

        let inf = Double.infinity
        let side = n + 2
        func slot(_ c: Int, _ s: Int, _ e: Int) -> Int { (c * side + s) * side + e }
        let slots = (k + 2) * side * side

        /// 三键固定为（极差, 方向违例, 平方和），比较一律走元组的字典序。
        func key(maxH: Double, minH: Double, viol: Double, sq: Double) -> (Double, Double, Double) {
            (maxH - minH, viol, sq)
        }
        var bestMax = [Double](repeating: inf, count: slots)
        var bestMin = [Double](repeating: inf, count: slots)
        var bestViol = [Double](repeating: inf, count: slots)
        var bestSq = [Double](repeating: inf, count: slots)
        var prevStart = [Int](repeating: -1, count: slots)

        // 1 组：整段 [0, e)
        for e in 1 ... n where feasible(0, e) {
            let g = groupHeight(0, e)
            let sl = slot(1, 0, e)
            bestMax[sl] = g; bestMin[sl] = g
            bestViol[sl] = 0; bestSq[sl] = g * g; prevStart[sl] = -1
        }

        if k > 1 {
            for c in 2 ... k {
                for s in (c - 1) ..< n {
                    // 后面还要放 k − c 组，本组终点有上限
                    let lastEnd = n - (k - c)
                    guard s + 1 <= lastEnd else { continue }
                    for e in (s + 1) ... lastEnd where feasible(s, e) {
                        let g = groupHeight(s, e)
                        var chosen = -1
                        var best: (Double, Double, Double) = (inf, inf, inf)
                        for ps in (c - 2) ..< s {
                            let prev = slot(c - 1, ps, s)
                            guard bestMax[prev] < inf else { continue }
                            let viol = bestViol[prev]
                                + order.violation(from: groupHeight(ps, s), to: g)
                            let cand = key(maxH: max(bestMax[prev], g),
                                           minH: min(bestMin[prev], g),
                                           viol: viol,
                                           sq: bestSq[prev] + g * g)
                            if cand < best { best = cand; chosen = ps }
                        }
                        guard chosen >= 0 else { continue }
                        let prev = slot(c - 1, chosen, s)
                        let sl = slot(c, s, e)
                        bestMax[sl] = max(bestMax[prev], g)
                        bestMin[sl] = min(bestMin[prev], g)
                        bestViol[sl] = bestViol[prev]
                            + order.violation(from: groupHeight(chosen, s), to: g)
                        bestSq[sl] = bestSq[prev] + g * g
                        prevStart[sl] = chosen
                    }
                }
            }
        }

        // 收尾：最后一组覆盖 [s, n)
        var bestStart = -1
        var bestKey: (Double, Double, Double) = (inf, inf, inf)
        for s in (k - 1) ..< n {
            let sl = slot(k, s, n)
            guard bestMax[sl] < inf else { continue }
            let cand = key(maxH: bestMax[sl], minH: bestMin[sl],
                           viol: bestViol[sl], sq: bestSq[sl])
            if cand < bestKey { bestKey = cand; bestStart = s }
        }
        guard bestStart >= 0 else { return [0 ..< n] }

        // 回溯出各分组的下标区间
        var ranges: [Range<Int>] = []
        var end = n
        var start = bestStart
        var c = k
        while c >= 1 {
            ranges.append(start ..< end)
            let ps = prevStart[slot(c, start, end)]
            end = start
            start = ps >= 0 ? ps : 0
            c -= 1
        }
        return ranges.reversed()
    }

    /// 「每一列高度都不超过 `maxGroupHeight`」所需的最少列数。
    ///
    /// 贪心即最优：尽量往当前列塞，塞不下才换列，得到的列数一定最少
    /// （往前面的列多塞只可能减少后续列数）。单条本身超高时它自己独占一列。
    public static func minimumFeasibleColumnCount(
        heights: [Double], gap: Double, maxGroupHeight: Double
    ) -> Int {
        guard !heights.isEmpty else { return 0 }
        var cols = 1
        var cur: Double = 0
        for h in heights {
            let add = cur == 0 ? h : h + gap
            if cur > 0 && cur + add > maxGroupHeight + 1e-9 {
                cols += 1
                cur = h
            } else {
                cur += add
            }
        }
        return cols
    }

    /// 「逐列填满」的保序分组：与 `minimumFeasibleColumnCount` 同源同口径，但返回**每列的范围**。
    ///
    /// 贪心即最优：尽量往当前列塞，塞不下才换列，所以**除最后一列外，每一列都是
    /// 「再塞一条就会超出 `maxGroupHeight`」的状态** —— 这正是「左侧优先填满」的形式化含义。
    /// 单条本身就超高时它自己独占一列（新一轮的第一条无条件加入，不会被判成超界）。
    ///
    /// ⚠️ 判断「当前列是否为空」用 `i == start` 而不是 `cur == 0`：
    /// 高度为 0 的分区会让 `cur` 停在 0，后者会把后续多条误判成「仍在第一列」而漏加 gap。
    public static func greedyFillColumnRanges(
        heights: [Double], gap: Double, maxGroupHeight: Double
    ) -> [Range<Int>] {
        guard !heights.isEmpty else { return [] }
        var ranges: [Range<Int>] = []
        var start = 0
        var cur: Double = 0
        for (i, h) in heights.enumerated() {
            let add = i == start ? h : h + gap
            if i > start && cur + add > maxGroupHeight + 1e-9 {
                ranges.append(start ..< i)
                start = i
                cur = h
            } else {
                cur += add
            }
        }
        ranges.append(start ..< heights.count)
        return ranges
    }

// MARK: - 拖动吸附

    /// 吸附阈值（点）：距目标边缘 16pt 以内即贴合
    public static let snapThreshold: Double = 16

    /// 拖动吸附的坐标解算。
    /// - 先贴身屏幕四边的 margin；
    /// - 再对其他分区的四条边做对齐（含 gap 间隔吸附）。
    /// - **所有入参必须是同一个坐标系**（屏幕相对、左上原点）。
    ///   历史上此处自身用屏幕相对坐标、相邻分区用 AppKit 全局坐标，
    ///   在非原点屏（如外接屏 origin = (1680, -30)）上相差一个屏幕原点偏移，
    ///   导致外接屏上的分区吸附不到相邻分区。
    /// 返回吸附后的左上原点坐标。
    public static func snappedPosition(
        x: Double, y: Double, w: Double, h: Double,
        screenWidth: Double, screenHeight: Double,
        others: [(x: Double, y: Double, w: Double, h: Double)],
        topMargin: Double? = nil
    ) -> (x: Double, y: Double) {
        let margin = Double(Layout.margin)
        let gap = Double(Layout.gap)
        let t = snapThreshold
        var nx = x, ny = y

        let effectiveTop = topMargin ?? margin

        // 屏幕边缘
        if abs(x - margin) <= t { nx = margin }
        else if abs(x + w - (screenWidth - margin)) <= t { nx = screenWidth - margin - w }
        if abs(y - effectiveTop) <= t { ny = effectiveTop }
        else if abs(y + h - (screenHeight - margin)) <= t { ny = screenHeight - margin - h }

        // 相邻分区（左右相邻、上下堆叠、边缘对齐与无缝贴靠）
        for o in others {
            // 水平吸附
            if abs(x - o.x) <= t { nx = o.x }                                    // 左对齐
            else if abs(x + w - (o.x - gap)) <= t { nx = o.x - w - gap }         // 置于其左（标准间距）
            else if abs(x + w - o.x) <= t { nx = o.x - w }                       // 置于其左（无缝贴合）
            else if abs(x - (o.x + o.w + gap)) <= t { nx = o.x + o.w + gap }     // 置于其右（标准间距）
            else if abs(x - (o.x + o.w)) <= t { nx = o.x + o.w }                 // 置于其右（无缝贴合）
            else if abs(x + w - (o.x + o.w)) <= t { nx = o.x + o.w - w }         // 右对齐

            // 垂直吸附
            if abs(y - o.y) <= t { ny = o.y }                                    // 顶对齐
            else if abs(y + h - (o.y - gap)) <= t { ny = o.y - h - gap }         // 置于其上（标准间距）
            else if abs(y + h - o.y) <= t { ny = o.y - h }                       // 置于其上（无缝贴合）
            else if abs(y - (o.y + o.h + gap)) <= t { ny = o.y + o.h + gap }     // 置于其下（标准间距）
            else if abs(y - (o.y + o.h)) <= t { ny = o.y + o.h }                 // 置于其下（无缝贴合）
            else if abs(y + h - (o.y + o.h)) <= t { ny = o.y + o.h - h }         // 底对齐
        }

        return (nx, ny)
    }

    // MARK: - 对齐编排（读序 → 分派）

    /// 一次对齐的输入项 —— 由调用方（`AppDelegate` / 跨端对拍工具）从配置或窗口状态读出。
    ///
    /// 本层**刻意不碰 AppKit 与 Config**：把这段抽出来的唯一目的，是让「读序 → 分派」
    /// 也能被单测与跨端对拍覆盖。它原先写在 `AppDelegate` 里，而 executable target
    /// **无法**被 testTarget 导入 —— 等于这段逻辑永远测不到，只能靠肉眼看窗口。
    public struct AlignItem {
        public let id: String
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double
        public let isCollapsed: Bool
        /// 配置顺序 —— `top` 的固定读序来源（稳定、与当前布局无关）
        public let index: Int

        public init(id: String, x: Double, y: Double, width: Double, height: Double,
                    isCollapsed: Bool, index: Int) {
            self.id = id
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.isCollapsed = isCollapsed
            self.index = index
        }
    }

    /// 对齐编排：`top` / `left` / `right` / `grid` 的**读序判定 + 排布分派**。
    ///
    /// 只算位置（x / y），不改宽高。与 `columnPlacements` / `gridPlacements` 的分工是：
    /// 这里决定「按什么顺序读、交给哪个排布器」，那边负责「给定序列怎么落位」。
    ///
    /// - Parameters:
    ///   - topHeightOrder: `"leftToRight"` = 整块贴左，`"rightToLeft"` = 整块贴右。
    ///
    /// - 保持稳定的空间阅读顺序：
    ///   · left / right：**列优先读序**（先一列自上而下、再下一列），**从当前布局贴的那一侧读起**；
    ///   · top：**固定读配置顺序**（与当前布局无关）—— 理由见下；
    ///   · grid：**行优先读序**（上排优先、同排左侧优先）。
    ///
    /// ⚠️ 读序必须与排布方式匹配，否则重排后取回的序列已经与列交错 → 再点一次就窜位。
    ///
    /// ⚠️⚠️ left / right 的「从哪一边读」由**当前布局贴哪一边**决定，**与接下来点哪个模式无关**：
    /// 贴左就从最左列读起，贴右就从最右列读起。
    /// 这是「左对齐与右对齐互为镜像」的前提 —— 两个模式必须拿到**同一条序列**，
    /// 分组才会一致，结果才是彼此的镜像；否则右对齐会按相反的顺序重新分组，
    /// 切出来的列根本不是同一组（实测 7 个分区：左对齐 814/758/610，
    /// 右对齐却成了 316/926/940）。
    /// 同时这也保证幂等：从「贴边的那一侧」读回的序列，正是上一次排布用过的序列。
    ///
    /// ⚠️️⚠️ `top` 为什么反过来要**脱离几何**：它的列是**按列高降序摆开**的
    /// （`columnPlacements(sortColumnsByHeight: true)`），列的左右顺序**不再承载读序信息**。
    /// 若还从布局几何推读序，读回来的就是「按列高排过序」的另一条序列，再分组必然切出不同的列 ——
    /// 实测（7 分区 / 3 列）会一路漂成 1054/646/482 → 978/776/428 → 1220/482/480 …
    /// 所以 `top` 的序列固定取**配置顺序**（与布局无关的稳定来源）⇒ 输入恒定 ⇒ 结果恒定。
    public static func alignPlacements(
        items: [AlignItem],
        mode: String,
        screenWidth: Double,
        screenHeight: Double,
        top: Double,
        maxColumns: Int,
        defaultWidth: Double,
        topHeightOrder: String
    ) -> [Placement] {
        var sorted = items
        if mode == "top" {
            sorted.sort { $0.index < $1.index }
        } else if mode == "left" || mode == "right" {
            var minX = Double.infinity
            var maxRight = -Double.infinity
            for p in sorted {
                minX = min(minX, p.x)
                maxRight = max(maxRight, p.x + p.width)
            }
            let margin = Double(Layout.margin)
            let fromRight: Bool
            if sorted.isEmpty {
                fromRight = false
            } else {
                let leftGap = minX - margin
                let rightGap = screenWidth - margin - maxRight
                fromRight = rightGap < leftGap
            }
            sorted.sort { p1, p2 in
                if abs(p1.x - p2.x) > 60 { return fromRight ? p1.x > p2.x : p1.x < p2.x }
                if abs(p1.y - p2.y) > 1 { return p1.y < p2.y }
                return p1.index < p2.index
            }
        } else {
            // grid：行优先读序（上排优先，同排左侧优先）
            sorted.sort { p1, p2 in
                if abs(p1.y - p2.y) > 60 { return p1.y < p2.y }
                if abs(p1.x - p2.x) > 1 { return p1.x < p2.x }
                return p1.index < p2.index
            }
        }

        let ids = sorted.map { $0.id }
        guard !ids.isEmpty else { return [] }

        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let getEffH: (String) -> Double = { id in
            guard let it = byID[id] else { return fallbackHeight }
            if it.isCollapsed { return collapsedHeight }
            return it.height > 0 ? it.height : fallbackHeight
        }
        let getW: (String) -> Double = { id in
            guard let it = byID[id] else { return defaultWidth }
            return it.width > 0 ? it.width : defaultWidth
        }
        // ⚠️ 这是**原始**高度（可能为 0），不是 getEffH —— 排布器只在 Placement.height 里回传它，
        // 分组与换行一律用 getEffH。与 AppDelegate 原写法逐字一致，别改成 fallbackHeight。
        let heightProvider: (String) -> Double = { byID[$0]?.height ?? fallbackHeight }

        switch mode {
        case "left":
            // 列数取「每列都不超过可用高度」的最少值，再由保序 DP 把各列高度调匀。
            return columnPlacements(
                ids: ids, effectiveHeight: getEffH, width: getW, height: heightProvider,
                screenWidth: screenWidth, screenHeight: screenHeight,
                top: top, defaultWidth: defaultWidth,
                fromRight: false, columns: .minimumFeasible)
        case "right":
            // ⚠️ 必须与 left 用**同一段**算法、只把 fromRight 打开 ——
            // 这样两者得到的分组完全一致，结果是彼此的**严格几何镜像**。
            return columnPlacements(
                ids: ids, effectiveHeight: getEffH, width: getW, height: heightProvider,
                screenWidth: screenWidth, screenHeight: screenHeight,
                top: top, defaultWidth: defaultWidth,
                fromRight: true, columns: .minimumFeasible)
        case "top":
            // 尽量多列（maxColumns）→ 各列尽量等高（保序 DP）→ **各列按列高降序摆开**。
            //
            // 「横排列高方向」只决定**整块贴哪一侧**：
            //   从左到右 = 贴左（最高的列在最左，向右依次递减或相等）
            //   从右到左 = 贴右（最高的列在最右，向左依次递减或相等）
            //
            // ⚠️ 这样「某侧最高」是**恒等成立**的，不再有「无解」：
            // 列本身已按高矮排好，方向只负责挑哪一侧是「高」的那一侧。
            // 单位是「同一套分组 + 只翻 fromRight」⇒ 两个方向**严格互为几何镜像**。
            // 方向**不参与分组**，否则两向会切出不同的列（见上方读序注释）。
            //
            // ⚠️ 代价：**列的左右顺序不再等于配置顺序**（分组照旧保序，但列按高矮摆放）——
            // 这正是「做到严格阶梯」必须付的代价：真实配置 5 列下
            // 分组列高为 316/316/480/428/610，其中 480 那一组（含序次靠后的两个分区）
            // 必须摆到 428 左边，才能消除上凸。
            return columnPlacements(
                ids: ids, effectiveHeight: getEffH, width: getW, height: heightProvider,
                screenWidth: screenWidth, screenHeight: screenHeight,
                top: top, defaultWidth: defaultWidth,
                fromRight: topHeightOrder == "rightToLeft",
                columns: .atMost(maxColumns),
                sortColumnsByHeight: true)
        default:   // "grid"：行优先网格（同排 Y 相同，排间按该排最高分区换行）
            return gridPlacements(
                ids: ids, effectiveHeight: getEffH, width: getW, height: heightProvider,
                screenWidth: screenWidth, top: top,
                maxColumns: maxColumns, defaultWidth: defaultWidth)
        }
    }
}
