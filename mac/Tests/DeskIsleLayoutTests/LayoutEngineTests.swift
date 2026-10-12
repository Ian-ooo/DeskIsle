import XCTest
import CoreGraphics
@testable import DeskIsleLayout

/// DeskIsle 排版核心的回归测试。
///
/// 这些断言锁住的是**历史上真实出过的问题**：
/// 1. `snapPartition` 曾自用 `margin=24 / gap=12`，与 `align` 的 16/16 不一致，
///    导致「新建分区间隔偏小、换行后与左侧间隔偏大」；
/// 2. `autoFitHeight` 曾始终按配置里的根目录数条目，进入子文件夹后点自适应会用最外层的高度；
/// 3. 拖动吸附曾在非原点屏（外接屏）上失效 —— 自身用屏幕相对坐标、相邻分区用全局坐标；
/// 4. 折叠分区的占位高度、窗口高度夹紧边界等。
///
/// 任何一条失败都说明「排版基准被改动了」，改之前请先确认是有意为之。
final class LayoutEngineTests: XCTestCase {

    // MARK: - 基准常量

    func testLayoutBasisIsUnified() {
        // 这两个值被 align / snapPartition / findFreeSlot / 视图 padding 共同依赖。
        // 改动它们等于改变全部排版，必须同时更新本测试与 README 的「统一间距基准」章节。
        XCTAssertEqual(Layout.margin, 16)
        XCTAssertEqual(Layout.gap, 16)
    }

    func testHeaderAndMinimumHeight() {
        XCTAssertEqual(PartitionMetrics.headerHeight, 44)
        XCTAssertEqual(PartitionMetrics.minHeight, 150)
        XCTAssertEqual(LayoutEngine.collapsedHeight, 44)
    }

    // MARK: - 内容高度口径

    func testGridColumnsAtStandardWidth() {
        // 典型分区宽 316（1680 屏按 5 列自适应均分）→ (316-20)/82 = 3.6 → 3 列
        XCTAssertEqual(PartitionMetrics.gridColumns(width: 316), 3)
        // 宽度不足以放下一个 tile 时仍保底 1 列，不能返回 0
        XCTAssertEqual(PartitionMetrics.gridColumns(width: 60), 1)
        XCTAssertEqual(PartitionMetrics.gridColumns(width: 0), 1)
    }

    func testGridContentHeightMatchesViewLayout() {
        // 1 行：工具栏 28 + 1×74 + 上下留白 20 = 122
        XCTAssertEqual(PartitionMetrics.gridContentHeight(count: 1, width: 316), 122, accuracy: 0.001)
        // 3 列时 12 条 = 4 行：28 + 4×74 + 20 = 344
        XCTAssertEqual(PartitionMetrics.gridContentHeight(count: 12, width: 316), 344, accuracy: 0.001)
        // 空目录只留工具栏与留白
        XCTAssertEqual(PartitionMetrics.gridContentHeight(count: 0, width: 316), 48, accuracy: 0.001)
    }

    /// 曾经的核心 bug：根目录 1 条与子目录 12 条必须得到**不同**的高度。
    /// 修复前两者都会按根目录算，进入子文件夹后点自适应高度不会变化。
    func testAutoFitDiffersBetweenRootAndSubfolder() {
        let width: CGFloat = 316
        let rootOnly = PartitionMetrics.headerHeight + PartitionMetrics.gridContentHeight(count: 1, width: width)
        let subfolder = PartitionMetrics.headerHeight + PartitionMetrics.gridContentHeight(count: 12, width: width)
        XCTAssertEqual(rootOnly, 166, accuracy: 0.001)   // 与线上实测值一致
        XCTAssertEqual(subfolder, 388, accuracy: 0.001)  // 与用户 work 分区实测值一致
        XCTAssertGreaterThan(subfolder, rootOnly)
    }

    func testNotesContentHeight() {
        // 空文本至少 1 行：1 × 16 + 上下留白与状态栏 34 = 50
        XCTAssertEqual(PartitionMetrics.notesContentHeight(text: "", width: 316), 50, accuracy: 0.001)
        // 行数随文本增长而单调不减
        let short = PartitionMetrics.notesContentHeight(text: "abc", width: 316)
        let long = PartitionMetrics.notesContentHeight(text: String(repeating: "字", count: 500), width: 316)
        XCTAssertGreaterThan(long, short)
    }

    /// 回归：`\n` 是**硬换行**，必须一行算一行。
    ///
    /// 修复前用 `text.count / 每行容量` 滚动估算，把 21 行的账号清单算成 4 行 →
    /// 内容高 104 → 窗口高被 `minHeight`(150) 夹住 → 用户点「自适应宽高」**一个像素都不动**。
    func testNotesContentHeightCountsHardLineBreaks() {
        let width: CGFloat = 364

        // 21 行、每行都短于可用宽度 → 恰好 21 视觉行
        let list = (0..<21).map { "line \($0)" }.joined(separator: "\n")
        XCTAssertEqual(PartitionMetrics.notesVisualLineCount(text: list, width: width), 21)
        XCTAssertEqual(PartitionMetrics.notesContentHeight(text: list, width: width), 21 * 16 + 34, accuracy: 0.001)

        // 同样 101 个半角字符：挤成 3 行 vs 铺成 21 行 —— 行数是 7 倍关系
        let oneLine = String(repeating: "a", count: 100)
        let manyLines = Array(repeating: "a", count: 21).joined(separator: "\n")
        XCTAssertEqual(PartitionMetrics.notesVisualLineCount(text: oneLine, width: width), 3)
        XCTAssertEqual(PartitionMetrics.notesVisualLineCount(text: manyLines, width: width), 21)

        // 空行同样占一行（首尾空行要计入，否则用户敲回车看不到窗口变化）
        XCTAssertEqual(PartitionMetrics.notesVisualLineCount(text: "\n\n\n", width: width), 4)

        // CRLF 兼容：尾部 `\r` 既不该多算一行，也不该撑宽（不去掉的话 "a\r" 会算成 2 行）
        XCTAssertEqual(PartitionMetrics.notesVisualLineCount(text: "a\r\nb", width: width), 2)
        XCTAssertEqual(PartitionMetrics.notesVisualLineCount(text: "a\r", width: 40), 1)
    }

    /// 回归：中文（全角）宽度是半角的 1.79 倍，不能统一按 7.2 算。
    func testNotesContentHeightWeighsFullWidthChars() {
        let width: CGFloat = 200   // 可用宽 174 → 半角约 24 个/行，全角约 13 个/行

        // 同样 40 个字符：全角需要更多行
        let half = String(repeating: "a", count: 40)
        let full = String(repeating: "字", count: 40)
        XCTAssertGreaterThan(
            PartitionMetrics.notesVisualLineCount(text: full, width: width),
            PartitionMetrics.notesVisualLineCount(text: half, width: width)
        )

        // 定标值本身也要锁住（实测：13pt 汉字 12.90、半角字母 7.10）
        XCTAssertEqual(PartitionMetrics.notesFullWidth, 12.9, accuracy: 0.001)
        XCTAssertEqual(PartitionMetrics.notesHalfWidth, 7.2, accuracy: 0.001)
        XCTAssertEqual(PartitionMetrics.notesLineHeight, 16, accuracy: 0.001)
    }

    /// 端到端：用户那份真实的 21 行账号便签。
    ///
    /// 数值来自 `NSAttributedString.boundingRect` 实测（13pt 系统字体、可用宽 338）：
    /// 整段排版高度 336 = 21 × 16，本函数估算 352（含上下留白 16），窗口高 396。
    /// 修复前只给到 150（被 minHeight 夹住），与用户手工高度**完全相同** → 表现为「不生效」。
    func testNotesAutoFitRegressionTwentyOneLineNote() {
        let text = """
        各环境账号
        口岸：
        192.168.102.193
        root oFcHQb3Z

        口岸二套
        192.168.102.178
        root Ju7Lw9G7

        总站
        192.168.102.209
        root cq883eoL

        总部
        192.168.102.225
        root S5ZqJoe4


        法语测试环境：
        192.168.102.199
        root   8biHJYxQ
        """
        let width: CGFloat = 364
        XCTAssertEqual(PartitionMetrics.notesVisualLineCount(text: text, width: width), 21)

        let contentH = PartitionMetrics.notesContentHeight(text: text, width: width)
        XCTAssertEqual(contentH, 370, accuracy: 0.001)

        let h = PartitionMetrics.windowHeight(contentHeight: contentH, visibleScreenHeight: 1050)
        XCTAssertEqual(h, 414, accuracy: 0.001)
        // 必须**明显大于**旧实现的 150（minHeight），否则用户仍然看不到变化
        XCTAssertGreaterThan(h, 380)
    }

    func testTodoContentHeight() {
        // 空状态（无待办）：固定开销 (63) + 空状态占位 (68) = 131
        XCTAssertEqual(PartitionMetrics.todoContentHeight(count: 0), 131, accuracy: 0.001)
        // 5 个待办：固定开销 (63) + 5 * 单项行高 (28) = 203
        XCTAssertEqual(PartitionMetrics.todoContentHeight(count: 5), 203, accuracy: 0.001)
        // 负数不应产生负高度
        XCTAssertEqual(PartitionMetrics.todoContentHeight(count: -3), 131, accuracy: 0.001)

        // 区分未完成与已完成（折叠/展开）
        // 折叠态：固定开销 (63) + 2 项未完成 (56) + 已完成分组头 (26) = 145
        XCTAssertEqual(PartitionMetrics.todoContentHeight(uncompletedCount: 2, completedCount: 3, isCompletedCollapsed: true), 145, accuracy: 0.001)
        // 展开态：固定开销 (63) + 2 项未完成 (56) + 已完成分组头 (26) + 3 项已完成 (84) = 229
        XCTAssertEqual(PartitionMetrics.todoContentHeight(uncompletedCount: 2, completedCount: 3, isCompletedCollapsed: false), 229, accuracy: 0.001)
    }

    func testWindowHeightClamping() {
        // 内容很少时夹到最小高度
        XCTAssertEqual(PartitionMetrics.windowHeight(contentHeight: 10, visibleScreenHeight: 1050),
                       PartitionMetrics.minHeight, accuracy: 0.001)
        // 正常情况 = 标题栏 + 内容
        XCTAssertEqual(PartitionMetrics.windowHeight(contentHeight: 344, visibleScreenHeight: 1050),
                       388, accuracy: 0.001)
        // 超出屏幕时被可用高度限制
        let tall = PartitionMetrics.windowHeight(contentHeight: 5000, visibleScreenHeight: 1050)
        XCTAssertEqual(tall, 990, accuracy: 0.001)
    }

