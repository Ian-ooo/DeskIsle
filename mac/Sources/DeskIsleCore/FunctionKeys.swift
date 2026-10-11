import Foundation

/// **macOS 功能键（F1–F12）的键码表**，以及「是否算功能键」的判据。
///
/// ## 为什么要单独一个文件
///
/// 这张表以前散在两处、且**两处都写错了**，而它决定的是「用户能不能把 F1 设成快捷键」：
///
/// - `Shortcut.isFunctionKey` 曾写成 `(96...111).contains(code)`
/// - `FileOperations.fileKeyName` 曾把 `"f2"` 挂在 `case 96` 上
///
/// ## ⚠️⚠️ 功能键码**不是连续的**（这是本文件存在的全部理由）
///
/// 直觉上「F1 到 F12」应该是一个区间，于是就有人写了 `96...111`。但 Carbon `Events.h` 里：
///
/// ```text
/// kVK_F5  = 0x60 = 96     kVK_F4 = 0x76 = 118
/// kVK_F6  = 0x61 = 97     kVK_F2 = 0x78 = 120
/// kVK_F7  = 0x62 = 98     kVK_F1 = 0x7A = 122
/// kVK_F3  = 0x63 = 99   ← 注意：F3 插在 F7 和 F8 之间
/// kVK_F8  = 0x64 = 100
/// kVK_F9  = 0x65 = 101
/// kVK_F11 = 0x67 = 103
/// kVK_F13 = 0x69 = 105   ← F13+ 挤在 F12 之前
/// kVK_F16 = 0x6A = 106
/// kVK_F14 = 0x6B = 107
/// kVK_F10 = 0x6D = 109
/// kVK_F12 = 0x6F = 111
/// ```
///
/// 所以 `96...111` 实际覆盖的是 **F5 F6 F7 F3 F8 F9 F11 F13 F16 F14 F10 F12**：
/// **漏掉 F1 / F2 / F4，却放行了 F13 / F14 / F16**。后果有两面：
/// - 配置里写 `"F1"` 会因 `guard` 不通过而**静默丢弃**并退回默认键（用户看不出为什么没生效）
/// - 裸按 F13 反而被当成合法快捷键
///
/// ⇒ 因此这里**只用显式集合**，且由 `FunctionKeyTests` 锁住「F1–F12 全收、F13+ 全拒」。
///
/// ## 为什么不用 `import Carbon` 写 `kVK_F1`
///
/// `kVK_*` 是 Carbon（AppKit 时代）的常量，`DeskIsleCore` 必须保持**只依赖 Foundation**
/// 才能被测试 target 与跨端脚本复用。字面量本身不会变（macOS 20 年没动过这套键码），
/// 但**每个数字都必须注明它等于哪个 `kVK_*`**，便于日后核对。
public enum FunctionKeys {
    /// F1–F12 的键码集合。⚠️ 不要试图把它写成区间 —— 见文件头注释。
    public static let f1ToF12: Set<UInt32> = [
        96,   // kVK_F5  = 0x60
        97,   // kVK_F6  = 0x61
        98,   // kVK_F7  = 0x62
        99,   // kVK_F3  = 0x63
        100,  // kVK_F8  = 0x64
        101,  // kVK_F9  = 0x65
        103,  // kVK_F11 = 0x67
        109,  // kVK_F10 = 0x6D
        111,  // kVK_F12 = 0x6F
        118,  // kVK_F4  = 0x76
        120,  // kVK_F2  = 0x78
        122,  // kVK_F1  = 0x7A
    ]

    /// 「不带修饰键也允许单独按」的功能键判据（F1–F12）。
    ///
    /// ⚠️ **F13 及以上不算** —— 多数键盘没有物理 F13+， 放行它们只会让
    /// 误触变成一个查不到来源的怪快捷键。与 Electron `ShortcutRecorder` 的限制一致。
    public static func isFunctionKey(_ code: UInt32) -> Bool {
        f1ToF12.contains(code)
    }

    /// 按键码 → 规范名（`"F1"`…`"F12"`），非功能键返回 nil。
    ///
    /// ⚠️ 这里必须先解包 `ordinal` 再插值 —— 直接写 `"F\(ordinal(of: code))"`
    /// 会把可选值一并拼进去，产出 `"FOptional(1)"`（已踩过一次，由测试抓出）。
    public static func name(for code: UInt32) -> String? {
        guard let n = ordinal(of: code) else { return nil }
        return "F\(n)"
    }

    /// 规范名（不区分大小写）→ 键码。`"f2"` / `"F2"` 都认。
    public static func code(for name: String) -> UInt32? {
        let n = name.uppercased()
        guard n.hasPrefix("F"), let num = Int(n.dropFirst()), (1...12).contains(num) else { return nil }
        return code(of: num)
    }

    /// 第几个功能键（F1 → 1 … F12 → 12）。非功能键返回 nil。
    public static func ordinal(of code: UInt32) -> Int? {
        // 键码无规律，只能查表 —— 这也是不能用区间的原因。
        let ordered: [(UInt32, Int)] = [
            (122, 1), (120, 2), (99, 3), (118, 4), (96, 5), (97, 6),
            (98, 7), (100, 8), (101, 9), (109, 10), (103, 11), (111, 12),
        ]
        return ordered.first { $0.0 == code }?.1
    }

    /// 第 n 个功能键（F1 → 1）的键码。越界返回 nil。
    public static func code(of n: Int) -> UInt32? {
        switch n {
        case 1: return 122   // kVK_F1
        case 2: return 120   // kVK_F2
        case 3: return 99    // kVK_F3
        case 4: return 118   // kVK_F4
        case 5: return 96    // kVK_F5
        case 6: return 97    // kVK_F6
        case 7: return 98    // kVK_F7
        case 8: return 100   // kVK_F8
        case 9: return 101   // kVK_F9
        case 10: return 109  // kVK_F10
        case 11: return 103  // kVK_F11
        case 12: return 111  // kVK_F12
        default: return nil
        }
    }
}