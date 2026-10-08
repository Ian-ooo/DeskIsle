import XCTest
@testable import DeskIsleCore

final class FileSelectionTests: XCTestCase {

    /// 三端共用同一组场景：Windows `FileSelectionTests`、Electron `verify-logic.mts`。
    /// 改任何一条语义，**三处断言必须一起改**。
    private let v = ["/d/a.txt", "/d/b.txt", "/d/c.txt", "/d/d.txt"]

    // MARK: - 单击 / ⌘ 切换

    func testPlainClickReplacesSelection() {
        var s = FileSelection()
        s.click("/d/a.txt", visible: v)
        s.click("/d/c.txt", visible: v)
        XCTAssertEqual(s.selected, ["/d/c.txt"])
        XCTAssertEqual(s.anchor, "/d/c.txt")
    }

    func testCommandClickToggles() {
        var s = FileSelection()
        s.click("/d/a.txt", visible: v)
        s.click("/d/c.txt", visible: v, command: true)
        XCTAssertEqual(s.selected, ["/d/a.txt", "/d/c.txt"])
        // 再点一次 = 取消
        s.click("/d/c.txt", visible: v, command: true)
        XCTAssertEqual(s.selected, ["/d/a.txt"])
    }

    // MARK: - ⇧ 区间

    func testShiftSelectsRange() {
        var s = FileSelection()
        s.click("/d/b.txt", visible: v)
        s.click("/d/d.txt", visible: v, shift: true)
        XCTAssertEqual(s.selected, ["/d/b.txt", "/d/c.txt", "/d/d.txt"])
    }

    func testShiftRangeIsDirectionAgnostic() {
        var s = FileSelection()
        s.click("/d/d.txt", visible: v)          // 锚点在后面
        s.click("/d/b.txt", visible: v, shift: true)
        XCTAssertEqual(s.selected, ["/d/b.txt", "/d/c.txt", "/d/d.txt"])
        XCTAssertEqual(s.anchor, "/d/d.txt")     // 锚点**不动**
    }

    func testShiftWithoutAnchorIsPlainClick() {
        var s = FileSelection()
        s.click("/d/b.txt", visible: v, shift: true)
        XCTAssertEqual(s.selected, ["/d/b.txt"])
        XCTAssertEqual(s.anchor, "/d/b.txt")
    }

    func testShiftWithDeadAnchorIsPlainClick() {
        var s = FileSelection()
        s.click("/d/b.txt", visible: v)
        // 锚点被过滤掉了（搜索框里打字）→ 不能什么都不做，退化为单击
        s.click("/d/b.txt", visible: ["/d/b.txt"], shift: true)
        XCTAssertEqual(s.selected, ["/d/b.txt"])
        XCTAssertEqual(s.anchor, "/d/b.txt")
    }

    // MARK: - 刷新 / 清空

    func testRetainDropsVanishedPaths() {
        var s = FileSelection()
        s.click("/d/a.txt", visible: v)
        s.click("/d/b.txt", visible: v, command: true)
        s.retain(alive: ["/d/a.txt", "/d/c.txt"])     // b.txt 在别处被删了
        XCTAssertEqual(s.selected, ["/d/a.txt"])
        XCTAssertNil(s.anchor)                         // 锚点也没了
    }

    func testRetainKeepsSelectionWhileFiltering() {
        var s = FileSelection()
        s.click("/d/a.txt", visible: v)
        // ⚠️ retain 传的是**完整列表**，不是过滤后的：搜索时打了个字母，选区不该被清空
        s.retain(alive: Set(v))
        XCTAssertEqual(s.selected, ["/d/a.txt"])
        XCTAssertEqual(s.anchor, "/d/a.txt")
    }

    func testClearDropsEverything() {
        var s = FileSelection()
        s.click("/d/a.txt", visible: v)
        s.clear()
        XCTAssertTrue(s.selected.isEmpty)
        XCTAssertNil(s.anchor)
    }

    func testIsSelected() {
        var s = FileSelection()
        XCTAssertFalse(s.isSelected("/d/a.txt"))
        s.click("/d/a.txt", visible: v)
        XCTAssertTrue(s.isSelected("/d/a.txt"))
        XCTAssertFalse(s.isSelected("/d/b.txt"))
    }

    // MARK: - 选区顺序与右键目标（三端同源，Windows / Electron 有同名断言）

    func testOrderedSelectionFollowsDisplayOrder() {
        var s = FileSelection()
        // 故意按「b → a」的点击顺序选中：结果必须按显示顺序输出
        s.click("/d/b.txt", visible: v)
        s.click("/d/a.txt", visible: v, command: true)
        XCTAssertEqual(s.orderedSelection(visible: v), ["/d/a.txt", "/d/b.txt"],
                       "批量操作的先后与提示里列出的名字不能跟着点击顺序乱跳")
    }

    func testOrderedSelectionDropsFilteredOutItems() {
        var s = FileSelection()
        s.click("/d/a.txt", visible: v)
        s.click("/d/c.txt", visible: v, command: true)
        // 模拟搜索过滤：可见列表里只剩 a
        XCTAssertEqual(s.orderedSelection(visible: ["/d/a.txt"]), ["/d/a.txt"])
    }

    func testMenuTargetsUseWholeSelectionWhenClickingInsideIt() {
        var s = FileSelection()
        s.click("/d/a.txt", visible: v)
        s.click("/d/b.txt", visible: v, command: true)
        XCTAssertEqual(s.menuTargets(clicked: "/d/a.txt", visible: v),
                       ["/d/a.txt", "/d/b.txt"],
                       "点在选区内 → 菜单作用于整个选区")
    }

    func testMenuTargetsShrinkToClickedOneWhenClickingOutsideSelection() {
        var s = FileSelection()
        s.click("/d/a.txt", visible: v)
        XCTAssertEqual(s.menuTargets(clicked: "/d/b.txt", visible: v), ["/d/b.txt"],
                       "⚠️ 点在选区外只操作它自己 —— 否则「右键别的文件顺手删一下」会连坐")
    }

    func testMenuTargetsFallBackToClickedWhenSelectionIsAllFilteredOut() {
        var s = FileSelection()
        s.click("/d/c.txt", visible: v)
        // 选区里的 c 已被过滤掉：不能返回空数组（菜单会对着空气操作）
        XCTAssertEqual(s.menuTargets(clicked: "/d/c.txt", visible: ["/d/a.txt"]), ["/d/c.txt"])
    }

    // MARK: - 选区的作用域（活跃分区变化时是否失效）

    func testStaysWhenOwnPartitionBecomesActive() {
        // ⚠️ 反向用例同样要钉住：点自己的空白区 / 工具栏也会重发「我活跃」，
        // 若这里也清，选中就根本没法用了。
        XCTAssertFalse(FileSelectionScope.shouldClear(ownID: "p1", activeID: "p1"))
    }

    func testClearsWhenAnotherPartitionBecomesActive() {
        XCTAssertTrue(FileSelectionScope.shouldClear(ownID: "p1", activeID: "p2"),
                      "操作另一个分区 → 本分区的选中必须失效")
    }

    func testClearsWhenActiveIsOutsideAnyPartition() {
        XCTAssertTrue(FileSelectionScope.shouldClear(ownID: "p1", activeID: nil),
                      "点到桌面 / 别的应用 → 所有分区的选中都必须失效")
        XCTAssertTrue(FileSelectionScope.shouldClear(ownID: "p2", activeID: nil))
    }
}