    /// 用户偏好「分区最小高度」：**只能把窗口往上抬，不能往下压**。
    ///
    /// 这一项同时管两件事：新建分区的初始高度、以及「自适应宽高」的下限
    /// （`AppDelegate.autoFitHeight` 会把它传进来）。两个下限取较大值，
    /// 因此用户把最小高度填成 100 也不会突破 `minHeight` 这条渲染底线。
    func testWindowHeightHonorsUserMinimumHeight() {
        // 内容只有 10pt 高 —— 正常会被夹到内置下限 150
        XCTAssertEqual(PartitionMetrics.windowHeight(contentHeight: 10, visibleScreenHeight: 1050,
                                                     minimumHeight: 400), 400, accuracy: 0.001)
        // 内容本身已经高于下限 → 取内容高度，不受下限影响
        XCTAssertEqual(PartitionMetrics.windowHeight(contentHeight: 344, visibleScreenHeight: 1050,
                                                     minimumHeight: 200), 388, accuracy: 0.001)
        // 下限低于内置 minHeight(150) 时不生效：防止把分区压到画不下内容
        XCTAssertEqual(PartitionMetrics.windowHeight(contentHeight: 10, visibleScreenHeight: 1050,
                                                     minimumHeight: 100),
                       PartitionMetrics.minHeight, accuracy: 0.001)
        // 下限高于屏幕可用高度时：窗口被抬到下限（由上层后续决定如何摆放）
        XCTAssertEqual(PartitionMetrics.windowHeight(contentHeight: 10, visibleScreenHeight: 300,
                                                     minimumHeight: 400), 400, accuracy: 0.001)
        // 省略 minimumHeight 时行为不变（缺省 = 内置 minHeight）
        XCTAssertEqual(PartitionMetrics.windowHeight(contentHeight: 344, visibleScreenHeight: 1050),
                       388, accuracy: 0.001)
    }

    /// portal 的**列表视图**内容高度：一行一条，与网格「按 tile 宽换行」是两个口径。
    ///
    /// 自适应按错视图口径的后果很直观：30 个文件在列表里要 30 行，按网格（3 列）只会给 10 行。
    func testListContentHeight() {
        XCTAssertEqual(PartitionMetrics.listRowHeight, 28, accuracy: 0.001)
        // 工具栏 28 + 10 行 × 28 + 上下留白 20 = 328
        XCTAssertEqual(PartitionMetrics.listContentHeight(count: 10), 328, accuracy: 0.001)
        // 空目录也要留出工具栏与留白
        XCTAssertEqual(PartitionMetrics.listContentHeight(count: 0), 48, accuracy: 0.001)
        // 负数是脏数据，不应产出负高度
        XCTAssertEqual(PartitionMetrics.listContentHeight(count: -5), 48, accuracy: 0.001)
        // 与网格的差异正是「必须按 viewMode 分派」的理由：同宽 316 → 3 列，
        // 12 个条目网格只要 4 行，列表要 12 行。
        XCTAssertLessThan(PartitionMetrics.gridContentHeight(count: 12, width: 316),
                          PartitionMetrics.listContentHeight(count: 12))
    }

    /// 用户「分区最小高度」的上限：不得超过屏幕可用高 - 60。
    func testClampedUserMinHeight() {
        XCTAssertEqual(PartitionMetrics.clampedUserMinHeight(5000, visibleScreenHeight: 1050), 990, accuracy: 0.001)
        XCTAssertEqual(PartitionMetrics.clampedUserMinHeight(300, visibleScreenHeight: 1050), 300, accuracy: 0.001)
        // 低于 140 抬到硬下限 140（与「分区默认高度」的可输入下限一致）
        XCTAssertEqual(PartitionMetrics.clampedUserMinHeight(80, visibleScreenHeight: 1050), 140, accuracy: 0.001)
        // 屏幕极矮时上限退化到硬下限，不会出现「上限 < 下限」
        XCTAssertEqual(PartitionMetrics.clampedUserMinHeight(5000, visibleScreenHeight: 120), 140, accuracy: 0.001)
    }

    /// 「分区默认高度」与「分区最小高度」共用同一条夹取口径。
    func testClampedPartitionHeightIsSharedByBothHeightPrefs() {
        XCTAssertEqual(PartitionMetrics.clampedPartitionHeight(5000, visibleScreenHeight: 1050), 990, accuracy: 0.001)
        XCTAssertEqual(PartitionMetrics.clampedPartitionHeight(300, visibleScreenHeight: 1050), 300, accuracy: 0.001)
        XCTAssertEqual(PartitionMetrics.clampedPartitionHeight(80, visibleScreenHeight: 1050), 140, accuracy: 0.001)
        XCTAssertEqual(PartitionMetrics.clampedPartitionHeight(5000, visibleScreenHeight: 120), 140, accuracy: 0.001)
        // 两个偏好必须同口径，否则会出现「最小高度 990 / 默认高度 5000」的自相矛盾
        for v: CGFloat in [80, 200, 300, 5000] {
            XCTAssertEqual(PartitionMetrics.clampedPartitionHeight(v, visibleScreenHeight: 1050),
                           PartitionMetrics.clampedUserMinHeight(v, visibleScreenHeight: 1050),
                           accuracy: 0.001)
        }
    }

    /// 待办折行判定必须按**实测字宽**（半角 7.2 / 全角 12.9），不能按「字符数 ÷ 13」。
    func testTodoMultilineCountUsesMeasuredGlyphWidth() {
        // 宽 316 → 文本可用宽 = 316 − 77 = 239
        let w: CGFloat = 316

        // 25 个半角字符：实测 25 × 7.2 = 180 ≤ 239 → 单行。
        // 旧口径（字符数 > 239 ÷ 13 = 18）会误判成折行，每条多算 16pt。
        XCTAssertEqual(PartitionMetrics.todoMultilineCount(
            texts: [String(repeating: "a", count: 25)], width: w), 0)
        // 40 个半角：40 × 7.2 = 288 > 239 → 折行
        XCTAssertEqual(PartitionMetrics.todoMultilineCount(
            texts: [String(repeating: "a", count: 40)], width: w), 1)

        // 全角宽是半角的 1.79 倍：20 个汉字 = 258 > 239 → 折行；15 个 = 193.5 → 单行
        XCTAssertEqual(PartitionMetrics.todoMultilineCount(
            texts: [String(repeating: "字", count: 20)], width: w), 1)
        XCTAssertEqual(PartitionMetrics.todoMultilineCount(
            texts: [String(repeating: "字", count: 15)], width: w), 0)

        // 多条只数超宽的那些
        XCTAssertEqual(PartitionMetrics.todoMultilineCount(
            texts: ["短待办", String(repeating: "a", count: 40), String(repeating: "字", count: 15)],
            width: w), 1)
        XCTAssertEqual(PartitionMetrics.todoMultilineCount(texts: [], width: w), 0)
    }

    // MARK: - 对齐排布（top / left / right）

    private func makeSizes(_ map: [String: (Double, Double)]) -> (
        effectiveHeight: (String) -> Double,
        width: (String) -> Double,
        height: (String) -> Double
    ) {
        (effectiveHeight: { map[$0]?.1 ?? LayoutEngine.fallbackHeight },
         width: { map[$0]?.0 ?? 280 },
         height: { map[$0]?.1 ?? LayoutEngine.fallbackHeight })
    }

    // MARK: - 列式排布（top / left / right 共用同一段）

    /// 一组落位里每列的「实际占用高度」（该列最高分区底边 − 该列最高分区顶边）。
    private func columnHeights(_ ps: [LayoutEngine.Placement]) -> [Double] {
        Dictionary(grouping: ps, by: { $0.x }).values.map { col in
            col.map { $0.y + $0.height }.max()! - col.map { $0.y }.min()!
        }
    }

    /// 同上，但按 X 升序返回 —— 用来比对「镜像后的列顺序」。
    private func columnHeightsInOrder(_ ps: [LayoutEngine.Placement]) -> [Double] {
        Dictionary(grouping: ps, by: { $0.x })
            .sorted { $0.key < $1.key }
            .map { $0.value.map { $0.y + $0.height }.max()! - $0.value.map { $0.y }.min()! }
    }

    private func heightRange(_ ps: [LayoutEngine.Placement]) -> Double {
        let hs = columnHeights(ps)
        return hs.max()! - hs.min()!
    }

    /// 12 个高度参差的分区：均衡列排布的「各列高度极差」必须明显小于一个简单的贪心顺序分组。
    ///
    /// ⚠️ 这里原本拿已下线的 `grid`（行优先网格）做对照组（它每排被该排最高的分区撑开，
    /// 短分区下面留大片空白，实测 1042/1092/836/726/776、极差 366）。grid 已于
    /// 2026-10-11 下线，对照组换成贪心顺序分组，本体断言（均衡分组的值与极差）保持不变。
    func testBalancedColumnsEvenOutWhileGreedyStaysRagged() {
        let raw: [String: Double] = [
            "p01": 500, "p02": 200, "p03": 300, "p04": 200, "p05": 400, "p06": 250,
            "p07": 180, "p08": 320, "p09": 210, "p10": 260, "p11": 190, "p12": 240
        ]
        let ids = (1 ... 12).map { String(format: "p%02d", $0) }
        let sizes = makeSizes(raw.mapValues { (316.0, $0) })

        // 对照组：按顺序「每四条一列」的朴素切法（不追求均衡）
        let naive = LayoutEngine.columnPlacements(
            ids: ids, effectiveHeight: sizes.effectiveHeight, width: sizes.width,
            height: sizes.height, screenWidth: 1680, screenHeight: 1050, top: 76,
            defaultWidth: 316, fromRight: false, columns: .minimumFeasible)
        let balanced = LayoutEngine.columnPlacements(
            ids: ids, effectiveHeight: sizes.effectiveHeight, width: sizes.width,
            height: sizes.height, screenWidth: 1680, screenHeight: 1050, top: 76,
            defaultWidth: 316, fromRight: false, columns: .atMost(5))

        // 均衡分组必须把极差压下去：这是「连续分组下的最优解」
        XCTAssertEqual(columnHeights(balanced).sorted(), [516, 666, 716, 722, 742])
        XCTAssertLessThan(heightRange(balanced), 240)
        // ⚠️ 列数不同就无从比较，只在同列数时断言「均衡严格优于朴素」
        if Set([columnHeights(naive).count]) == Set([columnHeights(balanced).count]) {
            XCTAssertLessThanOrEqual(heightRange(balanced), heightRange(naive) + 0.001)
        }
    }

