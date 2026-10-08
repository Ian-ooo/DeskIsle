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

    // MARK: - 网格排布（top / grid）

    private func makeSizes(_ map: [String: (Double, Double)]) -> (
        effectiveHeight: (String) -> Double,
        width: (String) -> Double,
        height: (String) -> Double
    ) {
        (effectiveHeight: { map[$0]?.1 ?? LayoutEngine.fallbackHeight },
         width: { map[$0]?.0 ?? 280 },
         height: { map[$0]?.1 ?? LayoutEngine.fallbackHeight })
    }

    func testGridPlacesRowFirstWithAlignedColumnsAndRows() {
        let sizes = makeSizes([
            "a": (300, 200), "b": (300, 200), "c": (300, 200),
            "d": (300, 200), "e": (300, 200)
        ])
        let placements = LayoutEngine.gridPlacements(
            ids: ["a", "b", "c", "d", "e"],
            effectiveHeight: sizes.effectiveHeight,
            width: sizes.width,
            height: sizes.height,
            screenWidth: 1680, top: 60, maxColumns: 5, defaultWidth: 280)

        XCTAssertEqual(placements.count, 5)
        // 一屏放得下 5 列 → 全在同一排
        XCTAssertEqual(Set(placements.map { $0.y }), [60])
        // 同列 X 严格相同，且横向间距恒为 gap
        let xs = placements.map { $0.x }
        XCTAssertEqual(xs, [16, 332, 648, 964, 1280])
        for (i, p) in placements.enumerated() {
            XCTAssertEqual(p.id, ["a", "b", "c", "d", "e"][i])
            XCTAssertEqual(p.width, 300)
        }
    }

    func testGridWrapsWhenRowExceedsAvailableWidth() {
        let sizes = makeSizes(["a": (500, 200), "b": (500, 200), "c": (500, 200)])
        let placements = LayoutEngine.gridPlacements(
            ids: ["a", "b", "c"],
            effectiveHeight: sizes.effectiveHeight,
            width: sizes.width,
            height: sizes.height,
            screenWidth: 1100, top: 60, maxColumns: 5, defaultWidth: 280)
        // 1100 - 32 = 1068 可用；3 列需要 3×500 + 2×16 = 1532 > 1068 → 降为 2 列
        // 2 列需要 1016 ≤ 1068 ✓
        let firstRow = placements.filter { $0.y == 60 }
        XCTAssertEqual(firstRow.count, 2)
        // 第二排 Y = 60 + 行最大高 200 + gap 16
        let secondRow = placements.filter { $0.y == 276 }
        XCTAssertEqual(secondRow.count, 1)
    }

    func testGridUsesMaxEffectiveHeightForRowAdvance() {
        // 同一排里有一个折叠分区（高 44）和一个展开分区（高 300）→ 换行按 300 算
        let sizes = makeSizes(["tall": (300, 300), "folded": (300, 200)])
        let placements = LayoutEngine.gridPlacements(
            ids: ["tall", "folded"],
            effectiveHeight: { $0 == "folded" ? LayoutEngine.collapsedHeight : 300 },
            width: sizes.width,
            height: sizes.height,
            screenWidth: 1680, top: 60, maxColumns: 5, defaultWidth: 280)
        XCTAssertEqual(placements.map { $0.y }, [60, 60])
        // 第 3 个（如果有）才会换行；此处只验证同排 Y 一致
        XCTAssertEqual(Set(placements.map { $0.y }).count, 1)
    }

    func testGridEmptyInput() {
        let empty = LayoutEngine.gridPlacements(
            ids: [], effectiveHeight: { _ in 200 }, width: { _ in 280 },
            height: { _ in 200 }, screenWidth: 1680, top: 60, maxColumns: 5, defaultWidth: 280)
        XCTAssertTrue(empty.isEmpty)
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

    /// 12 个高度参差的分区：列优先均衡排布的「各列高度极差」必须明显小于行优先网格。
    ///
    /// 网格（旧行为）每排都被该排最高分区撑开，短分区下面留大片空白 ——
    /// 实测各列占用高度 1042/1092/836/726/776（极差 366）；
    /// 均衡列 716/516/666/742/722（极差 226），且这是**连续分组下的最优解**。
    func testBalancedColumnsEvenOutWhileGridStaysRagged() {
        let raw: [String: Double] = [
            "p01": 500, "p02": 200, "p03": 300, "p04": 200, "p05": 400, "p06": 250,
            "p07": 180, "p08": 320, "p09": 210, "p10": 260, "p11": 190, "p12": 240
        ]
        let ids = (1 ... 12).map { String(format: "p%02d", $0) }
        let sizes = makeSizes(raw.mapValues { (316.0, $0) })

        let grid = LayoutEngine.gridPlacements(
            ids: ids, effectiveHeight: sizes.effectiveHeight, width: sizes.width,
            height: sizes.height, screenWidth: 1680, top: 76, maxColumns: 5, defaultWidth: 316)
        let balanced = LayoutEngine.columnPlacements(
            ids: ids, effectiveHeight: sizes.effectiveHeight, width: sizes.width,
            height: sizes.height, screenWidth: 1680, screenHeight: 1050, top: 76,
            defaultWidth: 316, fromRight: false, columns: .atMost(5))

        XCTAssertEqual(columnHeights(grid).sorted(), [726, 776, 836, 1042, 1092])
        XCTAssertEqual(columnHeights(balanced).sorted(), [516, 666, 716, 722, 742])

        XCTAssertEqual(heightRange(grid), 366, accuracy: 0.001)
        // 极差必须显著更小（不是「差不多」，是数量级上的改善）
        XCTAssertLessThan(heightRange(balanced), 240)
        XCTAssertLessThan(heightRange(balanced), heightRange(grid) * 0.7)
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

    /// left / right **逐列填满**：先从最靠边的那一列塞起，塞到「再塞一条就超」才换列。
    ///
    /// 12 条分区、可用高 934 ⇒ 划成 5 列 `[716, 932, 782, 692, 240]`（升序 240…932）。
    ///
    /// ⚠️ 这里断言的是「**填满优先**」而不是「各列等高」：两者不可兼得，
    /// 2026-09-30 用户明确要前者（2026-09-28 曾一度选过后者，见下方 `columnHeights` 值的变化）。
    /// 「各列等高」的版本会把本该留在第一列的分区搬去后面以压极差（得 `[516,666,716,722,742]`），
    /// 直接表现就是「第一列没填满」。
    func testColumnsAreFilledFromTheLeadingEdgeFirst() {
        let ids = (1 ... 12).map { String(format: "p%02d", $0) }
        let sizes = makeSizes(LayoutEngineTests.skewed12.mapValues { (316.0, $0) })
        let availH = 1050.0 - 76.0 - LayoutEngine.bottomInset   // 934

        let left = LayoutEngine.columnPlacements(
            ids: ids, effectiveHeight: sizes.effectiveHeight, width: sizes.width,
            height: sizes.height, screenWidth: 1680, screenHeight: 1050, top: 76,
            defaultWidth: 316, fromRight: false, columns: .minimumFeasible)

        // 按列的几何顺序（X 升序）：last column 可以很短，其余各列都应是「塞满」状态
        XCTAssertEqual(columnHeightsInOrder(left), [716, 932, 782, 692, 240])

        // 语义本身：**除最后一列外**，每列再塞下「紧接的那一条」就会超出可用高度 ——
        // 这才是「优先填满」的形式化含义（用该列的下一条，不是全局最矮的一条）
        let hSeq = ids.map { LayoutEngineTests.skewed12[$0]! }
        let ranges = LayoutEngine.greedyFillColumnRanges(
            heights: hSeq, gap: Double(Layout.gap), maxGroupHeight: availH)
        for (ci, r) in ranges.enumerated() where ci < ranges.count - 1 {
            let colH = r.reduce(0.0) { $0 + hSeq[$1] } + Double(Layout.gap) * Double(r.count - 1)
            XCTAssertGreaterThan(colH + Double(Layout.gap) + hSeq[r.upperBound], availH,
                                 "第 \(ci) 列还能再塞下一条，说明没有被填满")
        }
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

    /// **从「贴边的那一侧」读回的序列与上一次排布用过的序列相同** ⇒ 连点同一个模式不窜位，
    /// 且「左 → 右 → 左」能回到同一套排布。
    ///
    /// 这条是「镜像」成立的前提：三个列式模式必须拿到**同一条序列**。
    func testColumnModesAreIdempotentThroughAnchorSideReading() {
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
        /// 与 AppDelegate 一致：先按「当前布局贴哪一边」定读向，再按列优先读序取序列
        func reading(_ ps: [LayoutEngine.Placement]) -> [String] {
            let minX = ps.map(\.x).min()!
            let maxRight = ps.map { $0.x + $0.width }.max()!
            let fromRight = (screenW - margin - maxRight) < (minX - margin)
            return ps.sorted { p1, p2 in
                if abs(p1.x - p2.x) > 60 { return fromRight ? p1.x > p2.x : p1.x < p2.x }
                if abs(p1.y - p2.y) > 1 { return p1.y < p2.y }
                return p1.id < p2.id
            }.map(\.id)
        }
        let norm: ([LayoutEngine.Placement]) -> [[Double]] =
            { $0.sorted { $0.id < $1.id }.map { [$0.x, $0.y, $0.width, $0.height] } }

        let left = run(ids, false)
        let right = run(ids, true)

        // 贴左的布局从左读、贴右的从右读 —— 都还原成同一个序列
        XCTAssertEqual(reading(left), ids)
        XCTAssertEqual(reading(right), ids)

        // 连点两次坐标完全不变
        XCTAssertEqual(norm(run(reading(left), false)), norm(left))
        XCTAssertEqual(norm(run(reading(right), true)), norm(right))
        // 左 → 右 → 左 回到同一套排布
        XCTAssertEqual(norm(run(reading(right), false)), norm(left))
        // 右 → 左 → 右 同理
        XCTAssertEqual(norm(run(reading(left), true)), norm(right))
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
