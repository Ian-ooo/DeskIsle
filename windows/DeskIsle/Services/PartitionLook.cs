using System;

namespace DeskIsle.Services
{
    /// <summary>
    /// ⭐ 分区级外观口径 —— <b>镜像 mac 的 <c>DeskIsleLayout/PartitionLook.swift</c></b>，
    /// 数值与阈值必须逐项一致（改一处记得同步：Electron <c>utils/partitionLook.ts</c>、
    /// <c>scripts/crosscheck</c> 里的常量断言）。
    ///
    /// 为什么连默认值都要单独开个：WPF 里很容易出现「窗口 XAML 里写 8、代码里又写 16」
    /// 这种两个默认打架的情况，最后用户看到的是「改了设置没变化」。这里指定唯一来源。
    /// </summary>
    public static class PartitionLook
    {
        // ── 默认值 ─────────────────────────────────────────────
        // ⚠️ 这组值是**历史观感**：改了等于让所有现存分区「升级后变样」，必须是刻意的决定。

        /// <summary>缺省背景色（黑）：历史上分区卡片就是黑底 + 毛玻璃。</summary>
        public const string DefaultBgColor = "#000000";

        /// <summary>
        /// 背景不透明度的缺省 = 跟随全局设置（<see cref="Config.PartitionBgOpacity"/>）。
        /// 这里只留「全局也没有」时的兜底。
        /// </summary>
        public const double FallbackBgOpacity = 0.10;

        /// <summary>缺省标题色（与 mac / Electron 同色）。</summary>
        public const string DefaultHeaderColor = "#38bdf8";

        /// <summary>
        /// 缺省正文色 = <b>空串</b> → 跟随系统前景色。
        /// 一旦写死白色，浅色主题下的分区正文会看不见。
        /// </summary>
        public const string DefaultContentTextColor = "";

        /// <summary>
        /// 缺省圆角。
        /// ⚠️ 注意 Windows 端的<b>历史卡片圆角是 8</b>（<c>CardBackgroundBrush</c> 那枚 Border），
        /// 而 mac 是 16 —— 两端视觉上从来就不同。这里<b>按 mac 基线统一为 16</b>：
        /// 跨端导入配置时圆角应当一致，而 16 也确实是 Windows 11 卡片的主流观感。
        /// 不要再回到 8 —— 分区卡片是全屏悬浮元素，圆角太小会显得「贴」在桌面上。
        /// </summary>
        public const double DefaultCornerRadius = 16;

        /// <summary>缺省模糊强度（→ UltraThin 档：历史上 Windows 端开着 Acrylic）。</summary>
        public const double DefaultBlurAmount = 12;

        // ── 值域 ───────────────────────────────────────────────
        public static readonly (double Min, double Max) CornerRadiusRange = (0, 32);
        public static readonly (double Min, double Max) BgOpacityRange = (0, 1);
        public static readonly (double Min, double Max) BlurRange = (0, 40);

        /// <summary>常用色板（hex，顺序与 mac / Electron 一致 —— UI 上是一排固定色块）。</summary>
        public static readonly string[] Palette =
        {
            "#000000", "#1e293b", "#0f766e", "#2563eb",
            "#7c3aed", "#be123c", "#ea580c", "#facc15",
            "#f8fafc"
        };

        // ── 夹取 ───────────────────────────────────────────────

        /// <summary>
        /// 负圆角会让 <c>CornerRadius</c> 抛异常（WPF 要求 ≥ 0），负透明度直接报错，
        /// 所以 UI 与导入配置来的一切数值都要先过这里。
        /// </summary>
        public static double Clamp(double value, double min, double max)
            => value < min ? min : (value > max ? max : value);

        public static double ClampCornerRadius(double v) => Clamp(v, CornerRadiusRange.Min, CornerRadiusRange.Max);
        public static double ClampBgOpacity(double v) => Clamp(v, BgOpacityRange.Min, BgOpacityRange.Max);
        public static double ClampBlur(double v) => Clamp(v, BlurRange.Min, BlurRange.Max);

        // ── 模糊档位 ────────────────────────────────────────────

        /// <summary>
        /// 模糊档位（与 mac 的 <c>PartitionLook.BlurTier</c> 同名同阈值）。
        /// </summary>
        public enum BlurTier
        {
            /// <summary>不要背景模糊（纯色卡片）。</summary>
            None = 0,

            /// <summary>极薄。</summary>
            UltraThin,

            /// <summary>薄。</summary>
            Thin,

            /// <summary>常规。</summary>
            Regular
        }

        /// <summary>强度 → 档位。阈值必须与 mac / Electron 完全一致。</summary>
        public static BlurTier TierFor(double amount)
        {
            double v = ClampBlur(amount);
            if (v <= 0) return BlurTier.None;
            if (v < 15) return BlurTier.UltraThin;
            if (v < 30) return BlurTier.Thin;
            return BlurTier.Regular;
        }

        // ⚠️ 「档位 → DWM 背景类型」的映射**刻意不放在这里**：它依赖 `Native.Win32`，
        // 而本文件要能被 `net8.0` 的测试工程链接编译（见 tests/DeskIsle.Tests.csproj）。
        // 映射在 `Views/PartitionWindow.xaml.cs` 的 `BackdropFor(...)`。
    }
}