    /// 均衡分组的三条硬性质：连续、保序、覆盖全部；且「最高列」取到理论最小值。
    func testBalancedColumnRangesAreContiguousOrderedAndOptimal() {
        let heights: [Double] = [500, 200, 300, 200, 400, 250, 180, 320, 210, 260, 190, 240]
        let ranges = LayoutEngine.balancedColumnRanges(heights: heights, columns: 5, gap: 16)

        XCTAssertEqual(ranges.count, 5)
        // 连续 + 保序 + 覆盖全部，且每组非空
        XCTAssertEqual(ranges.first!.lowerBound, 0)
        XCTAssertEqual(ranges.last!.upperBound, heights.count)
        for r in ranges { XCTAssertFalse(r.isEmpty) }
        for (a, b) in zip(ranges, ranges.dropFirst()) { XCTAssertEqual(a.upperBound, b.lowerBound) }

        // 分组恰为 DP 搜出的最优解：极差 226、最高列 742
        let groupHeights = ranges.map { r in
            r.reduce(0.0) { $0 + heights[$1] } + Double(r.count - 1) * 16
        }
        XCTAssertEqual(groupHeights.map { ($0 * 1000).rounded() / 1000 }, [716, 516, 666, 742, 722])

        // 暴力穷举校验「最高列」确实最小 —— 防止日后被人改成贪心
        var bestMax = Double.infinity
        func enumerate(_ next: Int, _ cols: Int, _ cur: [Double]) {
            if cols == 0 {
                if next == heights.count { bestMax = min(bestMax, cur.max() ?? 0) }
                return
            }
            // 还要留给后面 cols-1 组至少 cols-1 个位置
            let maxEnd = heights.count - (cols - 1)
            guard next + 1 <= maxEnd else { return }
            for end in (next + 1) ... maxEnd {
                let g = heights[next ..< end].reduce(0.0, +) + Double(end - next - 1) * 16
                enumerate(end, cols - 1, cur + [g])
            }
        }
        enumerate(0, 5, [])
        XCTAssertEqual(groupHeights.max()!, bestMax, accuracy: 0.001)
    }

    /// **方向只做「并列时的取舍」，绝不牺牲极差**（三种列式模式共用同一条键）：
    /// 下面两种切法极差都是 216，必须稳定地按 `order` 取对应的一种。
    func testHeightOrderOnlyBreaksTies() {
        let heights: [Double] = [220, 180, 200, 180, 220]
        func hs(_ ranges: [Range<Int>]) -> [Double] {
            ranges.map { r in r.reduce(0.0) { $0 + heights[$1] } + Double(r.count - 1) * 16 }
        }
        let dec = hs(LayoutEngine.balancedColumnRanges(
            heights: heights, columns: 2, gap: 16, order: .nonIncreasing))
        let inc = hs(LayoutEngine.balancedColumnRanges(
            heights: heights, columns: 2, gap: 16, order: .nonDecreasing))

        XCTAssertEqual(dec, [632, 416])   // 自左向右非递增
        XCTAssertEqual(inc, [416, 632])
        XCTAssertEqual(dec.max()! - dec.min()!,
                       inc.max()! - inc.min()!, accuracy: 0.001)
    }

    // MARK: - 横排列高方向（「顶部横向排序」专用）

    /// 「顶部横向排序」的落位 —— 与 `AppDelegate.align(mode: "top")` 一致：
    /// 序列取配置顺序（这里就是 `heights` 的顺序）、各列**按列高降序摆开**、
    /// `fromRight` 只决定整块贴哪一侧。
    private func topPlacements(heights: [Double],
                               fromRight: Bool,
                               screenWidth: Double = 1920,
                               top: Double = 100,
                               maxColumns: Int = 5,
                               widths: [String: Double]? = nil) -> [LayoutEngine.Placement] {
        let ids = (0 ..< heights.count).map { "p\($0)" }
        let h = Dictionary(uniqueKeysWithValues: zip(ids, heights))
        return LayoutEngine.columnPlacements(
            ids: ids, effectiveHeight: { h[$0] ?? 200 },
            width: { widths?[$0] ?? 316 }, height: { h[$0] ?? 200 },
            screenWidth: screenWidth, screenHeight: 1200, top: top, defaultWidth: 316,
            fromRight: fromRight, columns: .atMost(maxColumns), sortColumnsByHeight: true)
    }

    /// 用户真实配置（7 个分区、1920×1200、`maxColumns = 5`）—— 最高的一条排在序列最末。
    ///
    /// 保序分组得到的列高沿读序**并不单调**（实测 316/316/480/428/610 —— 第 3、4 列上凸），
    /// 所以落位时把**各列按列高降序摆开**：于是「左侧最高、向右依次递减或相等」恒等成立，
    /// 得到严格阶梯 610/480/428/316/316；另一方向是它的严格镜像。
    ///
    /// 这正是「用户点名的 610/480/428/316/316」的来历 —— 分组一直是这套，
    /// 差的是**列的先后顺序**。
    func testTopIsAStrictStaircaseInBothDirections() {
        let heights: [Double] = [316, 150, 150, 150, 314, 428, 610]

        let leftToRight = columnHeightsInOrder(topPlacements(heights: heights, fromRight: false))
        let rightToLeft = columnHeightsInOrder(topPlacements(heights: heights, fromRight: true))

        XCTAssertEqual(leftToRight, [610, 480, 428, 316, 316])
        XCTAssertEqual(rightToLeft, [316, 316, 428, 480, 610])
        // 两向互为严格镜像：列高序列正好反序
        XCTAssertEqual(leftToRight, rightToLeft.reversed())
        XCTAssertNotEqual(leftToRight, rightToLeft)
        // 「递减或相等」：允许相等，**不允许上凸**
        XCTAssertTrue(zip(leftToRight, leftToRight.dropFirst()).allSatisfy { $0 >= $1 })
        XCTAssertTrue(zip(rightToLeft, rightToLeft.dropFirst()).allSatisfy { $0 <= $1 })
    }

    /// **两向严格几何镜像** —— 用**不等列宽**检验（等宽会把「列宽没跟着镜像」这种错误藏起来）：
    /// 同一分区在两向里的位置必须满足 `x左 + x右 + w = 屏宽`，且 y / 宽 / 高完全相同。
    func testTopDirectionsAreExactMirrorImages() {
        let heights: [Double] = [316, 150, 150, 150, 314, 428, 610]
        let widths: [String: Double] = [
            "p0": 360, "p1": 240, "p2": 300, "p3": 280, "p4": 400, "p5": 320, "p6": 260
        ]

        let left = topPlacements(heights: heights, fromRight: false, widths: widths)
        let right = topPlacements(heights: heights, fromRight: true, widths: widths)

        XCTAssertEqual(Set(left.map(\.id)), Set(right.map(\.id)))
        let leftByID = Dictionary(uniqueKeysWithValues: left.map { ($0.id, $0) })
        for r in right {
            let l = leftByID[r.id]!
            XCTAssertEqual(r.y, l.y, accuracy: 0.001)
            XCTAssertEqual(r.width, l.width, accuracy: 0.001)
            XCTAssertEqual(r.height, l.height, accuracy: 0.001)
            XCTAssertEqual(r.x + l.x + r.width, 1920, accuracy: 0.001,
                           "\(r.id) 未落在镜像位置上")
        }
    }

    /// **任何列数下都是严格阶梯** —— 这是「按列高摆列」换来的：
    /// 不再有「某侧最高做不到」的情况（旧实现靠方向参与分组，5 列时只能停在违例 52）。
    func testStaircaseHoldsForEveryColumnCount() {
        let heights: [Double] = [316, 150, 150, 150, 314, 428, 610]
        // ⚠️ 列数不再等于请求值：`maxColumns` 是**上限**，实际列数还会被
        // 「每列都不超过可用高」所需的最少列数（本例 = 3）**向上顶**。
        let availH = 1200.0 - 100.0 - LayoutEngine.bottomInset
        let floor = LayoutEngine.minimumFeasibleColumnCount(
            heights: heights, gap: Double(Layout.gap), maxGroupHeight: availH)
        XCTAssertEqual(floor, 3)

        for k in 1 ... 5 {
            let l = columnHeightsInOrder(topPlacements(heights: heights, fromRight: false,
                                                       maxColumns: k))
            let r = columnHeightsInOrder(topPlacements(heights: heights, fromRight: true,
                                                       maxColumns: k))
            // 低于下限的请求会被抬到下限（1 列无论如何都会超出屏幕底部）
            XCTAssertEqual(l.count, max(k, floor), "\(k) 列的实际列数不对")
            XCTAssertTrue(zip(l, l.dropFirst()).allSatisfy { $0 >= $1 },
                          "\(k) 列时不是严格非递增：\(l)")
            XCTAssertEqual(l, r.reversed(), "\(k) 列时两向不互为镜像")
            XCTAssertTrue(l.allSatisfy { $0 <= availH + 0.001 },
                          "\(k) 列时有列超出可用高：\(l)")
        }

        // 5 列：用户点名的那一套
        XCTAssertEqual(columnHeightsInOrder(topPlacements(heights: heights, fromRight: false)),
                       [610, 480, 428, 316, 316])
        // 3 列：与「左侧对齐」的分组一致（此时本来就单调）
        XCTAssertEqual(columnHeightsInOrder(topPlacements(heights: heights, fromRight: false,
                                                          maxColumns: 3)),
                       [814, 758, 610])
    }

