import XCTest
@testable import DeskIsleCore

/// 目录条目可见性与计数口径的测试。
///
/// 这里守的是**三处口径不许分叉**：网格列表、标题栏徽标、自适应高度都数同一件事。
/// 曾经分叉过，用户看到的就是「列表 10 项、徽标写 11」。
final class DirectoryScanTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deskisle-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func make(_ name: String) {
        FileManager.default.createFile(atPath: tmp.appendingPathComponent(name).path,
                                       contents: Data("x".utf8))
    }

    // MARK: - 可见性判据

    func testDotPrefixedIsHidden() {
        XCTAssertFalse(DirectoryScan.isVisible(".DS_Store"))
        XCTAssertFalse(DirectoryScan.isVisible(".git"))
        XCTAssertFalse(DirectoryScan.isVisible(".a"))
    }

    func testNormalNamesAreVisible() {
        // 中间带点、含 emoji、纯中文都不该被当成隐藏
        for n in ["a", "报告.pdf", "📁 目录", "a.b.c", "deskisle_config.json"] {
            XCTAssertTrue(DirectoryScan.isVisible(n), n)
        }
    }

    /// 以点开头的名字**一律**隐藏，哪怕后面还跟着点。别自作聪明地只认 `.` + 非点。
    func testNamesStartingWithDotAreHiddenEvenWithMoreDots() {
        XCTAssertFalse(DirectoryScan.isVisible("..hidden-in-name"))
        XCTAssertFalse(DirectoryScan.isVisible("..."))
    }

    /// 空名字既不是文件也不该被计数 —— 防止 `contentsOfDirectory` 里混进空串时多算一项。
    func testEmptyNameIsHidden() {
        XCTAssertFalse(DirectoryScan.isVisible(""))
    }

    // MARK: - 计数

    func testHiddenEntriesAreNotCounted() throws {
        make("a.txt"); make("b.txt"); make(".DS_Store"); make(".hidden")
        XCTAssertEqual(DirectoryScan.visibleCount(in: tmp.path), 2)
        XCTAssertEqual(DirectoryScan.visibleNames(in: tmp.path).sorted(), ["a.txt", "b.txt"])
    }

    func testMissingDirectoryCountsZero() {
        let gone = tmp.appendingPathComponent("不存在").path
        XCTAssertEqual(DirectoryScan.visibleCount(in: gone), 0)
        XCTAssertEqual(DirectoryScan.visibleNames(in: gone), [])
    }

    func testEmptyPathCountsZero() {
        XCTAssertEqual(DirectoryScan.visibleCount(in: ""), 0)
    }

    /// 只有隐藏项的目录：徽标应显示 0（而不是显示 1 个「看不见的东西」）。
    func testOnlyHiddenEntriesCountsZero() throws {
        make(".DS_Store"); make(".localized")
        XCTAssertEqual(DirectoryScan.visibleCount(in: tmp.path), 0)
    }

    /// 计数与列表**必须**是同一个数：这正是「徽标 ≠ 列表」那个 bug 的回归断言。
    func testCountAlwaysEqualsListLength() throws {
        make("one"); make("two"); make(".three"); make("four")
        let names = DirectoryScan.visibleNames(in: tmp.path)
        XCTAssertEqual(DirectoryScan.visibleCount(in: tmp.path), names.count)
        XCTAssertEqual(names.count, 3)
    }

    /// 目录也算一个可见条目（与网格一致：文件夹占一格）。
    func testDirectoryCountsAsOneEntry() throws {
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("folder"),
                                                withIntermediateDirectories: false)
        make("file")
        XCTAssertEqual(DirectoryScan.visibleCount(in: tmp.path), 2)
    }
}
