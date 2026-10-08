using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace DeskIsle.Models
{
    public class PartitionModel
    {
        [JsonPropertyName("id")]
        public string Id { get; set; } = Guid.NewGuid().ToString();

        [JsonPropertyName("type")]
        public string Type { get; set; } = "portal"; // portal, notes, todo

        [JsonPropertyName("title")]
        public string Title { get; set; } = string.Empty;

        /// <summary>
        /// 分区所属显示器标识（<see cref="System.Windows.Forms.Screen.DeviceName"/>，如 \\.\DISPLAY1）。
        /// 用于重启后把分区归到正确的显示器分组（按屏对齐 / 按屏显隐）。
        /// 为空表示未知（旧配置），回退到「窗口当前所在显示器」运行时判定。
        /// </summary>
        /// <remarks>
        /// 用 <see cref="FlexibleStringConverter"/> 读取：mac 写的是数字（显示器 ID），
        /// Windows 写的是 <c>\.\DISPLAY1</c>。不加转换器时数字会让整份配置反序列化失败。
        /// </remarks>
        [JsonPropertyName("screenId")]
        [JsonConverter(typeof(FlexibleStringConverter))]
        public string? ScreenId { get; set; }

        [JsonPropertyName("x")]
        public double X { get; set; }

        [JsonPropertyName("y")]
        public double Y { get; set; }

        [JsonPropertyName("width")]
        public double Width { get; set; } = 280;

        [JsonPropertyName("height")]
        public double Height { get; set; } = 200;

        [JsonPropertyName("isCollapsed")]
        public bool IsCollapsed { get; set; }

        [JsonPropertyName("isLocked")]
        public bool IsLocked { get; set; }

        [JsonPropertyName("isAlwaysOnTop")]
        public bool IsAlwaysOnTop { get; set; }

        [JsonPropertyName("viewMode")]
        public string ViewMode { get; set; } = "grid"; // grid, list

        [JsonPropertyName("sortBy")]
        public string SortBy { get; set; } = "name"; // name, time, size, type

        [JsonPropertyName("sortOrder")]
        public string SortOrder { get; set; } = "asc"; // asc, desc

        [JsonPropertyName("folderPath")]
        public string? FolderPath { get; set; }

        /// <summary>当前子目录浏览路径（会话持久化，重启后恢复浏览深度）。</summary>
        [JsonPropertyName("currentSubPath")]
        public string? CurrentSubPath { get; set; }

        [JsonPropertyName("noteContent")]
        public string? NoteContent { get; set; }

        [JsonPropertyName("todos")]
        public List<TodoItem> Todos { get; set; } = new();

        [JsonPropertyName("isCompletedCollapsed")]
        public bool IsCompletedCollapsed { get; set; } = true;

        [JsonPropertyName("todoFilterMode")]
        public string TodoFilterMode { get; set; } = "all";

        /// <summary>
        /// 分区级外观（背景色 / 不透明度 / 圆角 / 模糊 / 标题色 / 正文色）。
        /// 三端同一组键，缺省即跟随全局 —— 见 <see cref="PartitionStyle"/> 的说明。
        /// </summary>
        [JsonPropertyName("style")]
        public PartitionStyle? Style { get; set; }

        /// <summary>
        /// 拿一个**可写**的 style 实例（没有就新建一个）。
        /// 面板里到处直接写 `p.Style = ...` 很容易漏判 null，统一走这里。
        /// </summary>
        [JsonIgnore]
        public PartitionStyle EditableStyle => Style ??= new PartitionStyle();

        [JsonExtensionData]
        public Dictionary<string, JsonElement>? ExtraData { get; set; }
    }
}
