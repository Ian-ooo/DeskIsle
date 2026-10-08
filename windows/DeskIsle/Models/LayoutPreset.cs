using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace DeskIsle.Models
{
    /// <summary>
    /// 布局预设里的单个分区条目。
    ///
    /// 按**分区 id** 记录 —— id 稳定不变（重命名、换映射目录都不改），
    /// 比「第 N 个分区」可靠：后者在中间插入或删除一个分区就会整体错位。
    ///
    /// JSON 键名（<c>id</c> / <c>x</c> / <c>y</c> / <c>width</c> / <c>height</c>）
    /// 由 <see cref="LayoutPresetConverter"/> 统一处理，这里不再挂 <c>[JsonPropertyName]</c>
    /// —— 挂了也不生效（转换器会接管整个对象的读写），留着只会让人以为那是真相。
    /// </summary>
    public class LayoutPresetEntry
    {
        public string Id { get; set; } = string.Empty;
        public double X { get; set; }
        public double Y { get; set; }
        public double Width { get; set; }
        public double Height { get; set; }
    }

    /// <summary>
    /// 布局预设：某块屏上所有分区的位置与尺寸，连同该屏的对齐模式，存成一条命名快照。
    ///
    /// **按屏保存**：坐标是屏幕相对的，跨屏套用会把分区搬到不相干的显示器上，
    /// 因此 <see cref="ScreenId"/> 是预设的一部分。
    /// </summary>
    /// <remarks>
    /// 读写走 <see cref="LayoutPresetConverter"/>：它负责抹平三端差异 ——
    /// 时间戳认 mac 的 <c>savedAt</c>（秒）与本端的 <c>createdAt</c>（毫秒），
    /// <c>screenId</c> 认数字（mac）与字符串（Windows / Electron）。
    /// 写出去一律是规范形状：<c>savedAt</c>（秒）+ 字符串 <c>screenId</c>。
    /// </remarks>
    [JsonConverter(typeof(LayoutPresetConverter))]
    public class LayoutPreset
    {
        public string Name { get; set; } = string.Empty;

        /// <summary>所属显示器的 <see cref="System.Windows.Forms.Screen.DeviceName"/></summary>
        public string ScreenId { get; set; } = string.Empty;

        public string AlignMode { get; set; } = "top";

        /// <summary>
        /// 保存时间，**毫秒**（Unix epoch）。
        ///
        /// 内存里统一用毫秒（Windows 原生精度），只在**序列化那一刻**折算成
        /// mac 的秒制写进文件 —— 折算点集中在一处，就不会出现「某一处忘了 /1000」。
        /// </summary>
        public long SavedAtMs { get; set; }

        public List<LayoutPresetEntry> Entries { get; set; } = new();
    }
}
