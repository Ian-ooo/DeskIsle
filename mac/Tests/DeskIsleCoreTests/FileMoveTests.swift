import XCTest
@testable import DeskIsleCore

final class FileMoveTests: XCTestCase {

    // MARK: - 同目录 = no-op

    func testSameDirectoryIsNoOp() {
        XCTAssertTrue(FileMove.isSameDirectory("/Users/me/a.txt", "/Users/me"))
        // 尾斜杠 / 相对成分差异不该影响判定
        XCTAssertTrue(FileMove.isSameDirectory("/Users/me/a.txt", "/Users/me/"))
        XCTAssertTrue(FileMove.isSameDirectory("/Users/me/./a.txt", "/Users/me"))
        // ⚠️ 软链（/private/var → /var）**不在**归一口径内：那要走 resolvingSymlinksInPath，
        // 而它对不存在路径会解出奇怪结果，拖放场景不值得为此冒险。
        XCTAssertFalse(FileMove.isSameDirectory("/Users/me/a.txt", "/Users/other"))
    }

    // MARK: - 拖自己 / 拖进子孙必须拒绝

    func testCannotMoveFolderIntoItself() {
        XCTAssertTrue(FileMove.isSelfOrDescendant("/Users/me/Foo", of: "/Users/me/Foo"))
        XCTAssertTrue(FileMove.isSelfOrDescendant("/Users/me/Foo/bar", of: "/Users/me/Foo"))
        // ⚠️ 这条是纯前缀比较最经典的误判：FooBar 不是 Foo 的子目录
        XCTAssertFalse(FileMove.isSelfOrDescendant("/Users/me/FooBar", of: "/Users/me/Foo"))
        XCTAssertFalse(FileMove.isSelfOrDescendant("/Users/other", of: "/Users/me/Foo"))
    }

    func testShouldMoveSkipsNoOpAndRejectsDescendant() {
        XCTAssertFalse(FileMove.shouldMove("/Users/me/a.txt", into: "/Users/me"))          // 同目录
        XCTAssertFalse(FileMove.shouldMove("/Users/me/Foo", into: "/Users/me/Foo/sub"))    // 进自己
        XCTAssertTrue(FileMove.shouldMove("/Users/other/a.txt", into: "/Users/me"))        // 正常搬入
    }

    // MARK: - 同名不覆盖

    func testDestinationSuffersNoOverwrite() {
        var existing: Set<String> = []
        let d = FileMove.destination(for: "/tmp/a.txt", directory: "/dst", exists: { existing.contains($0) })
        XCTAssertEqual(d, "/dst/a.txt")

        existing.insert("/dst/a.txt")
        let d2 = FileMove.destination(for: "/tmp/a.txt", directory: "/dst", exists: { existing.contains($0) })
        XCTAssertEqual(d2, "/dst/a 2.txt")

        existing.insert("/dst/a 2.txt")
        let d3 = FileMove.destination(for: "/tmp/a.txt", directory: "/dst", exists: { existing.contains($0) })
        XCTAssertEqual(d3, "/dst/a 3.txt")
    }

    func testDestinationKeepsExtensionOnSuffix() {
        // 无扩展名的目录名：后缀加在名字末尾，而不是被当成扩展名前插
        var existing: Set<String> = ["/dst/Photos"]
        let d = FileMove.destination(for: "/tmp/Photos", directory: "/dst", exists: { existing.contains($0) })
        XCTAssertEqual(d, "/dst/Photos 2")
    }

    func testDotfileIsTreatedAsWholeName() {
        // `.gitignore` 的点在 0 位：整串都算名字、没有扩展名。
        // 若按「空名字 + 扩展名」处理会产出 ` 2.gitignore`，与另两端不一致。
        let d = FileMove.destination(for: "/tmp/.gitignore", directory: "/dst") { $0 == "/dst/.gitignore" }
        XCTAssertEqual(d, "/dst/.gitignore 2")
    }

    func testDestinationNormalizesDirectory() {
        let d = FileMove.destination(for: "/tmp/a.txt", directory: "/dst/", exists: { _ in false })
        XCTAssertEqual(d, "/dst/a.txt")
    }

    // MARK: - 同名冲突检测（触发「保留两者 / 停止 / 替换」弹窗）

    func testConflictsDetectsSameNameOnly() {
        var existing: Set<String> = ["/dst/a.txt"]
        // a.txt 已存在 → 命中；b.txt 不存在 → 不命中
        let hits = FileMove.conflicts(["/tmp/a.txt", "/tmp/b.txt"], directory: "/dst") { existing.contains($0) }
        XCTAssertEqual(hits, ["/tmp/a.txt"])

        // 同目录（/dst/x.txt → /dst）不算冲突，只是 no-op
        let sameDir = FileMove.conflicts(["/dst/x.txt"], directory: "/dst") { _ in true }
        XCTAssertTrue(sameDir.isEmpty)

        // 把文件夹拖进它自己的子目录（/dst/Foo → /dst/Foo/sub）不算冲突，会被 shouldMove 拒绝
        let intoSelf = FileMove.conflicts(["/dst/Foo"], directory: "/dst/Foo/sub") { _ in true }
        XCTAssertTrue(intoSelf.isEmpty)
    }

    func testConflictsCountsOnlyMovableSources() {
        var existing: Set<String> = ["/dst/a.txt", "/dst/b.txt"]
        let hits = FileMove.conflicts(["/tmp/a.txt", "/tmp/b.txt", "/tmp/c.txt"],
                                     directory: "/dst") { existing.contains($0) }
        XCTAssertEqual(hits.sorted(), ["/tmp/a.txt", "/tmp/b.txt"])
    }

    // MARK: - 拖拽落点非法性检测

    func testIsDropTargetForbidden() {
        // 拖文件夹进自己 -> 禁止
        XCTAssertTrue(FileMove.isDropTargetForbidden(targetDirectory: "/Users/me/FolderA", draggedPaths: ["/Users/me/FolderA"]))
        // 拖文件夹进自己的子孙 -> 禁止
        XCTAssertTrue(FileMove.isDropTargetForbidden(targetDirectory: "/Users/me/FolderA/sub", draggedPaths: ["/Users/me/FolderA"]))
        // 拖文件夹进别的文件夹 -> 允许
        XCTAssertFalse(FileMove.isDropTargetForbidden(targetDirectory: "/Users/me/FolderB", draggedPaths: ["/Users/me/FolderA"]))
        // 拖普通文件进文件夹 -> 允许
        XCTAssertFalse(FileMove.isDropTargetForbidden(targetDirectory: "/Users/me/FolderA", draggedPaths: ["/Users/me/a.txt"]))
        // 拖普通文件进自己 -> 禁止
        XCTAssertTrue(FileMove.isDropTargetForbidden(targetDirectory: "/Users/me/a.txt", draggedPaths: ["/Users/me/a.txt"]))
        // 空拖拽集 -> 允许
        XCTAssertFalse(FileMove.isDropTargetForbidden(targetDirectory: "/Users/me/FolderA", draggedPaths: []))
    }
}
