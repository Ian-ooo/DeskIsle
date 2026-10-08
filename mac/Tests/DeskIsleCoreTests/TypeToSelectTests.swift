import XCTest
@testable import DeskIsleCore

final class TypeToSelectTests: XCTestCase {
    let candidates = [
        ("Apple.txt", "/path/Apple.txt"),
        ("Avocado.png", "/path/Avocado.png"),
        ("Banana.doc", "/path/Banana.doc"),
        ("Book.pdf", "/path/Book.pdf"),
        ("Cat.mp4", "/path/Cat.mp4")
    ]

    func testInitialSingleCharacterMatch() {
        let (buf, match) = TypeToSelect.resolve(
            char: "b",
            currentBuffer: "",
            lastInputTime: 0,
            now: 10,
            candidates: candidates,
            currentSelectedPath: nil
        )
        XCTAssertEqual(buf, "b")
        XCTAssertEqual(match, "/path/Banana.doc")
    }

    func testPrefixAccumulationMatch() {
        // 先输入 'b' 命中 Banana
        let (buf1, match1) = TypeToSelect.resolve(
            char: "b",
            currentBuffer: "",
            lastInputTime: 0,
            now: 10,
            candidates: candidates,
            currentSelectedPath: nil
        )
        XCTAssertEqual(buf1, "b")
        XCTAssertEqual(match1, "/path/Banana.doc")

        // 0.2 秒后输入 'o'，累积为 "bo"，精准命中 Book.pdf
        let (buf2, match2) = TypeToSelect.resolve(
            char: "o",
            currentBuffer: buf1,
            lastInputTime: 10,
            now: 10.2,
            candidates: candidates,
            currentSelectedPath: match1
        )
        XCTAssertEqual(buf2, "bo")
        XCTAssertEqual(match2, "/path/Book.pdf")
    }

    func testSingleCharacterRepeatCycles() {
        // 第一次按 'a' 命中 Apple
        let (buf1, match1) = TypeToSelect.resolve(
            char: "a",
            currentBuffer: "",
            lastInputTime: 0,
            now: 10,
            candidates: candidates,
            currentSelectedPath: nil
        )
        XCTAssertEqual(buf1, "a")
        XCTAssertEqual(match1, "/path/Apple.txt")

        // 0.3 秒后再次按 'a'，单字循环跳到 Avocado
        let (buf2, match2) = TypeToSelect.resolve(
            char: "a",
            currentBuffer: buf1,
            lastInputTime: 10,
            now: 10.3,
            candidates: candidates,
            currentSelectedPath: match1
        )
        XCTAssertEqual(buf2, "a")
        XCTAssertEqual(match2, "/path/Avocado.png")

        // 再次按 'a'，循环回 Apple
        let (buf3, match3) = TypeToSelect.resolve(
            char: "a",
            currentBuffer: buf2,
            lastInputTime: 10.3,
            now: 10.5,
            candidates: candidates,
            currentSelectedPath: match2
        )
        XCTAssertEqual(buf3, "a")
        XCTAssertEqual(match3, "/path/Apple.txt")
    }

    func testTimeoutResetsBuffer() {
        // 先按 'a'
        let (buf1, _) = TypeToSelect.resolve(
            char: "a",
            currentBuffer: "",
            lastInputTime: 0,
            now: 10,
            candidates: candidates,
            currentSelectedPath: nil
        )
        XCTAssertEqual(buf1, "a")

        // 1.5 秒后（超过 0.85s 超时）按 'c'，缓冲区应重置为 'c'
        let (buf2, match2) = TypeToSelect.resolve(
            char: "c",
            currentBuffer: buf1,
            lastInputTime: 10,
            now: 11.5,
            candidates: candidates,
            currentSelectedPath: nil
        )
        XCTAssertEqual(buf2, "c")
        XCTAssertEqual(match2, "/path/Cat.mp4")
    }

    func testArrowNavigation() {
        // 初始未选中时按向下：选中第 0 项
        XCTAssertEqual(TypeToSelect.nextIndex(currentIndex: nil, direction: .down, count: 5), 0)
        // 初始未选中时按向上：选中最后 1 项
        XCTAssertEqual(TypeToSelect.nextIndex(currentIndex: nil, direction: .up, count: 5), 4)

        // 列表中向下
        XCTAssertEqual(TypeToSelect.nextIndex(currentIndex: 1, direction: .down, count: 5), 2)
        // 列表中向上
        XCTAssertEqual(TypeToSelect.nextIndex(currentIndex: 1, direction: .up, count: 5), 0)
        // 列表顶部再向上不越界
        XCTAssertEqual(TypeToSelect.nextIndex(currentIndex: 0, direction: .up, count: 5), 0)
        // 列表底部再向下不越界
        XCTAssertEqual(TypeToSelect.nextIndex(currentIndex: 4, direction: .down, count: 5), 4)

        // 网格 3 列：从 1 向下跨行到 4
        XCTAssertEqual(TypeToSelect.nextIndex(currentIndex: 1, direction: .down, count: 5, columns: 3), 4)
        // 网格 3 列：从 4 向上跨行到 1
        XCTAssertEqual(TypeToSelect.nextIndex(currentIndex: 4, direction: .up, count: 5, columns: 3), 1)
    }
}
