import XCTest
@testable import DeskIsleCore

final class FileSortingTests: XCTestCase {

    struct Item {
        let name: String
        let isDir: Bool
        let size: Int64
        let modDate: Date
        let fileType: String
    }

    private func sortItems(_ items: inout [Item], sortBy: String, sortOrder: String) {
        items.sort { a, b in
            FileSorting.areInIncreasingOrder(
                aIsDir: a.isDir, aName: a.name, aSize: a.size, aModDate: a.modDate, aFileType: a.fileType,
                bIsDir: b.isDir, bName: b.name, bSize: b.size, bModDate: b.modDate, bFileType: b.fileType,
                sortBy: sortBy,
                sortOrder: sortOrder
            )
        }
    }

    // MARK: - 目录恒置顶

    func testDirectoriesAlwaysOnTopAscending() {
        var items = [
            Item(name: "file1.txt", isDir: false, size: 10, modDate: Date(), fileType: "txt"),
            Item(name: "dir1", isDir: true, size: 0, modDate: Date(), fileType: ""),
            Item(name: "file2.png", isDir: false, size: 20, modDate: Date(), fileType: "png"),
            Item(name: "dir2", isDir: true, size: 0, modDate: Date(), fileType: ""),
        ]
        sortItems(&items, sortBy: "name", sortOrder: "asc")
        XCTAssertEqual(items.map(\.name), ["dir1", "dir2", "file1.txt", "file2.png"])
    }

    func testDirectoriesAlwaysOnTopDescending() {
        var items = [
            Item(name: "file1.txt", isDir: false, size: 10, modDate: Date(), fileType: "txt"),
            Item(name: "dir1", isDir: true, size: 0, modDate: Date(), fileType: ""),
            Item(name: "file2.png", isDir: false, size: 20, modDate: Date(), fileType: "png"),
            Item(name: "dir2", isDir: true, size: 0, modDate: Date(), fileType: ""),
        ]
        sortItems(&items, sortBy: "name", sortOrder: "desc")
        XCTAssertEqual(items.map(\.name), ["dir2", "dir1", "file2.png", "file1.txt"])
    }

    // MARK: - 严格弱序（Strict Weak Ordering）公理

    func testStrictWeakOrderingAxioms() {
        let items = [
            Item(name: "DeskIsle", isDir: true, size: 0, modDate: Date(timeIntervalSince1970: 100), fileType: ""),
            Item(name: "eBook", isDir: true, size: 0, modDate: Date(timeIntervalSince1970: 100), fileType: ""),
            Item(name: "workbook", isDir: true, size: 0, modDate: Date(timeIntervalSince1970: 200), fileType: ""),
            Item(name: "希腊字母.png", isDir: false, size: 1024, modDate: Date(timeIntervalSince1970: 300), fileType: "png"),
        ]

        let sortBys = ["name", "time", "size", "type"]
        let sortOrders = ["asc", "desc"]

        for sortBy in sortBys {
            for sortOrder in sortOrders {
                for a in items {
                    // 1. 自反性：a < a 必须为 false
                    let selfOrder = FileSorting.areInIncreasingOrder(
                        aIsDir: a.isDir, aName: a.name, aSize: a.size, aModDate: a.modDate, aFileType: a.fileType,
                        bIsDir: a.isDir, bName: a.name, bSize: a.size, bModDate: a.modDate, bFileType: a.fileType,
                        sortBy: sortBy, sortOrder: sortOrder
                    )
                    XCTAssertFalse(selfOrder, "自反性违背：\(a.name) 按 \(sortBy) \(sortOrder) 比较自身返回了 true")

                    // 2. 反对称性：若 a < b 为 true，则 b < a 必须为 false
                    for b in items {
                        let ab = FileSorting.areInIncreasingOrder(
                            aIsDir: a.isDir, aName: a.name, aSize: a.size, aModDate: a.modDate, aFileType: a.fileType,
                            bIsDir: b.isDir, bName: b.name, bSize: b.size, bModDate: b.modDate, bFileType: b.fileType,
                            sortBy: sortBy, sortOrder: sortOrder
                        )
                        let ba = FileSorting.areInIncreasingOrder(
                            aIsDir: b.isDir, aName: b.name, aSize: b.size, aModDate: b.modDate, aFileType: b.fileType,
                            bIsDir: a.isDir, bName: a.name, bSize: a.size, bModDate: a.modDate, bFileType: a.fileType,
                            sortBy: sortBy, sortOrder: sortOrder
                        )
                        if ab {
                            XCTAssertFalse(ba, "反对称性违背：\(a.name) 与 \(b.name) 互为严格小于")
                        }
                    }
                }
            }
        }
    }

    // MARK: - 按类型降序排序的幂等性与稳定性（真实用户场景复现与验证）

    func testTypeDescendingSortStability() {
        let dirNames = [
            "软考速记手册", "eBook", "test", "in progress", "狂野AI大模型",
            "架构师课程", "DeskIsle", "project", "社保问题整理", "天机AI", "workbook"
        ]

        var items = dirNames.map {
            Item(name: $0, isDir: true, size: 0, modDate: Date(), fileType: "")
        }
        items.append(Item(name: "希腊字母.png", isDir: false, size: 100, modDate: Date(), fileType: "png"))

        // 第一次排序
        sortItems(&items, sortBy: "type", sortOrder: "desc")
        let firstOrder = items.map(\.name)

        // 验证文件在最后
        XCTAssertEqual(items.last?.name, "希腊字母.png")

        // 连续多次重排，必须严格幂等，绝对不能像历史 bug 那样来回颠倒
        for _ in 1...10 {
            sortItems(&items, sortBy: "type", sortOrder: "desc")
            XCTAssertEqual(items.map(\.name), firstOrder, "多次重排后顺序发生漂移或反转！")
        }
    }
}