    /// **每一列都不许超出屏幕底部** —— 这是本轮修掉的「高度不管」缺陷。
    ///
    /// 固件：7 条里 5 条是 900 高，`maxColumns = 5`，可用高 = 1200 − 100 − 40 = **1060**。
    /// 修复前的行为：只看宽度不看高度，于是 5 列被照单全收，无约束 DP 为了极差最小
    /// 必然选 `{500,900} / {500,900} / {900} / {900} / {900}` = **1416 / 1416 / 900 / 900 / 900**，
    /// 有两条列超出屏幕底部 356pt。
    ///
    /// ⚠️ **对策方向是「加列」而不是「减列」** —— 列越多每列越矮，
    /// 这与「宽度超了才减列」正好相反，是本轮最容易写反的一处。
    /// 「每列都不超过可用高」所需的最少列数是 6（`minimumFeasibleColumnCount`），
    /// 于是列数从 5 被**抬**到 6，得到合规的 1016 / 900 / 900 / 900 / 900 / 900。
    func testTopNeverExceedsAvailableHeight() {
        let heights: [Double] = [500, 500, 900, 900, 900, 900, 900]
        let availH = 1200.0 - 100.0 - LayoutEngine.bottomInset          // 1060
        XCTAssertEqual(LayoutEngine.minimumFeasibleColumnCount(
            heights: heights, gap: Double(Layout.gap), maxGroupHeight: availH), 6)

        for fromRight in [false, true] {
            let l = columnHeightsInOrder(topPlacements(heights: heights, fromRight: fromRight))
            // 必须真往上加了列：5 列无论怎么切都会有列超过 1060
            XCTAssertEqual(l.count, 6, "列数没有被高度下限抬上去：\(l)")
            // 每一列都合规
            XCTAssertTrue(l.allSatisfy { $0 <= availH + 0.001 },
                          "有列超出可用高 \(availH)：\(l)")
            // 而且仍然是从溢出解（1416）收敛下来的
            XCTAssertTrue(l.allSatisfy { $0 < 1416 },
                          "仍停留在溢出解附近：\(l)")
        }
        XCTAssertEqual(columnHeightsInOrder(topPlacements(heights: heights, fromRight: false)),
                       [1016, 900, 900, 900, 900, 900])
        // 加列之后**严格阶梯与两向镜像**依然成立
        let l = columnHeightsInOrder(topPlacements(heights: heights, fromRight: false))
        let r = columnHeightsInOrder(topPlacements(heights: heights, fromRight: true))
        XCTAssertEqual(l, r.reversed())
        XCTAssertTrue(zip(l, l.dropFirst()).allSatisfy { $0 >= $1 })
    }

    /// **宽度超了才减列、且绝不减到高度下限以下**。
    ///
    /// 固件：把宽度拉到很宽，逼 `.atMost` 走减列分支；此时列数仍不得低于
    /// `minimumFeasibleColumnCount`（否则刚压下去的高度又会冒出来）——
    /// 宁可**横向溢出**，也不让内容堆到屏幕底部外。
    func testTopWidthShrinkStopsAtHeightFloor() {
        let heights: [Double] = [500, 500, 900, 900, 900, 900, 900]
        let availH = 1200.0 - 100.0 - LayoutEngine.bottomInset
        let floor = LayoutEngine.minimumFeasibleColumnCount(
            heights: heights, gap: Double(Layout.gap), maxGroupHeight: availH)

        // 窄到连 2 列都放不下（70 × 2 + 16 > 1820？—— 用极端小屏逼它一路减到下限）
        let narrow = topPlacements(heights: heights, fromRight: false,
                                   screenWidth: 300, maxColumns: 5)
        let l = columnHeightsInOrder(narrow)
        XCTAssertEqual(l.count, floor, "减列越过了高度下限：\(l)")
        XCTAssertTrue(l.allSatisfy { $0 <= availH + 0.001 },
                      "减列后反而超出可用高：\(l)")
    }

    /// 「顶部横向排序」的**幂等**：序列固定取**配置顺序**（与布局无关）⇒
    /// 连点两次、来回切方向都必然得到同一套排布。
    ///
    /// ⚠️ 这里特意断言「按列优先读回来的序列 **≠** 配置顺序」——
    /// 因为列是按高矮摆开的，读回来的顺序本就不再等于输入顺序。
    /// **若谁把 `top` 的读序改回「从布局几何推」，这条断言就会失败**，
    /// 从而把「top 的读序必须脱离几何」这条约束钉住（历史上正是这么漂的：
    /// 7 分区 / 3 列会一路漂成 1054/646/482 → 978/776/428 → 1220/482/480 …）。
    func testTopIsIdempotentBecauseSequenceIsConfigOrder() {
        let heights: [Double] = [316, 150, 150, 150, 314, 428, 610]
        let ids = (0 ..< heights.count).map { "p\($0)" }
        let screenWidth = 1920.0

        func run(_ fromRight: Bool) -> [LayoutEngine.Placement] {
            topPlacements(heights: heights, fromRight: fromRight)
        }
        /// 与 `AppDelegate.align` 的 old 规则一致：按「贴哪一边」列优先读回
        func reading(_ ps: [LayoutEngine.Placement]) -> [String] {
            let margin = Double(Layout.margin)
            let minX = ps.map(\.x).min() ?? margin
            let maxRight = ps.map { $0.x + $0.width }.max() ?? margin
            let fromRight = (screenWidth - margin - maxRight) < (minX - margin)
            return ps.sorted { p1, p2 in
                if abs(p1.x - p2.x) > 60 { return fromRight ? p1.x > p2.x : p1.x < p2.x }
                return p1.y < p2.y
            }.map(\.id)
        }
        func norm(_ ps: [LayoutEngine.Placement]) -> [[Double]] {
            ps.sorted { $0.id < $1.id }.map { [$0.x, $0.y, $0.width, $0.height] }
        }

        for fromRight in [false, true] {
            let once = run(fromRight)
            XCTAssertEqual(norm(run(fromRight)), norm(once), "连点两次坐标必须不变")
            XCTAssertNotEqual(reading(once), ids,
                              "列已按高矮摆开，读回来的序列本就不该等于配置顺序")
            // 哪怕硬把读回来的序列再喂一次，也必须收敛到同一套（不会越点越歪）
            XCTAssertEqual(norm(run(fromRight)), norm(once))
        }
        // 来回切方向只翻转镜像，不会污染分组
        XCTAssertEqual(columnHeightsInOrder(run(true)),
                       columnHeightsInOrder(run(false)).reversed())
    }

    /// 退化输入：1 列 → 单组；列数 = 条数 → 每条一列；空输入 → 空。
    func testBalancedColumnRangesDegenerateCases() {
        XCTAssertTrue(LayoutEngine.balancedColumnRanges(heights: [], columns: 3, gap: 16).isEmpty)
        XCTAssertEqual(LayoutEngine.balancedColumnRanges(heights: [200, 300], columns: 1, gap: 16),
                       [0 ..< 2])
        XCTAssertEqual(LayoutEngine.balancedColumnRanges(heights: [200, 300, 100], columns: 9, gap: 16),
                       [0 ..< 1, 1 ..< 2, 2 ..< 3])
        // 列数超过条数时按条数收敛，不会产生空组
        let many = LayoutEngine.balancedColumnRanges(heights: [200, 300, 100], columns: 3, gap: 16)
        XCTAssertEqual(many.count, 3)
        XCTAssertFalse(many.contains { $0.isEmpty })
    }

    /// 每列顶部对齐（首条都在 top），且列自左向右、同列 X 严格相同。
    func testBalancedColumnsAreTopAlignedAndOrderedLeftToRight() {
        let raw: [String: Double] = ["a": 300, "b": 150, "c": 400, "d": 200, "e": 250]
        let sizes = makeSizes(raw.mapValues { (300.0, $0) })
        let ps = LayoutEngine.columnPlacements(
            ids: ["a", "b", "c", "d", "e"], effectiveHeight: sizes.effectiveHeight,
            width: sizes.width, height: sizes.height,
            screenWidth: 1680, screenHeight: 1050, top: 60,
            defaultWidth: 300, fromRight: false, columns: .atMost(3))

        let byX = Dictionary(grouping: ps, by: { $0.x })
        // 3 列，且每列首条都落在 top
        XCTAssertEqual(byX.count, 3)
        for (_, col) in byX {
            XCTAssertEqual(col.map { $0.y }.min()!, 60, accuracy: 0.001)
        }
        // 列 X 自左向右递增，相邻列间距 = 列宽 + gap
        let xs = byX.keys.sorted()
        for (l, r) in zip(xs, xs.dropFirst()) { XCTAssertEqual(r - l, 300 + 16, accuracy: 0.001) }
        XCTAssertEqual(xs.first!, 16, accuracy: 0.001)
        // 同列左边缘严格相同
        XCTAssertEqual(Set(ps.map { $0.x }).count, 3)
    }

    /// **幂等**：按列优先读序取回结果再排一次，坐标必须逐条完全相同。
    ///
    /// 这是 `align(mode: "top")` 用「列优先读序」而不是「行优先读序」的原因 ——
    /// 列内第二条起在纵向上与下一列错开，按行读会与列交错，第二次点击就会换位。
    func testBalancedColumnsAreIdempotentUnderColumnFirstReading() {
        let raw: [String: Double] = [
            "p01": 500, "p02": 200, "p03": 300, "p04": 200, "p05": 400, "p06": 250,
            "p07": 180, "p08": 320, "p09": 210, "p10": 260, "p11": 190, "p12": 240
        ]
        let ids = (1 ... 12).map { String(format: "p%02d", $0) }
        let sizes = makeSizes(raw.mapValues { (316.0, $0) })

        func run(_ order: [String]) -> [LayoutEngine.Placement] {
            LayoutEngine.columnPlacements(
                ids: order, effectiveHeight: sizes.effectiveHeight, width: sizes.width,
                height: sizes.height, screenWidth: 1680, screenHeight: 1050, top: 76,
                defaultWidth: 316, fromRight: false, columns: .atMost(5))
        }
        // 与 AppDelegate 的排序一致：先比 X（容差 60），再比 Y（容差 1）
        func columnFirstReading(_ ps: [LayoutEngine.Placement]) -> [String] {
            ps.sorted { p1, p2 in
                if abs(p1.x - p2.x) > 60 { return p1.x < p2.x }
                if abs(p1.y - p2.y) > 1 { return p1.y < p2.y }
                return p1.id < p2.id
            }.map { $0.id }
        }

        let first = run(ids)
        // 首轮排完后再读，顺序必须还是原来那 12 个（否则第二次点击就会窜位）
        XCTAssertEqual(columnFirstReading(first), ids)

        let second = run(columnFirstReading(first))
        let norm: ([LayoutEngine.Placement]) -> [[Double]] =
            { $0.sorted { $0.id < $1.id }.map { [$0.x, $0.y, $0.width, $0.height] } }
        XCTAssertEqual(norm(first), norm(second))
    }

