import XCTest
@testable import DeskIsleCore

/// 配置历史快照的生成判据与命名。
///
/// 这里守的是**「恢复历史快照」的可回滚承诺**：UI 与文档都写着「覆盖之前会把当前状态
/// 另存一份，之后仍可再恢复回来」，而实现上这一个 -- 留底动作走的是 60s 节流闸门。
/// 用户点恢复的时刻往往刚发生过一次落盘（删分区、拖动都是立刻保存），
/// 于是闸门把它判成「距上次太近」直接跳过 —— 留底没写成，旧快照却照常覆盖了配置。
/// 这类错不报错、不崩溃，只在用户真的想回退时才现形，必须有断言兜住。
final class ConfigHistoryTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - 是否留快照

    func testRecentSaveIsThrottled() {
        // 10 秒前刚保存过，未到 60s 闸门 → 跳过（常规路径：拖动 / 连调设置不该刷爆名额）
        let last = now.addingTimeInterval(-10)
        XCTAssertFalse(ConfigHistory.shouldSnapshot(now: now,
                                                    lastHistoryAt: last,
                                                    minInterval: 60,
                                                    force: false))
    }

    func testSnapshotAfterIntervalElapses() {
        let last = now.addingTimeInterval(-61)
        XCTAssertTrue(ConfigHistory.shouldSnapshot(now: now,
                                                   lastHistoryAt: last,
                                                   minInterval: 60,
                                                   force: false))
    }

    /// 边界：恰好等于间隔。闸门是 `>=`，踩线应当放行（否则会退化成「必须超过一点点」）。
    func testExactlyAtIntervalPasses() {
        let last = now.addingTimeInterval(-60)
        XCTAssertTrue(ConfigHistory.shouldSnapshot(now: now,
                                                   lastHistoryAt: last,
                                                   minInterval: 60,
                                                   force: false))
    }

    /// **本轮修的那个 bug**：即时 expects 距上次保存只有半秒，forced 也必须留底。
    func testForceBypassesThrottle() {
        let last = now.addingTimeInterval(-0.5)
        XCTAssertTrue(ConfigHistory.shouldSnapshot(now: now,
                                                   lastHistoryAt: last,
                                                   minInterval: 60,
                                                   force: true))
    }

    /// 同一时刻（差 0 秒）也要留：这是「连续两次点恢复」会走到的分支。
    func testForceWorksEvenWhenLastIsNow() {
        XCTAssertTrue(ConfigHistory.shouldSnapshot(now: now,
                                                   lastHistoryAt: now,
                                                   minInterval: 60,
                                                   force: true))
    }

    func testZeroIntervalAlwaysSnapshots() {
        XCTAssertTrue(ConfigHistory.shouldSnapshot(now: now,
                                                   lastHistoryAt: now,
                                                   minInterval: 0,
                                                   force: false))
    }

    // MARK: - 快照命名（同秒撞名）

    func testNameHasNoSuffixWhenIndexIsZero() {
        XCTAssertEqual(ConfigHistory.snapshotFileName(base: "20261009-081530", collisionIndex: 0),
                       "deskisle_config-20261009-081530.json")
    }

    func testCollisionAppendsUnderscoreIndex() {
        XCTAssertEqual(ConfigHistory.snapshotFileName(base: "20261009-081530", collisionIndex: 1),
                       "deskisle_config-20261009-081530_1.json")
        XCTAssertEqual(ConfigHistory.snapshotFileName(base: "20261009-081530", collisionIndex: 2),
                       "deskisle_config-20261009-081530_2.json")
    }

    /// ⚠️ 这一条是命名规则的**真正用途**：快照目录没有别的时间戳字段，
    /// 「最新的一份」完全靠 `lastPathComponent` 字符串倒序取。
    /// 同秒里**后**写的（带 `_n`）必须排得更前，否则 `restoreLatestHistory` 会捞到更早的那一版。
    func testLaterSnapshotSortsFirst() {
        let first  = ConfigHistory.snapshotFileName(base: "20261009-081530", collisionIndex: 0)
        let second = ConfigHistory.snapshotFileName(base: "20261009-081530", collisionIndex: 1)

        // 复刻 Config.availableHistory 的排序
        let sorted = [first, second].sorted { $0 > $1 }
        XCTAssertEqual(sorted.first, second)
    }
}
