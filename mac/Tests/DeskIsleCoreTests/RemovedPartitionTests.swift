import XCTest
@testable import DeskIsleCore

/// 已下线分区类型的剔除判据测试。
///
/// ⚠️ 这批断言是**安全绳**：这里判断失误的代价是「用户的分区被永久丢掉」
/// （不是「少显示一个」，是配置里真的没了）。所以每条 undo 路径都要有断言。
///
/// 两端同防：Windows `RemovedPartitionTests`。改任何一条语义，**两处必须一起改**。
final class RemovedPartitionTests: XCTestCase {

    private func part(_ type: String, id: String = UUID().uuidString) -> [String: Any] {
        ["id": id, "type": type, "title": "t-\(type)"]
    }

    // MARK: - 谁被判死

    func testCollectionIsRemoved() {
        XCTAssertTrue(RemovedPartition.isRemoved("collection"))
    }

    func testLiveTypesAreKept() {
        for t in ["portal", "notes", "todo"] {
            XCTAssertFalse(RemovedPartition.isRemoved(t), "\(t) 仍受支持，不能被剔除")
        }
    }

    /// 未知类型**必须保留**：宁可渲染出一个可删除的空壳，也不能偷偷删掉用户的数据。
    /// 这是本文件里最重要的一条。
    func testUnknownTypeIsKept() {
        XCTAssertFalse(RemovedPartition.isRemoved("smart"))
        XCTAssertFalse(RemovedPartition.isRemoved(""))
        XCTAssertFalse(RemovedPartition.isRemoved("🤷‍♂️"))
    }

    // MARK: - 整份剔除

    func testDropsOnlyCollection() {
        let parts = [part("portal"), part("collection"), part("notes"),
                     part("collection"), part("todo")]
        let r = RemovedPartition.droppingRemovedTypes(parts)
        XCTAssertEqual(r.dropped, 2)
        XCTAssertEqual(r.kept.compactMap { $0["type"] as? String },
                       ["portal", "notes", "todo"], "保留项必须维持原顺序")
    }

    func testNothingToDropKeepsEverythingAndReportsZero() {
        let parts = [part("portal"), part("notes")]
        let r = RemovedPartition.droppingRemovedTypes(parts)
        XCTAssertEqual(r.dropped, 0, "调用方据此决定要不要落盘 —— 误报会让每次读盘都重写文件")
        XCTAssertEqual(r.kept.count, 2)
    }

    func testIdempotent() {
        let parts = [part("portal"), part("collection"), part("todo")]
        let once = RemovedPartition.droppingRemovedTypes(parts)
        let twice = RemovedPartition.droppingRemovedTypes(once.kept)
        XCTAssertEqual(twice.dropped, 0, "再跑一次必须什么都不做")
        XCTAssertEqual(twice.kept.count, once.kept.count)
    }

    func testEmptyAndMalformedEntries() {
        XCTAssertEqual(RemovedPartition.droppingRemovedTypes([]).dropped, 0)
        // 没有 type 的条目：当作未知类型保留，不删
        let weird: [[String: Any]] = [["id": "x"], ["type": 42], ["type": "collection"]]
        let r = RemovedPartition.droppingRemovedTypes(weird)
        XCTAssertEqual(r.dropped, 1, "只有明确写着 collection 的那一条被剔除")
        XCTAssertEqual(r.kept.count, 2)
    }

    // MARK: - 只过滤类型串

    func testKeepingSupported() {
        XCTAssertEqual(RemovedPartition.keepingSupported(["portal", "collection", "notes"]),
                       ["portal", "notes"])
        XCTAssertEqual(RemovedPartition.keepingSupported(["collection"]), [])
        XCTAssertEqual(RemovedPartition.keepingSupported([]), [])
    }
}
