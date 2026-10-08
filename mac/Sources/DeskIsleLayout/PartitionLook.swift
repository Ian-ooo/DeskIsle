import Foundation

/// ⭐ **分区级外观口径（mac 基线定义；Electron / Windows 现有实现必须与本文件同值）**
///
/// 六个键写在每个分区的 `style` 字典里（三端键名一致，见两端各自的 styleKeys 常量）：
/// `bgColor`(hex) / `bgOpacity`(0–1) / `borderRadius`(pt) / `blurAmount`(强度) /
/// `headerColor`(hex) / `textColor`(hex)。
///
/// **「缺省即跟随全局」是这套设计的核心**：不写某个键 = 用默认值，因此
/// ① 老配置不会因为升级而变样；② 别的端导出的配置也能正常渲染；
/// ③ 用户按「恢复默认外观」时只需删掉整段 `style`。
///
/// ⚠️ **模糊在三端是三种不同技术**，不可能像素级一致：
/// - mac：SwiftUI `Material` 系统材质 —— **没有连续半径**，只能按档位取（`BlurTier`）
/// - Windows：Acrylic 合成笔刷（同样按档位，见 `Views/PartitionWindow.xaml.cs`）
/// - Electron：CSS `backdrop-filter: blur(Npx)` —— 唯一能取连续像素值的一端
///
/// 所以 `blurAmount` 存的是「视觉强度」而不是像素，各端按自己的档位表解释。
/// 改动这里的任何默认值 / 范围时，**三端必须一起改**（别忘了同步对拍脚本里的常量）。
public enum PartitionLook {
    /// 缺省圆角（= 历史固定值 16pt，保证老分区外观完全不变）。
    public static let defaultCornerRadius: CGFloat = 16
    public static let cornerRadiusRange: ClosedRange<CGFloat> = 0...32

    /// 缺省背景色（黑）：历史上就是用黑遮罩叠毛玻璃。
    public static let defaultBgColor = "#000000"
    /// 背景不透明度的**缺省值不写死**：跟随全局 `settings.partitionBgOpacity`。
    /// 全局滑杆仍是「一次改全部」的入口，per-partition 值只是在某个分区上覆盖它。
    public static let bgOpacityRange: ClosedRange<Double> = 0...1
    /// 全局缺失时的**兜底**（与 `Config.partitionBgOpacity` 的历史缺省一致）。
    public static let fallbackBgOpacity: Double = 0.10

    /// 缺省模糊强度（落到 UltraThin 档）。
    public static let defaultBlurAmount: CGFloat = 12
    public static let blurRange: ClosedRange<CGFloat> = 0...40

    /// 缺省标题色。
    public static let defaultHeaderColor = "#38bdf8"
    /// 缺省正文色：**空串 = 跟随系统**（深色 / 浅色外观都能读）——不写死颜色是刻意的。
    public static let defaultContentTextColor = ""
    /// 正文色 UI 上给笔画不了的预览用的占位色（不是默认值，别混淆）。
    public static let contentTextPreviewColor = "#ffffff"

    /// 常用色板（hex，三端顺序一致）。
    public static let palette: [String] = [
        "#000000", "#1e293b", "#0f766e", "#2563eb",
        "#7c3aed", "#be123c", "#ea580c", "#facc15",
        "#f8fafc"
    ]

    // MARK: - 值域夹取

    /// UI 滑杆 / 手输会给来任何东西 —— 负圆角会让 `RoundedRectangle` 画出自交图形，
    /// 负透明度会直接把背景涂成反色，所以这里一律夹紧（**不丢弃**，保留用户意图的最近值）。
    public static func clamped(cornerRadius v: CGFloat) -> CGFloat {
        min(max(v, cornerRadiusRange.lowerBound), cornerRadiusRange.upperBound)
    }
    public static func clamped(bgOpacity v: Double) -> Double {
        min(max(v, bgOpacityRange.lowerBound), bgOpacityRange.upperBound)
    }
    public static func clamped(blur v: CGFloat) -> CGFloat {
        min(max(v, blurRange.lowerBound), blurRange.upperBound)
    }

    // MARK: - 模糊档位

    /// 材质档位。抽成 enum 而不是在 SwiftUI 视图里写 if —— 这样「强度 → 档位」的映射可被单测锁住，
    /// 且 Windows / Electron 能用同一套阈值描述自己的实现。
    public enum BlurTier: Int, CaseIterable {
        /// 不要毛玻璃：纯色背景（用户想要完全不透明的卡片时用）。
        case none = 0
        case ultraThin
        case thin
        case regular
    }

    /// 强度 → 档位。**阈值必须与 Electron / Windows 的实现一致**（否则同一份配置跨端观感不同）。
    ///
    /// 0 独占一档（- none）是因为「完全不要模糊」是个明确意图，
    /// 不该因为滑杆从 0 拖到 2 就突然从无到有地跳一下。
    public static func blurTier(for amount: CGFloat) -> BlurTier {
        switch clamped(blur: amount) {
        case 0: return .none
        case ..<15: return .ultraThin
        case ..<30: return .thin
        default: return .regular
        }
    }
}