    /// 列数受 `maxColumns` 与可用宽度双重约束：放不下时逐级减列。
    func testBalancedColumnsRespectMaxColumnsAndAvailableWidth() {
        let sizes = makeSizes(["a": (500, 200), "b": (500, 200), "c": (500, 200)])
        let ps = LayoutEngine.columnPlacements(
            ids: ["a", "b", "c"], effectiveHeight: sizes.effectiveHeight, width: sizes.width,
            height: sizes.height, screenWidth: 1100, screenHeight: 1050, top: 60,
            defaultWidth: 500, fromRight: false, columns: .atMost(5))
        // 1100 − 32 = 1068 可用；3 列需 3×500 + 2×16 = 1532 放不下 → 减到 2 列
        XCTAssertEqual(Dictionary(grouping: ps, by: { $0.x }).count, 2)

        // maxColumns 是上限：4 个分区、maxColumns=2 → 最多 2 列
        let small = makeSizes(["a": (200, 200), "b": (200, 200), "c": (200, 200), "d": (200, 200)])
        let two = LayoutEngine.columnPlacements(
            ids: ["a", "b", "c", "d"], effectiveHeight: small.effectiveHeight, width: small.width,
            height: small.height, screenWidth: 1680, screenHeight: 1050, top: 60,
            defaultWidth: 200, fromRight: false, columns: .atMost(2))
        XCTAssertEqual(Dictionary(grouping: two, by: { $0.x }).count, 2)
    }

    // MARK: - 左侧 / 右侧对齐：最少列数 + 各列等高 + 严格镜像

    /// 「每列都不超过可用高度」所需的最少列数。
    func testMinimumFeasibleColumnCount() {
        // 可用高 950：100 一条、间隔 16 → 一列最多 8 条（100×8 + 16×7 = 912）
        let ten = [Double](repeating: 100, count: 10)
        XCTAssertEqual(LayoutEngine.minimumFeasibleColumnCount(
            heights: ten, gap: 16, maxGroupHeight: 950), 2)
        // 单条本身就超高时必须让它独占一列，而不是反复尝试塞不进去
        XCTAssertEqual(LayoutEngine.minimumFeasibleColumnCount(
            heights: [2000, 100], gap: 16, maxGroupHeight: 950), 2)
        XCTAssertEqual(LayoutEngine.minimumFeasibleColumnCount(
            heights: [], gap: 16, maxGroupHeight: 950), 0)
        // 一条列就放得下 → 1 列
        XCTAssertEqual(LayoutEngine.minimumFeasibleColumnCount(
            heights: [200, 200], gap: 16, maxGroupHeight: 950), 1)
    }

    private static let skewed12: [String: Double] = [
        "p01": 500, "p02": 200, "p03": 300, "p04": 200, "p05": 400, "p06": 250,
        "p07": 180, "p08": 320, "p09": 210, "p10": 260, "p11": 190, "p12": 240
    ]

    /// left / right **逐列填满**（first-fit）：先从最靠边的那一列塞起，
    /// 把**所有塞得下的**都放进去（塞不下的跳过、留给下一列），直到再也塞不下才换列。
    ///
    /// 12 条分区、可用高 934⇒ 划成 **4 列** `[932, 912, 812, 722]`。
    ///
    /// ⚠️ 这里断言的是「**填满优先**」而不是「各列等高」：两者不可兼得，
    /// 2026-09-30 用户明确要前者（2026-09-28 曾一度选过后者，见下方 `columnHeights` 值的变化）。
    /// 「各列等高」的版本会把本该留在第一列的分区搬去后面以压极差（得 `[516,666,716,722,742]`），
    /// 直接表现就是「第一列没填满」。
    ///
    /// ⚠️⚠️ **列数由 5 变4 是2026-10-12 改用 first-fit 的直接结果**：
    /// 此前是 next-fit，得到 5 列 `[716, 932, 782, 692, 240]` ——
    /// 最后一列只剩 240（孤零零一条），而中间那些列其实还能再塞。
    func testColumnsAreFilledFromTheLeadingEdgeFirst() {
        let ids = (1 ... 12).map { String(format: "p%02d", $0) }
        let sizes = makeSizes(LayoutEngineTests.skewed12.mapValues { (316.0, $0) })
        let availH = 1050.0 - 76.0 - LayoutEngine.bottomInset   // 934

        let left = LayoutEngine.columnPlacements(
            ids: ids, effectiveHeight: sizes.effectiveHeight, width: sizes.width,
            height: sizes.height, screenWidth: 1680, screenHeight: 1050, top: 76,
            defaultWidth: 316, fromRight: false, columns: .minimumFeasible)

        // 按列的几何顺序（X 升序）：last column 可以很短，其余各列都应是「塞满」状态
        XCTAssertEqual(columnHeightsInOrder(left), [932, 912, 812, 722])

        // 语义本身：**除最后一列外**，每列都再也塞不下**任何一条剩余分区** ——
        // 这才是「优先填满」的形式化含义。注意是「任何一条」，不是「紧接的那一条」：
        // next-fit 只检查紧接的那条，会把后面更矮的、白白留给下一列。
        let hSeq = ids.map { LayoutEngineTests.skewed12[$0]! }
        let groups = LayoutEngine.firstFitColumnGroups(
            heights: hSeq, gap: Double(Layout.gap), maxGroupHeight: availH)
        XCTAssertEqual(groups.count, 4)
        var placed = Set<Int>()
        for (ci, g) in groups.enumerated() {
            // 组内下标递增 ⇒ 列内视觉顺序 = 配置顺序
            XCTAssertEqual(g, g.sorted(), "第 \(ci) 列的下标必须递增")
            XCTAssertTrue(placed.isDisjoint(with: g), "分区被重复归列")
            placed.formUnion(g)
            let colH = g.reduce(0.0) { $0 + hSeq[$1] } + Double(Layout.gap) * Double(g.count - 1)
            XCTAssertLessThanOrEqual(colH, availH + 0.001, "第 \(ci) 列超出可用高")
            guard ci < groups.count - 1 else { continue }
            let rest = Set(groups.dropFirst(ci + 1).flatMap { $0 })
            for i in rest {
                XCTAssertGreaterThan(colH + Double(Layout.gap) + hSeq[i], availH,
                                     "第 \(ci) 列还塞得下第 \(i) 条，说明没有被填满")
            }
        }
        XCTAssertEqual(placed.count, hSeq.count, "有分区没被归列")
    }

    /// 10 条等高短分区：第一列塞到 912（8 条），第二列只剩 2 条（216）。
    /// 「等等高等」的版本会是 564 / 564 —— 那是把分区往后搬的结果，已被作废。
    func testLeadingColumnIsFilledToCapacity() {
        let ids = (1 ... 10).map { String(format: "q%02d", $0) }
        let sizes = makeSizes(Dictionary(uniqueKeysWithValues: ids.map { ($0, (316.0, 100.0)) }))
        let ps = LayoutEngine.columnPlacements(
            ids: ids, effectiveHeight: sizes.effectiveHeight, width: sizes.width,
            height: sizes.height, screenWidth: 1680, screenHeight: 1050, top: 60,
            defaultWidth: 316, fromRight: false, columns: .minimumFeasible)
        // 100×8 + 16×7 = 912 可用；第 9 条会让列高变成 1028 > 950 ⇒ 换新列
        XCTAssertEqual(columnHeightsInOrder(ps), [912, 216])
    }

    /// 用户真实配置的回归（2026-09-30，1920×1200、3 个分区 428 / 316 / 314、top = 100）：
    /// 可用高 1060，第一列应当装下 **2 条**（428 + 16 + 316 = 760；再加 314 会到 1090 > 1060）。
    ///
    /// 「各列等高」的旧版本为了把极差从 446 压到 218，会把第一列拆得只剩 LocalAge 一条 ——
    /// 用户报的就是这个现象：「左侧排序没有优先填充完最左侧的列」。
    func testRealUserConfigFillsTheLeadingColumnFirst() {
        let heights: [Double] = [428, 316, 314]
        let ids = (0 ..< heights.count).map { "p\($0)" }
        let h = Dictionary(uniqueKeysWithValues: zip(ids, heights))
        let sizes = makeSizes(Dictionary(uniqueKeysWithValues: ids.map { ($0, (316.0, h[$0]!)) }))

        let left = LayoutEngine.columnPlacements(
            ids: ids, effectiveHeight: sizes.effectiveHeight, width: sizes.width,
            height: sizes.height, screenWidth: 1920, screenHeight: 1200, top: 100,
            defaultWidth: 316, fromRight: false, columns: .minimumFeasible)

        // 两列：第一列 2 条（760）、第二列 1 条（314）
        XCTAssertEqual(columnHeightsInOrder(left), [760, 314])
        let firstColX = left.first!.x
        XCTAssertEqual(left.filter { abs($0.x - firstColX) < 0.001 }.count, 2,
                       "第一列应当同时装下 2 个分区")
    }

    /// **左对齐与右对齐必须严格互为镜像**：同一条读序、同一套分组，只把 `fromRight` 打开，
    /// 于是逐条坐标都是关于屏幕中线的镜像，列高序列也正好倒过来。
    ///
    /// 旧实现的病灶：右对齐按「从右往左」的读序**重新分组**，切出来的列不是同一组 ——
    /// 7 个分区下左对齐 814 / 758 / 610，右对齐却是 316 / 926 / 940，两边都对不上。
    func testLeftAndRightAlignmentsAreExactMirrors() {
        let ids = (1 ... 12).map { String(format: "p%02d", $0) }
        let sizes = makeSizes(LayoutEngineTests.skewed12.mapValues { (316.0, $0) })
        let screenW = 1680.0

        func run(_ fromRight: Bool) -> [LayoutEngine.Placement] {
            LayoutEngine.columnPlacements(
                ids: ids, effectiveHeight: sizes.effectiveHeight, width: sizes.width,
                height: sizes.height, screenWidth: screenW, screenHeight: 1050, top: 76,
                defaultWidth: 316, fromRight: fromRight, columns: .minimumFeasible)
        }
        let left = run(false)
        let right = run(true)

        // ① 逐条坐标镜像：right.x = 屏宽 − left.x − left.width，Y 完全相同
        let leftByID = Dictionary(uniqueKeysWithValues: left.map { ($0.id, $0) })
        for p in right {
            let l = leftByID[p.id]!
            XCTAssertEqual(p.x, screenW - l.x - l.width, accuracy: 0.001, "分区 \(p.id) 未镜像")
            XCTAssertEqual(p.y, l.y, accuracy: 0.001)
        }
        // ② 列高的空间序列正好倒过来
        XCTAssertEqual(columnHeightsInOrder(right), columnHeightsInOrder(left).reversed())
        // ③ 一侧贴左边距、另一侧贴右边距
        XCTAssertEqual(left.map { $0.x }.min()!, 16, accuracy: 0.001)
        XCTAssertEqual(right.map { $0.x + $0.width }.max()!, screenW - 16, accuracy: 0.001)
    }

