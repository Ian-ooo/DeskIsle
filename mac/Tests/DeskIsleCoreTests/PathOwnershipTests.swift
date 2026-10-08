import XCTest
@testable import DeskIsleCore

/// 事件路径 → 分区归属的测试。
///
/// 前缀比较的边界错一格，后果不是崩溃而是**静默的错刷新**：
/// 多认领 = 另一个分区被无谓地刷新；少认领 = 该刷新的分区不刷新（用户看到「改了没反应」）。
/// 所以每条边界都要有断言。
final class PathOwnershipTests: XCTestCase {

    // MARK: - 归一化

    func testNormalizeTrimsTrailingSlash() {
        XCTAssertEqual(PathOwnership.normalize("/a/b/"), "/a/b")
        XCTAssertEqual(PathOwnership.normalize("/a/b///"), "/a/b")
        XCTAssertEqual(PathOwnership.normalize("/a/b"), "/a/b")
    }

    /// 根目录 `/` 不能被削成空串 —— 削没了会让所有以 `/` 为根的判断失效。
    func testNormalizeKeepsRootSlash() {
        XCTAssertEqual(PathOwnership.normalize("/"), "/")
        XCTAssertEqual(PathOwnership.normalize(""), "")
    }

    // MARK: - 包含关系与前缀边界

    func testContainsSelfAndDescendants() {
        XCTAssertTrue(PathOwnership.contains(root: "/a/b", path: "/a/b"))
        XCTAssertTrue(PathOwnership.contains(root: "/a/b", path: "/a/b/c.txt"))
        XCTAssertTrue(PathOwnership.contains(root: "/a/b", path: "/a/b/c/d.txt"))
    }

    /// ⚠️ 本文件最重要的一条：`/a/b` 不能认领 `/a/bc`。
    func testDoesNotMatchSiblingWithSharedPrefix() {
        XCTAssertFalse(PathOwnership.contains(root: "/a/b", path: "/a/bc"))
        XCTAssertFalse(PathOwnership.contains(root: "/a/b", path: "/a/bc/d.txt"))
    }

    func testDoesNotMatchParentOrUnrelated() {
        XCTAssertFalse(PathOwnership.contains(root: "/a/b/c", path: "/a/b"))
        XCTAssertFalse(PathOwnership.contains(root: "/a/b", path: "/x/y"))
    }

    func testContainsToleratesTrailingSlashOnRoot() {
        XCTAssertTrue(PathOwnership.contains(root: "/a/b/", path: "/a/b/c.txt"))
    }

    func testEmptyInputsAreNotContained() {
        XCTAssertFalse(PathOwnership.contains(root: "", path: "/a"))
        XCTAssertFalse(PathOwnership.contains(root: "/a", path: ""))
    }

    // MARK: - 归属

    func testOwnerFindsTheOnlyMatch() {
        let roots = ["p1": "/Users/yang/Documents/work", "p2": "/Users/yang/Documents/myself"]
        XCTAssertEqual(PathOwnership.owner(of: "/Users/yang/Documents/work/a.txt", roots: roots), "p1")
        XCTAssertEqual(PathOwnership.owner(of: "/Users/yang/Documents/myself", roots: roots), "p2")
    }

    /// 两个分区的根目录互相嵌套时，归给**更具体**的那个。
    func testNestedRootsPickMostSpecific() {
        let roots = ["outer": "/x", "inner": "/x/y"]
        XCTAssertEqual(PathOwnership.owner(of: "/x/y/f.txt", roots: roots), "inner")
        XCTAssertEqual(PathOwnership.owner(of: "/x/y", roots: roots), "inner")
        XCTAssertEqual(PathOwnership.owner(of: "/x/z/f.txt", roots: roots), "outer")
        XCTAssertEqual(PathOwnership.owner(of: "/x", roots: roots), "outer")
    }

    func testOwnerIsNilOutsideAllRoots() {
        let roots = ["p1": "/a"]
        XCTAssertNil(PathOwnership.owner(of: "/b/f.txt", roots: roots))
        XCTAssertNil(PathOwnership.owner(of: "/ab/f.txt", roots: roots))
    }

    func testOwnerIgnoresEmptyRootPaths() {
        // 未选目录的 portal 分区在配置里 folderPath 就是空串
        let roots = ["empty": "", "real": "/a"]
        XCTAssertEqual(PathOwnership.owner(of: "/a/f.txt", roots: roots), "real")
        XCTAssertNil(PathOwnership.owner(of: "/b/f.txt", roots: roots))
    }

    // MARK: - 父目录（事件相关性判据）

    func testParent() {
        XCTAssertEqual(PathOwnership.parent(of: "/a/b/c.txt"), "/a/b")
        XCTAssertEqual(PathOwnership.parent(of: "/a/b/"), "/a")
        XCTAssertEqual(PathOwnership.parent(of: "/a"), "/")
    }

    func testParentOfRootAndEmpty() {
        XCTAssertEqual(PathOwnership.parent(of: "/"), "")
        XCTAssertEqual(PathOwnership.parent(of: ""), "")
    }

    // MARK: - 事件相关性（要不要拖着列表刷新）

    /// 正在浏览 `/root/sub` 时：它自己的条目变动要刷新，深层噪音不要。
    func testListingRelevanceForSubdirectoryBrowsing() {
        let shown = "/root/sub"
        XCTAssertTrue(PathOwnership.affectsListing(eventPath: "/root/sub/新建文稿.txt", shownDirectory: shown))
        XCTAssertTrue(PathOwnership.affectsListing(eventPath: shown, shownDirectory: shown))
        // `/root/sub/build` 是列表里**看得见的一行**，它自己被改名 / 改属性当然要刷新
        XCTAssertTrue(PathOwnership.affectsListing(eventPath: "/root/sub/build", shownDirectory: shown))
        // 深层：用户看不见，刷新它纯属浪费（正是 FSEvents 递归带来的新噪音）
        XCTAssertFalse(PathOwnership.affectsListing(eventPath: "/root/sub/build/obj/a.o", shownDirectory: shown))
        XCTAssertFalse(PathOwnership.affectsListing(eventPath: "/root/sub/build/obj", shownDirectory: shown))
    }

    /// 正在浏览根目录时：直接子项相关，隔着一层的无关。
    func testListingRelevanceForRootBrowsing() {
        let shown = "/root"
        XCTAssertTrue(PathOwnership.affectsListing(eventPath: "/root/a.txt", shownDirectory: shown))
        XCTAssertTrue(PathOwnership.affectsListing(eventPath: "/root", shownDirectory: shown))
        XCTAssertFalse(PathOwnership.affectsListing(eventPath: "/root/sub/a.txt", shownDirectory: shown))
        XCTAssertFalse(PathOwnership.affectsListing(eventPath: "/other/a.txt", shownDirectory: shown))
    }

    /// 正在浏览的目录被改名 / 删掉：事件路径是它的**祖先**，必须让视图知道，
    /// 否则视图会一直停在一个已不存在的路径上，谁也不通知它。
    func testListingRelevanceWhenShownDirectoryDisappears() {
        let shown = "/root/sub"
        XCTAssertTrue(PathOwnership.affectsListing(eventPath: "/root/sub2", shownDirectory: shown))
        XCTAssertTrue(PathOwnership.affectsListing(eventPath: "/root", shownDirectory: shown))
    }

    func testListingRelevanceWithEmptyShownDirectory() {
        XCTAssertFalse(PathOwnership.affectsListing(eventPath: "/root/a.txt", shownDirectory: ""))
    }
}
