import XCTest
@testable import DeskIsleCore

/// `FunctionKeys` 的回归测试。
///
/// ## 这组测试存在的理由
///
/// 功能键码**不是连续的**（F3 插在 F7/F8 之间，F1/F2/F4 远在 118 以上），
/// 因此「F1–F12 = 96...111」这种直觉写法是错的，而且它**错得很隐蔽**：
/// 看不出异常、用户只会觉得「我设的 F1 没生效」。
///
/// 历史上本项目真的踩过两次：
/// 1. `Shortcut.isFunctionKey` 写成区间 ⇒ 配置里的 `"F1"` 被 `guard` 静默丢弃
/// 2. `FileOperations.fileKeyName` 把 `"f2"` 挂在 `case 96` ⇒ 按 F5 才触发重命名
///
/// 所以下面几条断言锁的是**键码本身**，不是实现细节。
final class FunctionKeysTests: XCTestCase {

    /// 全部 12 个键码与 Carbon `kVK_F*` 逐字对齐。
    ///
    /// 核对来源：Xcode SDK 的
    /// `System/Library/Frameworks/Carbon.framework/Frameworks/HIToolbox.framework/Headers/Events.h`
    func testEveryCodeMatchesCarbonConstant() {
        let expected: [(UInt32, Int, String)] = [
            (122, 1, "kVK_F1  = 0x7A"),
            (120, 2, "kVK_F2  = 0x78"),
            (99,  3, "kVK_F3  = 0x63"),
            (118, 4, "kVK_F4  = 0x76"),
            (96,  5, "kVK_F5  = 0x60"),
            (97,  6, "kVK_F6  = 0x61"),
            (98,  7, "kVK_F7  = 0x62"),
            (100, 8, "kVK_F8  = 0x64"),
            (101, 9, "kVK_F9  = 0x65"),
            (109, 10, "kVK_F10 = 0x6D"),
            (103, 11, "kVK_F11 = 0x67"),
            (111, 12, "kVK_F12 = 0x6F"),
        ]
        for (code, ordinal, origin) in expected {
            XCTAssertEqual(FunctionKeys.code(of: ordinal), code,
                           "第 \(ordinal) 个功能键的键码与 \(origin) 不符")
            XCTAssertEqual(FunctionKeys.ordinal(of: code), ordinal, "\(origin) 的序号不对")
        }
        XCTAssertEqual(FunctionKeys.f1ToF12.count, 12, "功能键必须是 12 个，不能多也不能少")
    }

    /// ⚠️ 本组测试的核心：F1–F12 **全部**必须被认成功能键。
    ///
    /// 旧的区间写法会漏掉 F1(122) / F2(120) / F4(118) —— 它们是历史上真实丢失的三个。
    func testAllTwelveFunctionKeysAreAccepted() {
        for n in 1...12 {
            let code = FunctionKeys.code(of: n)!
            XCTAssertTrue(FunctionKeys.isFunctionKey(code), "F\(n)（键码 \(code)）应被认成功能键")
            XCTAssertEqual(FunctionKeys.name(for: code), "F\(n)")
        }
    }

    /// 反向：F13 及以上**不得**放行。
    ///
    /// 旧区间 `96...111` 恰好覆盖了 kVK_F13(105) / F16(106) / F14(107) —— 必须拒绝。
    func testF13AndAboveAreRejected() {
        for code: UInt32 in [104, 105, 106, 107, 113] {   // F15=0x71=113，其余为 F13/F16/F14
            XCTAssertFalse(FunctionKeys.isFunctionKey(code),
                           "键码 \(code)（F13 以上）不该被当成 F1–F12")
            XCTAssertNil(FunctionKeys.name(for: code))
        }
    }

    /// 普通键绝不能被误认成功能键（否则裸按字母键就能当快捷键，会疯狂误触）。
    func testOrdinaryKeysAreNotFunctionKeys() {
        // A=0x00, S=0x01, D=0x02… 数字 1=0x12, 空格=0x31, ⌫=0x33, 方向键 0x7B~0x7E
        for code: UInt32 in [0, 1, 2, 12, 18, 36, 49, 51, 53, 123, 124, 125, 126] {
            XCTAssertFalse(FunctionKeys.isFunctionKey(code), "键码 \(code) 不是功能键")
        }
    }

    /// 名称解析双向可用，且大小写不敏感。
    func testNameRoundTrip() {
        for n in 1...12 {
            let code = FunctionKeys.code(of: n)!
            XCTAssertEqual(FunctionKeys.code(for: "F\(n)"), code)
            XCTAssertEqual(FunctionKeys.code(for: "f\(n)"), code, "应大小写不敏感")
            XCTAssertEqual(FunctionKeys.name(for: code), "F\(n)")
        }
        // 越界与垃圾输入
        XCTAssertNil(FunctionKeys.code(of: 0))
        XCTAssertNil(FunctionKeys.code(of: 13))
        XCTAssertNil(FunctionKeys.code(for: "F13"))
        XCTAssertNil(FunctionKeys.code(for: "F0"))
        XCTAssertNil(FunctionKeys.code(for: "FF"))
        XCTAssertNil(FunctionKeys.code(for: ""))
        XCTAssertNil(FunctionKeys.code(for: "A"))
    }

    /// ⚠️ 专门锁住历史上那两个 bug 的**症状**（而不只是键码表本身）。
    func testHistoricalBugsStayFixed() {
        // bug 1：F1 被区间漏掉 → 配置里写 "F1" 会被静默丢弃
        XCTAssertTrue(FunctionKeys.isFunctionKey(122), "F1 曾因区间写法被漏掉")
        XCTAssertEqual(FunctionKeys.code(for: "F1"), 122)

        // bug 2："f2" 曾挂在 case 96（那是 kVK_F5）→ 按 F5 才触发重命名
        XCTAssertEqual(FunctionKeys.code(for: "F2"), 120, "F2 是 0x78=120，不是 96")
        XCTAssertNotEqual(FunctionKeys.code(of: 2), 96, "F2 的键码不可能是 F5 的 96")
        XCTAssertEqual(FunctionKeys.code(of: 5), 96, "96 属于 F5")
    }
}