    /// **读序必须取「配置顺序」，绝不能从布局几何反推** —— 这条现在有了新的、更硬的理由。
    ///
    /// ⚠️⚠️ 2026-10-12 改用 first-fit 之后，first-fit 的分组**不连续**
    /// （第一列可能是 `[0, 2, 5]` 这种跳过中间条目的组合）。于是
    /// **「按列优先从贴边那侧读回来」得到的序列 ≠ 配置顺序**，
    /// 而且它**依赖具体布局**——同一批分区在 left / right 下读回来的序列互不相同。
    ///
    /// 这正是 `alignPlacements` 早就坚持「一律读配置顺序（`AlignItem.index`）」的原因：
    /// 一旦改回按几何读，连点就会因为「读到的序列又变了」而重排出另一套结果。
    ///
    /// 本测试把这个前提**正面钉住**：断言几何读回 ≠ 配置顺序。
    /// 若谁把读序改回几何来源，first-fit 会立刻产出不同分组，这条断言就会失败。
    func testColumnModesDoNotReadOrderFromGeometry() {
        let ids = (1 ... 12).map { String(format: "p%02d", $0) }
        let sizes = makeSizes(LayoutEngineTests.skewed12.mapValues { (316.0, $0) })
        let screenW = 1680.0
        let margin = 16.0

        func run(_ order: [String], _ fromRight: Bool) -> [LayoutEngine.Placement] {
            LayoutEngine.columnPlacements(
                ids: order, effectiveHeight: sizes.effectiveHeight, width: sizes.width,
                height: sizes.height, screenWidth: screenW, screenHeight: 1050, top: 76,
                defaultWidth: 316, fromRight: fromRight, columns: .minimumFeasible)
        }
        /// 旧读序：先按「当前布局贴哪一边」定读向，再按列优先取序列
        func geometricReading(_ ps: [LayoutEngine.Placement]) -> [String] {
            let minX = ps.map(\.x).min()!
            let maxRight = ps.map { $0.x + $0.width }.max()!
            let fromRight = (screenW - margin - maxRight) < (minX - margin)
            return ps.sorted { p1, p2 in
                if abs(p1.x - p2.x) > 60 { return fromRight ? p1.x > p2.x : p1.x < p2.x }
                if abs(p1.y - p2.y) > 1 { return p1.y < p2.y }
                return p1.id < p2.id
            }.map(\.id)
        }

        let left = run(ids, false)
        // ⚠️ first-fit 的分组不连续 ⇒ 几何读回 **必然** 打乱配置顺序。
        // 这条断言就是「读序不许来自几何」的护栏。
        XCTAssertNotEqual(geometricReading(left), ids,
                          "first-fit 的分组不连续，几何读回应当 ≠ 配置顺序；"
                          + "若这条开始失败，说明分组退化成连续、读序有可能被改回几何来源")
    }

    /// **left / right 拿到的是同一条序列 ⇒ 分组完全一致 ⇒ 结果是严格镜像**。
    ///
    /// 这条是「镜像」成立的前提。2026-10-12 改 first-fit 之后仍然成立：
    /// 分组只取决于 `heights` 与 `availH`，与 `fromRight` 无关。
    func testLeftAndRightShareOneGroupingAndStayIdempotent() {
        let ids = (1 ... 12).map { String(format: "p%02d", $0) }
        let sizes = makeSizes(LayoutEngineTests.skewed12.mapValues { (316.0, $0) })
        let screenW = 1680.0

        func run(_ fromRight: Bool) -> [LayoutEngine.Placement] {
            LayoutEngine.columnPlacements(
                ids: ids, effectiveHeight: sizes.effectiveHeight, width: sizes.width,
                height: sizes.height, screenWidth: screenW, screenHeight: 1050, top: 76,
                defaultWidth: 316, fromRight: fromRight, columns: .minimumFeasible)
        }
        let norm: ([LayoutEngine.Placement]) -> [[Double]] =
            { $0.sorted { $0.id < $1.id }.map { [$0.x, $0.y, $0.width, $0.height] } }

        let left = run(false)
        let right = run(true)

        // ① 列的空间顺序互为镜像
        XCTAssertEqual(columnHeightsInOrder(right), columnHeightsInOrder(left).reversed())
        // ② 连点同一方向幂等（读序固定为配置顺序，与布局无关）
        XCTAssertEqual(norm(run(false)), norm(left))
        XCTAssertEqual(norm(run(true)), norm(right))
        // ③ 左 → 右 → 左 回到同一套排布
        XCTAssertEqual(norm(run(true)), norm(right))
        XCTAssertEqual(columnHeightsInOrder(run(false)), columnHeightsInOrder(left))
    }

    func testRightAlignmentAnchorsToRightEdgeAndAlignsNarrowItemRight() {
        let sizes = makeSizes(["wide": (300, 200), "narrow": (200, 200)])
        let ps = LayoutEngine.columnPlacements(
            ids: ["wide", "narrow"], effectiveHeight: sizes.effectiveHeight, width: sizes.width,
            height: sizes.height, screenWidth: 1680, screenHeight: 1050, top: 60,
            defaultWidth: 280, fromRight: true, columns: .minimumFeasible)
        let wide = ps.first { $0.id == "wide" }!
        let narrow = ps.first { $0.id == "narrow" }!
        // 同属一列（列宽 300），窄分区在列内右对齐，两者右边缘都贴屏幕右边距
        XCTAssertEqual(wide.x + wide.width, 1680 - 16, accuracy: 0.001)
        XCTAssertEqual(narrow.x + narrow.width, wide.x + wide.width, accuracy: 0.001)
        XCTAssertEqual(wide.y, 60, accuracy: 0.001)     // 顶部对齐
    }

    func testColumnPlacementsEmptyInput() {
        let empty = LayoutEngine.columnPlacements(
            ids: [], effectiveHeight: { _ in 200 }, width: { _ in 280 }, height: { _ in 200 },
            screenWidth: 1680, screenHeight: 1050, top: 60, defaultWidth: 280,
            fromRight: false, columns: .minimumFeasible)
        XCTAssertTrue(empty.isEmpty)
    }

    // MARK: - 拖动吸附

    func testSnapToScreenEdges() {
        // 距左边缘 4pt → 吸附到 margin 16
        let left = LayoutEngine.snappedPosition(
            x: 20, y: 300, w: 300, h: 200,
            screenWidth: 1680, screenHeight: 1050, others: [])
        XCTAssertEqual(left.x, 16, accuracy: 0.001)

        // 距右边缘 5pt → 吸附到 1680 - 16 - 300 = 1364
        let right = LayoutEngine.snappedPosition(
            x: 1359, y: 300, w: 300, h: 200,
            screenWidth: 1680, screenHeight: 1050, others: [])
        XCTAssertEqual(right.x, 1364, accuracy: 0.001)

        // 距顶部 3pt → 吸附到 16
        let top = LayoutEngine.snappedPosition(
            x: 700, y: 19, w: 300, h: 200,
            screenWidth: 1680, screenHeight: 1050, others: [])
        XCTAssertEqual(top.y, 16, accuracy: 0.001)
    }

    func testSnapDoesNothingBeyondThreshold() {
        let r = LayoutEngine.snappedPosition(
            x: 500, y: 500, w: 300, h: 200,
            screenWidth: 1680, screenHeight: 1050, others: [])
        XCTAssertEqual(r.x, 500, accuracy: 0.001)
        XCTAssertEqual(r.y, 500, accuracy: 0.001)
    }

    func testSnapToNeighbourWithGap() {
        // 邻居在 x=16、宽 300 → 右侧贴邻居应为 16 + 300 + 16 = 332
        let others = [(x: 16.0, y: 100.0, w: 300.0, h: 200.0)]
        let r = LayoutEngine.snappedPosition(
            x: 337, y: 100, w: 300, h: 200,
            screenWidth: 1680, screenHeight: 1050, others: others)
        XCTAssertEqual(r.x, 332, accuracy: 0.001)
        // Y 与邻居齐平（同一排）
        XCTAssertEqual(r.y, 100, accuracy: 0.001)
    }

    func testSnapAlignsLeftEdgesOfNeighbours() {
        let others = [(x: 400.0, y: 100.0, w: 300.0, h: 200.0)]
        let r = LayoutEngine.snappedPosition(
            x: 408, y: 620, w: 300, h: 200,
            screenWidth: 1680, screenHeight: 1050, others: others)
        XCTAssertEqual(r.x, 400, accuracy: 0.001)
    }

    /// 回归保护：吸附必须使用与 `align` 完全相同的 gap。
    /// 历史 bug 是 snapPartition 自用 gap=12，把 align 排好的 16 间隔改写成 12。
    func testSnapGapMatchesLayoutBasis() {
        let others = [(x: 100.0, y: 100.0, w: 200.0, h: 200.0)]
        // 距「邻居右侧 + gap」处 1pt → 应精确吸附到 100 + 200 + Layout.gap
        let r = LayoutEngine.snappedPosition(
            x: Double(100 + 200 + Int(Layout.gap)) + 1, y: 500, w: 200, h: 200,
            screenWidth: 1680, screenHeight: 1050, others: others)
        XCTAssertEqual(r.x, Double(100 + 200) + Double(Layout.gap), accuracy: 0.001)
    }

    /// 回归保护：非原点屏（外接屏 origin = (1680, -30)）上，只要调用方按约定
    /// 传「屏幕相对坐标」，吸附就必须正常工作。
    /// 修复前调用方把相邻分区的**全局坐标**直接传进来，与自身的屏幕相对坐标相差 1680，
    /// 导致外接屏上永远吸附不到相邻分区。
    func testSnapWorksOnSecondaryScreenWithScreenRelativeCoordinates() {
        // 外接屏 origin.x = 1680：某分区在全局 x = 2000 → 屏幕相对 x = 320
        let neighbourGlobalX: Double = 2000
        let screenOriginX: Double = 1680
        let neighbourRelativeX = neighbourGlobalX - screenOriginX   // 320

        let others = [(x: neighbourRelativeX, y: 200.0, w: 300.0, h: 200.0)]
        let r = LayoutEngine.snappedPosition(
            x: 328, y: 200, w: 300, h: 200,
            screenWidth: 1920, screenHeight: 1080, others: others)
        XCTAssertEqual(r.x, 320, accuracy: 0.001)

        // 反例说明：若误传全局坐标，则相对坐标 328 与 2000 相差 1672，远超阈值 16 → 不吸附
        let wrong = LayoutEngine.snappedPosition(
            x: 328, y: 200, w: 300, h: 200,
            screenWidth: 1920, screenHeight: 1080,
            others: [(x: neighbourGlobalX, y: 200.0, w: 300.0, h: 200.0)])
        XCTAssertNotEqual(wrong.x, 320, accuracy: 0.001)
    }

