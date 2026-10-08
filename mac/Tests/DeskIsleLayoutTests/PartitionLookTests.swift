import XCTest
@testable import DeskIsleLayout

/// `PartitionLook` 是**三端共用的分区外观口径**（默认值 / 值域 / 模糊档位）。
///
/// 为什么把这些看起来「只是几个常数」的东西也钉上单测：
/// Electron 用 CSS `backdrop-filter` 能精确取像素值、Windows 是 Acrylic 按档位、
/// mac 是 SwiftUI Material 按档位 —— 三份实现**只能靠同一套阈值保持一致**。
/// 阈值一旦被某端悄悄调过，用户导入配置后会看到「同一个分区在两台机器上一个糊一个不糊」，
/// 而这类差异在代码 review 里几乎看不出来。这里把契约固化，改动即红。
final class PartitionLookTests: XCTestCase {

    // MARK: - 默认值（跨版本不能漂移）

    func testDefaultsAreHistoricalValues() {
        // 这三值是**历史观感**：改了等于让所有现存分区「升级后变样」，
        // 必须是有意识的决定 + 三端同步，不能顺手改。
        XCTAssertEqual(PartitionLook.defaultCornerRadius, 16, accuracy: 0.001)
        XCTAssertEqual(PartitionLook.defaultHeaderColor, "#38bdf8")
        XCTAssertEqual(PartitionLook.defaultBgColor, "#000000")
        // 缺省模糊落到 UltraThin（不是 none）：历史上一直有毛玻璃，缺省必须保持。
        XCTAssertEqual(PartitionLook.blurTier(for: PartitionLook.defaultBlurAmount), .ultraThin)
    }

    /// 正文色缺省必须是**空串**：空 = 跟随系统外观（深色/浅色都能读）。
    /// 一旦有人把这里改成具体颜色，浅色模式下的分区正文会变成白字看不见。
    func testDefaultContentTextMeansFollowSystem() {
        XCTAssertEqual(PartitionLook.defaultContentTextColor, "")
    }

    /// 背景不透明度的缺省不写死常量，而是跟随全局设置；这里只钉「全局也没有时」的兜底。
    func testFallbackBgOpacityMatchesGlobalDefault() {
        XCTAssertEqual(PartitionLook.fallbackBgOpacity, 0.10, accuracy: 0.0001)
    }

    // MARK: - 值域夹取

    func testClampsNegativeAndOverRangeValues() {
        XCTAssertEqual(PartitionLook.clamped(cornerRadius: -8), 0, accuracy: 0.001)
        XCTAssertEqual(PartitionLook.clamped(cornerRadius: 999), 32, accuracy: 0.001)
        XCTAssertEqual(PartitionLook.clamped(bgOpacity: -0.5), 0, accuracy: 0.0001)
        XCTAssertEqual(PartitionLook.clamped(bgOpacity: 3), 1, accuracy: 0.0001)
        XCTAssertEqual(PartitionLook.clamped(blur: -1), 0, accuracy: 0.001)
        XCTAssertEqual(PartitionLook.clamped(blur: 500), 40, accuracy: 0.001)
    }

    /// 范围内的值必须原样返回 —— 夹取不能「顺手」改掉用户的意图。
    func testClampKeepsInRangeValuesUntouched() {
        XCTAssertEqual(PartitionLook.clamped(cornerRadius: 7.5), 7.5, accuracy: 0.001)
        XCTAssertEqual(PartitionLook.clamped(bgOpacity: 0.42), 0.42, accuracy: 0.0001)
        XCTAssertEqual(PartitionLook.clamped(blur: 23), 23, accuracy: 0.001)
    }

    // MARK: - 模糊档位（三端必须同阈值的那张表）

    func testBlurTierThresholds() {
        XCTAssertEqual(PartitionLook.blurTier(for: 0), .none)
        XCTAssertEqual(PartitionLook.blurTier(for: 1), .ultraThin)
        XCTAssertEqual(PartitionLook.blurTier(for: 14.9), .ultraThin)
        XCTAssertEqual(PartitionLook.blurTier(for: 15), .thin)
        XCTAssertEqual(PartitionLook.blurTier(for: 29.9), .thin)
        XCTAssertEqual(PartitionLook.blurTier(for: 30), .regular)
        XCTAssertEqual(PartitionLook.blurTier(for: 40), .regular)
    }

    /// 越界输入先夹后分档：40 以上是 regular，**不能**因为输入非法就跳到 none。
    func testBlurTierClampsBeforeMapping() {
        XCTAssertEqual(PartitionLook.blurTier(for: 999), .regular)
        XCTAssertEqual(PartitionLook.blurTier(for: -5), .none)
    }

    /// 色板顺序不能变（UI 上是一排固定色块，换顺序会让用户手输的 hex 与记忆不一致）。
    func testPaletteIsStable() {
        XCTAssertEqual(PartitionLook.palette.count, 9)
        XCTAssertEqual(PartitionLook.palette.first, "#000000")
        XCTAssertEqual(PartitionLook.palette.last, "#f8fafc")
    }
}
