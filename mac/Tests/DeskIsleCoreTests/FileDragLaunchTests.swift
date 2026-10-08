import XCTest
@testable import DeskIsleCore

final class FileDragLaunchTests: XCTestCase {

    /// 两端共用同一组场景：Windows `FileDragLaunchTests`。
    /// 改任何一条语义，**两处断言必须一起改**。
    ///
    /// 场景编号即判据顺序，别重排 —— 出问题时按编号就能定位漏了哪一条。
    private let winA = 1001
    private let winB = 1002

    private func input(
        eventWindowID: Int,
        ownWindowID: Int?,
        downWindowID: Int,
        downInsideRow: Bool = true,
        alreadyBegan: Bool = false,
        anotherSessionActive: Bool = false,
        dx: Double = 10,
        dy: Double = 0
    ) -> DragLaunchInput {
        DragLaunchInput(eventWindowID: eventWindowID,
                        ownWindowID: ownWindowID,
                        downWindowID: downWindowID,
                        downInsideRow: downInsideRow,
                        alreadyBegan: alreadyBegan,
                        anotherSessionActive: anotherSessionActive,
                        dx: dx, dy: dy)
    }

    // MARK: - 0. 正常发起

    func testSameWindowAndEnoughMoveBegins() {
        XCTAssertTrue(FileDragLaunch.shouldBegin(
            input(eventWindowID: winA, ownWindowID: winA, downWindowID: winA)))
    }

    func testDiagonalMoveUsesSquaredDistance() {
        // 3²+3²=18 过阈值，但单独看 dx、dy 都只有 3pt —— 必须按**距离**算，不能按分量算
        XCTAssertTrue(FileDragLaunch.shouldBegin(
            input(eventWindowID: winA, ownWindowID: winA, downWindowID: winA, dx: 3, dy: 3)))
    }

    // MARK: - 1. 位移阈值（4pt，手抖不该变拖拽）

    func testTinyMoveDoesNotBegin() {
        XCTAssertFalse(FileDragLaunch.shouldBegin(
            input(eventWindowID: winA, ownWindowID: winA, downWindowID: winA, dx: 2, dy: 0)))
    }

    func testExactlyAtThresholdDoesNotBegin() {
        // 阈值是「严格大于」：恰好等于 4pt 不算拖动
        XCTAssertFalse(FileDragLaunch.shouldBegin(
            input(eventWindowID: winA, ownWindowID: winA, downWindowID: winA, dx: 4, dy: 0)))
    }

    func testJustOverThresholdBegins() {
        XCTAssertTrue(FileDragLaunch.shouldBegin(
            input(eventWindowID: winA, ownWindowID: winA, downWindowID: winA, dx: 4.001, dy: 0)))
    }

    // MARK: - 2. 窗口（本次事故的根因）

    func testEventFromAnotherWindowNeverBegins() {
        // ⚠️ 最关键的一条：在 B 窗口按下，A 窗口里同坐标的那一行不许发起 ——
        // 否则用户拖的是 B 的文件，被搬走的却是 A 里恰好同位置的另一个文件。
        XCTAssertFalse(FileDragLaunch.shouldBegin(
            input(eventWindowID: winB, ownWindowID: winA, downWindowID: winB)))
    }

    func testViewNotInAnyWindowNeverBegins() {
        XCTAssertFalse(FileDragLaunch.shouldBegin(
            input(eventWindowID: winA, ownWindowID: nil, downWindowID: winA)))
    }

    func testDownAndDragInDifferentWindowsDoesNotBegin() {
        XCTAssertFalse(FileDragLaunch.shouldBegin(
            input(eventWindowID: winA, ownWindowID: winA, downWindowID: winB)))
    }

    // MARK: - 3. 只有被按住的那一行能发起

    func testDownOutsideThisRowDoesNotBegin() {
        XCTAssertFalse(FileDragLaunch.shouldBegin(
            input(eventWindowID: winA, ownWindowID: winA, downWindowID: winA,
                  downInsideRow: false)))
    }

    // MARK: - 4. 一次按下只发起一次，全局同时只有一个会话

    func testAlreadyBeganDoesNotBeginAgain() {
        XCTAssertFalse(FileDragLaunch.shouldBegin(
            input(eventWindowID: winA, ownWindowID: winA, downWindowID: winA,
                  alreadyBegan: true)))
    }

    func testAnotherSessionActiveDoesNotBegin() {
        // 第二把锁：即便窗口判据被改坏，也保证一次拖动只带出一组文件
        XCTAssertFalse(FileDragLaunch.shouldBegin(
            input(eventWindowID: winA, ownWindowID: winA, downWindowID: winA,
                  anotherSessionActive: true)))
    }
}