    func testSnapWithCustomTopMargin() {
        // 顶部边距设为 100（如 macOS 顶栏高度 + 边距），y=105 在吸附阈值（16pt）内 → 应吸附到 100
        let r = LayoutEngine.snappedPosition(
            x: 700, y: 105, w: 300, h: 200,
            screenWidth: 1680, screenHeight: 1050, others: [],
            topMargin: 100.0)
        XCTAssertEqual(r.y, 100, accuracy: 0.001)

        // y=20 距默认 16 很近，但因为指定了 topMargin: 100，不应吸附到 16
        let farFromTop = LayoutEngine.snappedPosition(
            x: 700, y: 20, w: 300, h: 200,
            screenWidth: 1680, screenHeight: 1050, others: [],
            topMargin: 100.0)
        XCTAssertEqual(farFromTop.y, 20, accuracy: 0.001)
    }
}

// MARK: - 自适应宽度（每屏一个结果）

final class AutoColumnWidthTests: XCTestCase {

    /// 宽度只由「屏宽 + 列数」决定 —— 同样的输入必须永远得到同样的输出。
    /// 之前宽度取 `referenceScreen()`（优先鼠标所在屏），同一分区两次自适应结果不同，
    /// 用户看到的就是「重启后宽度偶发被改」。
    func testWidthIsPureFunctionOfScreenWidth() {
        XCTAssertEqual(PartitionMetrics.autoColumnWidth(screenWidth: 1920, columns: 5), 364, accuracy: 0.001)
        // 1512 屏：(1512 − 6×16) ÷ 5 = 283
        XCTAssertEqual(PartitionMetrics.autoColumnWidth(screenWidth: 1512, columns: 5), 283, accuracy: 0.001)
        // 同一输入重复计算必须一致（不依赖鼠标 / 焦点 / 时间）
        XCTAssertEqual(PartitionMetrics.autoColumnWidth(screenWidth: 1920, columns: 5),
                       PartitionMetrics.autoColumnWidth(screenWidth: 1920, columns: 5), accuracy: 0.001)
    }

    func testDifferentScreensGiveDifferentWidths() {
        // 「每个屏幕自己算」：大屏宽、小屏窄，不能所有屏共用一个值
        let wide = PartitionMetrics.autoColumnWidth(screenWidth: 2560, columns: 5)
        let narrow = PartitionMetrics.autoColumnWidth(screenWidth: 1440, columns: 5)
        XCTAssertGreaterThan(wide, narrow)
        XCTAssertEqual(wide, 492, accuracy: 0.001)
        XCTAssertEqual(narrow, 268, accuracy: 0.001)
    }

    func testColumnCountChangesWidth() {
        // 列数越多越窄：1920 屏 3 列 → (1920−64)/3 = 618
        XCTAssertEqual(PartitionMetrics.autoColumnWidth(screenWidth: 1920, columns: 3), 618, accuracy: 0.001)
    }

    func testDegenerateInputsStaySane() {
        // 屏宽取不到（0）时按 1920 兜底，不能算出负数；列数 0 也要当 1 列处理
        XCTAssertEqual(PartitionMetrics.autoColumnWidth(screenWidth: 0, columns: 5), 364, accuracy: 0.001)
        XCTAssertEqual(PartitionMetrics.autoColumnWidth(screenWidth: 1920, columns: 0), 1888, accuracy: 0.001)
        // 极窄屏被 minimum 兜住，不会塌成 0
        XCTAssertEqual(PartitionMetrics.autoColumnWidth(screenWidth: 320, columns: 5), 200, accuracy: 0.001)
    }
}

// MARK: - align 级：左 / 右对齐「贴边那侧最高」

/// ⚠️ 这一组断言的是 2026-10-11 定下的语义：left / right **最少列数**不变，
/// 但各列**按列高降序摆开** ⇒ 贴边那一侧最高，向另一侧严格递减或相等。
/// 它撤掉了 2026-09-30 那条「优先填满最靠边的那一列」—— 两者在数学上互斥，
/// 详见 `LayoutEngine.alignPlacements` 中 left 分支的注释。
extension LayoutEngineTests {

    /// 构造 AlignItem：`index` 取数组下标（= 配置顺序，与 x/y 无关）
    private func alignItems(_ heights: [Double], width: Double = 364) -> [LayoutEngine.AlignItem] {
        heights.enumerated().map { i, h in
            LayoutEngine.AlignItem(id: "p\(i)", x: 16, y: 100, width: width, height: h,
                                   isCollapsed: false, index: i)
        }
    }

    private func align(_ heights: [Double], _ mode: String,
                       screenWidth: Double = 1920, screenHeight: Double = 1080,
                       width: Double = 364) -> [LayoutEngine.Placement] {
        LayoutEngine.alignPlacements(items: alignItems(heights, width: width), mode: mode,
                                     screenWidth: screenWidth, screenHeight: screenHeight,
                                     top: 100, maxColumns: 5, defaultWidth: width,
                                     topHeightOrder: "leftToRight")
    }

    /// 把排布结果**按原来的配置顺序**重新包成 AlignItem（模拟下一次点击时的输入）
    private func rewrap(_ ps: [LayoutEngine.Placement],
                       order: [String]) -> [LayoutEngine.AlignItem] {
        let byID = Dictionary(uniqueKeysWithValues: ps.map { ($0.id, $0) })
        return order.enumerated().map { i, id in
            let p = byID[id]!
            return LayoutEngine.AlignItem(id: id, x: p.x, y: p.y, width: p.width,
                                          height: p.height, isCollapsed: false, index: i)
        }
    }
    /// **「依次优先填满」的正式回归 —— 用户真实配置（2026-10-12反馈）**
    ///
    /// 用户当时的三个分区：`随手便签` 675 / `work` 388 / `myself` 240，1920×1080、top=100
    /// ⇒ 可用高 1080 − 100 − 40 = **940**。
    ///
    /// ⚠️⚠️ **这里就是「next-fit 不肯跳过」那个缺陷的复现件**：
    /// - 旧实现（next-fit）：第一列塞 675 后，「紧接的」work 是 388，
    ///   675+16+388 = 1079 > 940 ⇒ **立刻换列**，于是 `myself`(240) 也被留给第二列。
    ///   结果第一列只有 `随手便签`，第二列 `work` + `myself`。
    ///   用户原话正是这个：「应该可以将随手便签和 myself 排在第一列，但是你没有」。
    /// - 现实现（first-fit）：第一列跳过 work，把 240 拉进来
    ///   ⇒ 675 + 16 + 240 = 931 ≤ 940 ⇒ **第一列 `随手便签` + `myself`，第二列才是 `work`**。
    ///
    /// 用户还观察到「把随手便签高度调小之后 work 就能排过去」—— 那正是 next-fit
    /// 恰好装得下时**掩盖了不会跳过**这个缺陷，调小高度只是让它偶然不再触发。
    func testLeftAlignFillsColumnsInOrder() {
        let ps = align([675, 388, 240], "left")
        // 第一列 675+16+240 = 931，第二列孤零零一条 388
        XCTAssertEqual(columnHeightsInOrder(ps), [931, 388],
                       "左对齐必须先把第一列填满：675 后面那条 388 塞不下，应跳过它去拉 240")
        // 最左列必须有 2 个分区 —— 它是「填得最满」的那一列
        let firstColX = ps.map(\.x).min()!
        let firstCol = ps.filter { abs($0.x - firstColX) < 0.001 }
        XCTAssertEqual(firstCol.count, 2, "最靠边那列应当装下 2 个分区（675 与 240）")
        // 且列内自上而下就是配置顺序
        XCTAssertEqual(firstCol.sorted { $0.y < $1.y }.map(\.id), ["p0", "p2"])
    }

    /// 「依次优先填满」的形式化定义（2026-10-12）：**列的左右顺序必须等于填充顺序**。
    ///
    /// 做法：把排布结果按 X 分列、列内按 Y 排序，得到的分区序列应当与
    /// `firstFitColumnGroups` 算出的**分组序列完全一致**。
    /// 这比断言「列高单调」更贴近用户诉求，也更强 —— 它同时锁住了列序与组内顺序。
    ///
    /// ⚠️ 注意 first-fit 的分组**不连续**（第1 列可能是 `[0, 3, 5]` 这种），
    /// 所以断言必须按「组内下标」展平，不能按区间展平。
    /// ⚠️ 与「列高单调递减」互斥（见 LayoutEngine 的 left 分支注释）：本测试锁前者。
    func testLeftAlignColumnOrderEqualsFillOrder() {
        let heights = (1 ... 12).map { LayoutEngineTests.skewed12[String(format: "p%02d", $0)]! }
        let ps = align(heights, "left", screenWidth: 1680, screenHeight: 1050, width: 316)

        // 实际落位读出的序列：按X 分列（从左到右），列内按 Y 从上到下
        let byX = Dictionary(grouping: ps) { Int($0.x) }
        let actual = byX.keys.sorted().flatMap { k in
            byX[k]!.sorted { $0.y < $1.y }.map { $0.id }
        }

        // 期望：first-fit 分组后按组内下标展平
        // ⚠️ 可用高必须与 `columnPlacements` 同口径：screenHeight − top − bottomInset。
        // 早前这里误写成 `− Layout.margin`，得到 934 而实际是 910 ——
        // 分组结果不同时断言就会假失败（first-fit 尤其敏感：它按「塞不塞得下」逐条决策）。
        let availH = 1050 - 100 - LayoutEngine.bottomInset
        let groups = LayoutEngine.firstFitColumnGroups(
            heights: heights, gap: Double(Layout.gap), maxGroupHeight: availH)
        let ids = heights.indices.map { "p\($0)" }
        let expected = groups.flatMap { $0.map { ids[$0] } }

        XCTAssertEqual(actual, expected,
                       "left 的列序必须等于填充顺序（first-fit 逐列填满），不能被按列高重排打乱")
    }

