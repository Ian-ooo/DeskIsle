using System;
using System.Text.Json.Serialization;

namespace DeskIsle.Models
{
    /// <summary>
    /// ⭐ 分区级外观（`style` 字典）—— <b>三端共用同一组键与取值口径</b>
    /// （定义方：mac 的 <c>DeskIsleLayout/PartitionLook.swift</c>；Electron：<c>utils/partitionLook.ts</c>）。
    ///
    /// 六个键：<c>bgColor</c>(hex) / <c>bgOpacity</c>(0–1) / <c>borderRadius</c>(pt) /
    /// <c>blurAmount</c>(强度) / <c>headerColor</c>(hex) / <c>textColor</c>(hex)。
    ///
    /// <b>全部可为 null = 「跟随全局 / 跟随系统」</b>：
    /// - <c>bgOpacity</c> 为 null → 用 <see cref="Config.PartitionBgOpacity"/>（全局滑杆）
    /// - <c>textColor</c> 为 null 或空 → 跟随系统前景色
    ///
    /// 这是刻意的：<b>不写默认值进配置</b>。一旦写死，将来调整默认感知时，
    /// 老分区会被自己当年落盘的旧值钉住，永远升不了级。
    /// </summary>
    /// <remarks>
    /// ⚠️ <c>[JsonIgnore(WhenWritingNull)]</c> 是必须的：不加的话，
    /// 一个只改了圆角的分区会把另外五个键写成 <c>null</c> 落盘，
    /// 别的端读到 <c>"bgColor": null</c> 时行为不一致（mac 的字典取值会跳过，
    /// 但 JSON Schema 意义上这是个脏值）。这里选择「缺失即默认」而不是「写 null」。
    /// </remarks>
    public class PartitionStyle
    {
        [JsonPropertyName("bgColor")]
        [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
        public string? BgColor { get; set; }

        [JsonPropertyName("bgOpacity")]
        [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
        public double? BgOpacity { get; set; }

        [JsonPropertyName("borderRadius")]
        [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
        public double? BorderRadius { get; set; }

        [JsonPropertyName("blurAmount")]
        [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
        public double? BlurAmount { get; set; }

        [JsonPropertyName("headerColor")]
        [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
        public string? HeaderColor { get; set; }

        [JsonPropertyName("textColor")]
        [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
        public string? TextColor { get; set; }

        /// <summary>是否一个键都没写（= 完全跟随全局）。空字典不该被序列化出去。</summary>
        [JsonIgnore]
        public bool IsEmpty =>
            string.IsNullOrWhiteSpace(BgColor) &&
            string.IsNullOrWhiteSpace(HeaderColor) &&
            string.IsNullOrWhiteSpace(TextColor) &&
            BgOpacity is null && BorderRadius is null && BlurAmount is null;

        /// <summary>回到「跟随全局」—— 实例本身保留，但六个键全部清空。</summary>
        public void Reset()
        {
            BgColor = null;
            BgOpacity = null;
            BorderRadius = null;
            BlurAmount = null;
            HeaderColor = null;
            TextColor = null;
        }

        public PartitionStyle Clone() => new()
        {
            BgColor = BgColor,
            BgOpacity = BgOpacity,
            BorderRadius = BorderRadius,
            BlurAmount = BlurAmount,
            HeaderColor = HeaderColor,
            TextColor = TextColor
        };
    }
}