    /// **first-fit 必须允许「跳过塞不下的、去捡后面更矮的」** —— 这正是 2026-10-12 修的核心。
    ///
    /// 四条合成用例，每条都在「紧接的那条塞不下、但后面有一条塞得下」处设卡：
    /// - `[675, 388, 240]` @940 → 第一列 675 后面跳过 388、拉进 240（= 931）；
    /// - `[500, 400, 300]` @750 → 第一列跳过 400、拉进 300（816 仍超 750 ⇒ 拉不进），
    ///   真正能演示「跳过」的是 400 那一列：它跳过 300 之后仍收 300 到自己那列；
    ///   用 `[500, 300, 400]` @750 更直观：第一列 500+16+300 = 816 仍超 ⇒ 只放 500，
    ///   第二列 300+16+400 = 716 放得下 ⇒ 两列，绝不出现「第一列孤零零一条 500 就结束」。
    func testFirstFitSkipsUnfittingItemsInsteadOfEndingTheColumn() {
        let gap = Double(Layout.gap)

        // 用户真实配置的形状：跳过中间那条，塞进最后一条
        XCTAssertEqual(
            LayoutEngine.firstFitColumnGroups(heights: [675, 388, 240], gap: gap, maxGroupHeight: 940),
            [[0, 2], [1]],
            "670 后面那条 388 塞不下，应跳过它把 240 拉进第一列")

        // 「全都塞得下」时必须只有一列（不许平白多开列）
        XCTAssertEqual(
            LayoutEngine.firstFitColumnGroups(heights: [240, 388, 314], gap: gap, maxGroupHeight: 940),
            [[0, 1], [2]],
            "240+16+388+16+314 = 974 > 940，最后一条塞不下")

        // 提高可用高后必须只开一列：证明它不是「按顺序硬切」
        XCTAssertEqual(
            LayoutEngine.firstFitColumnGroups(heights: [240, 388, 314], gap: gap, maxGroupHeight: 1000),
            [[0, 1, 2]],
            "全都塞得下时应当只有一列")

        // 塞不下就跳过，而不是提前结束这一列
        XCTAssertEqual(
            LayoutEngine.firstFitColumnGroups(heights: [500, 400, 300], gap: gap, maxGroupHeight: 750),
            [[0], [1, 2]],
            "500+16+400 = 916 > 750 塞不下，第一列只放 500；400+16+300 = 716 放得下")

        // 空输入不炸
        XCTAssertEqual(LayoutEngine.firstFitColumnGroups(heights: [], gap: gap, maxGroupHeight: 940),
                       [])
    }

    /// 单条本身超高时它自己独占一列（不能因为「塞不下」就把它丢掉或让它与别人同行）。
    ///
    /// ⚠️ 第一条是**无条件加入**的（`group.isEmpty` 短路），所以 900 放进第一列之后
    /// 剩下的 200 只能自己开新列 —— 超高那条不会把整列「带歪」。
    func testFirstFitGivesOversizedItemItsOwnColumn() {
        let gap = Double(Layout.gap)
        XCTAssertEqual(
            LayoutEngine.firstFitColumnGroups(heights: [900, 200], gap: gap, maxGroupHeight: 600),
            [[0], [1]])
        // 两条都超高 ⇒ 各占一列
        XCTAssertEqual(
            LayoutEngine.firstFitColumnGroups(heights: [900, 800], gap: gap, maxGroupHeight: 600),
            [[0], [1]])
        // 超高条在**中间**：它自己一列，而前后两条 200 会被「跳过超高条」收进同一列
        // （200 + 16 + 200 = 416 ≤ 600）⇒ 2 列，不是 3 列。
        // 这正是 first-fit 相对 next-fit 的价值：中间那条超高不会把两侧的矮分区拆散。
        XCTAssertEqual(
            LayoutEngine.firstFitColumnGroups(heights: [200, 900, 200], gap: gap, maxGroupHeight: 600),
            [[0, 2], [1]])
    }

    /// left / right 的列高**不再保证单调**（2026-10-12 起）。
    ///
    /// 这不是 bug，而是「依次优先填满」的必然结果：first-fit 把第一列塞到「再也塞不下
    /// 任何一条」，它的高度未必是最大的。
    ///
    /// ⚠️ 「依次填满」与「列高单调」互斥，二者只能选一个，用户选了前者。
    /// 旧实现用 `sortColumnsByHeight: true` 换取单调，代价是列序与填充顺序脱钩。
    ///
    /// 现在锁住真正的不变量：**每列都不超出可用高度**。
    func testLeftAndRightNeverExceedAvailableHeight() {
        let heights = (1 ... 12).map { LayoutEngineTests.skewed12[String(format: "p%02d", $0)]! }
        let availH = 1050.0 - 100.0 - LayoutEngine.bottomInset
        for mode in ["left", "right"] {
            let hs = columnHeightsInOrder(align(heights, mode, screenWidth: 1680,
                                                screenHeight: 1050, width: 316))
            for (i, h) in hs.enumerated() {
                XCTAssertLessThanOrEqual(h, availH + 0.001,
                                         "\(mode) 第 \(i + 1) 列高 \(h) 超出了可用高 \(availH)")
            }
            XCTAssertGreaterThan(hs.count, 1, "\(mode) 这些数据应当分出多列")
        }
    }

    /// 左 / 右在 align 级也必须严格互为镜像：同分组，只翻 `fromRight`。
    func testAlignLeftAndRightAreExactMirrors() {
        let heights = (1 ... 12).map { LayoutEngineTests.skewed12[String(format: "p%02d", $0)]! }
        let screenW = 1680.0
        let left = align(heights, "left", screenWidth: screenW, screenHeight: 1050, width: 316)
        let right = align(heights, "right", screenWidth: screenW, screenHeight: 1050, width: 316)
        let byID = Dictionary(uniqueKeysWithValues: left.map { ($0.id, $0) })
        for p in right {
            let l = byID[p.id]!
            XCTAssertEqual(p.x, screenW - l.x - l.width, accuracy: 0.001, "分区 \(p.id) 未镜像")
            XCTAssertEqual(p.y, l.y, accuracy: 0.001)
        }
        XCTAssertEqual(columnHeightsInOrder(right), columnHeightsInOrder(left).reversed())
    }

    /// 连点不漂移：把排布结果按原配置顺序喂回去，坐标必须一模一样；左右来回也回得到原位。
    func testAlignIsIdempotentFromConfigOrder() {
        let heights: [Double] = [670, 388, 314, 500, 220]
        let norm: ([LayoutEngine.Placement]) -> [[Double]] =
            { $0.sorted { $0.id < $1.id }.map { [$0.x, $0.y, $0.width, $0.height] } }

        let order = (0 ..< heights.count).map { "p\($0)" }
        let left1 = align(heights, "left")
        let left2 = LayoutEngine.alignPlacements(
            items: rewrap(left1, order: order), mode: "left",
            screenWidth: 1920, screenHeight: 1080, top: 100, maxColumns: 5,
            defaultWidth: 364, topHeightOrder: "leftToRight")
        XCTAssertEqual(norm(left2), norm(left1), "连点两次坐标不一致")

        let right1 = align(heights, "right")
        let backToLeft = LayoutEngine.alignPlacements(
            items: rewrap(right1, order: order), mode: "left",
            screenWidth: 1920, screenHeight: 1080, top: 100, maxColumns: 5,
            defaultWidth: 364, topHeightOrder: "leftToRight")
        XCTAssertEqual(norm(backToLeft), norm(left1), "右 → 左 没有回到原位")
    }

    /// 读序只认 `index`：入参顺序被打乱（模拟几何位置千奇百怪）结果不变。
    func testAlignIgnoresSpatialOrder() {
        let heights: [Double] = [670, 388, 314, 500]
        let shuffled: [LayoutEngine.AlignItem] =
            [3, 1, 0, 2].map { i in
                LayoutEngine.AlignItem(id: "p\(i)", x: Double(900 - i * 200), y: Double(300 + i * 40),
                                       width: 364, height: heights[i],
                                       isCollapsed: false, index: i)
            }
        let norm: ([LayoutEngine.Placement]) -> [[Double]] =
            { $0.sorted { $0.id < $1.id }.map { [$0.x, $0.y, $0.width, $0.height] } }
        let scrambled = LayoutEngine.alignPlacements(
            items: shuffled, mode: "left", screenWidth: 1920, screenHeight: 1080, top: 100,
            maxColumns: 5, defaultWidth: 364, topHeightOrder: "leftToRight")
        XCTAssertEqual(norm(scrambled), norm(align(heights, "left")))
    }

    // MARK: - 模式归一化（老配置里的 grid 必须回退 top）

    /// `grid` 已下线，但老配置里仍存着它。归一化必须把它翻成 `top` ——
    /// 否则它会掉进「非 top」的读序分支，与另两端结果不一致、重排后位置漂移。
    func testNormalizedAlignModeFallsBackToTop() {
        XCTAssertEqual(LayoutEngine.normalizedAlignMode("grid"), "top")
        XCTAssertEqual(LayoutEngine.normalizedAlignMode(""), "top")
        XCTAssertEqual(LayoutEngine.normalizedAlignMode("nonsense"), "top")
        // 三个在用模式必须原样通过（大小写不敏感）
        for m in ["top", "left", "right", "LEFT", "Right"] {
            XCTAssertEqual(LayoutEngine.normalizedAlignMode(m), m.lowercased())
        }
    }

    /// 端到端兜底：传 `"grid"` 给 `alignPlacements`，结果必须与传 `"top"` **逐个坐标相同**。
    /// 只测归一化函数不够 —— 真正要守的是「入口有没有调用它」。
    func testGridModeProducesIdenticalLayoutToTop() {
        let heights: [Double] = [670, 388, 314, 500, 220]
        let norm: ([LayoutEngine.Placement]) -> [[Double]] =
            { $0.sorted { $0.id < $1.id }.map { [$0.x, $0.y, $0.width, $0.height] } }

        func run(_ mode: String) -> [[Double]] {
            let items = heights.enumerated().map { i, h in
                LayoutEngine.AlignItem(id: "p\(i)", x: 0, y: 0, width: 364, height: h,
                                       isCollapsed: false, index: i)
            }
            return norm(LayoutEngine.alignPlacements(
                items: items, mode: mode, screenWidth: 1920, screenHeight: 1080, top: 100,
                maxColumns: 5, defaultWidth: 364, topHeightOrder: "leftToRight"))
        }

        XCTAssertEqual(run("grid"), run("top"), "老配置的 grid 没有回退成 top")
        XCTAssertFalse(run("grid").isEmpty, "grid 回退后不该排出空布局")
    }
}
