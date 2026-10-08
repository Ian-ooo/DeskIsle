using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace DeskIsle.Models
{
    /// <summary>
    /// 配置兼容层：让 Windows 端能容忍 **mac / Electron 写出来的字段形状**。
    ///
    /// 背景（2026-09-28 实测）：三端共用同一份 JSON 结构，但同一个字段的类型并不一致。
    /// 最典型的是分区的 <c>files</c>：
    /// - mac / Electron 写的是**对象数组** `[{ id, name, path, isDir, ... }]`；
    /// - Windows 一直是**纯路径数组** `["C:\\a.txt", "D:\\b.pdf"]`。
    ///
    /// 用 <c>List&lt;string&gt;</c> 去反序列化对象数组会**直接抛 JsonException**。
    /// 而这条异常会顺着 <see cref="Config.Load"/> 冒上去，让整份配置读取失败 ——
    /// 更糟的是（修复前）此时 <c>Raw</c> 已换成新内容、<c>Partitions</c> 却还是空表，
    /// 之后任何一次 <c>Save()</c> 都会把这张空表写回磁盘，**用户的分区就凭空消失了**。
    ///
    /// 因此本文件的策略是：
    /// **读的时候尽量宽容（永不抛异常），写的时候只写自己的规范形状。**
    /// 这样既不会因为别人的字段形状炸掉，也不会把自己的写法搞得四不像。
    /// </summary>
    public static class JsonCompat
    {
        /// <summary>
        /// 从一个「条目」里取路径：字符串条目直接用；对象条目优先取 <c>path</c>，
        /// 没有 <c>path</c> 时退回 <c>name</c>（有些历史版本只存了文件名）。
        /// </summary>
        public static string? PathOf(JsonElement element)
        {
            switch (element.ValueKind)
            {
                case JsonValueKind.String:
                    return element.GetString();

                case JsonValueKind.Object:
                    if (element.TryGetProperty("path", out var p) && p.ValueKind == JsonValueKind.String)
                    {
                        var s = p.GetString();
                        if (!string.IsNullOrEmpty(s)) return s;
                    }
                    if (element.TryGetProperty("name", out var n) && n.ValueKind == JsonValueKind.String)
                    {
                        var s = n.GetString();
                        if (!string.IsNullOrEmpty(s)) return s;
                    }
                    return null;

                default:
                    return null;
            }
        }

        // ── 通用取值助手（形状无关，永不抛异常）────────────────────────────
        //
        // 手改配置、跨端互导、以及「另一个版本刚写下的文件」都会带来
        // 「键名对不上 / 类型对不上」这两类问题。转换器里如果直接 GetProperty +
        // GetString，一个类型不符就抛 JsonException，整份配置读取失败 ——
        // 代价远大于「这一个字段取默认值」。所以统一走下面这几个 helper。

        /// <summary>取字符串字段；数字 / 布尔也转成字符串；取不到返回 null。</summary>
        public static string? Str(JsonElement obj, string name)
        {
            if (obj.ValueKind != JsonValueKind.Object) return null;
            if (!obj.TryGetProperty(name, out var v)) return null;
            return v.ValueKind switch
            {
                JsonValueKind.String => v.GetString(),
                JsonValueKind.Number => v.ToString(),
                JsonValueKind.True => "true",
                JsonValueKind.False => "false",
                _ => null
            };
        }

        /// <summary>依次尝试多个键名，返回第一个非空字符串（**靠前的键优先**）。</summary>
        public static string? FirstStr(JsonElement obj, params string[] names)
        {
            foreach (var n in names)
            {
                var s = Str(obj, n);
                if (!string.IsNullOrEmpty(s)) return s;
            }
            return null;
        }

        /// <summary>取数值字段；字符串形式的数字也认；取不到返回 0。</summary>
        public static double Num(JsonElement obj, string name)
        {
            if (obj.ValueKind != JsonValueKind.Object) return 0;
            if (!obj.TryGetProperty(name, out var v)) return 0;
            if (v.ValueKind == JsonValueKind.Number && v.TryGetDouble(out var d)) return d;
            if (v.ValueKind == JsonValueKind.String &&
                double.TryParse(v.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var p))
            {
                return p;
            }
            return 0;
        }

        /// <summary>取布尔字段；数字 / 字符串形式也认；取不到返回 null（**区分「没写」与「写了 false」**）。</summary>
        public static bool? Bool(JsonElement obj, string name)
        {
            if (obj.ValueKind != JsonValueKind.Object) return null;
            if (!obj.TryGetProperty(name, out var v)) return null;
            return v.ValueKind switch
            {
                JsonValueKind.True => true,
                JsonValueKind.False => false,
                // 显式转成 bool? ：否则 `cond ? bool : null` 这种分支在 switch 表达式里
                // 要靠目标类型推断才成立，写明确一点省得依赖语言版本细节。
                JsonValueKind.Number => v.TryGetInt32(out var i) ? (bool?)(i != 0) : null,
                JsonValueKind.String => bool.TryParse(v.GetString(), out var b) ? (bool?)b : null,
                _ => (bool?)null
            };
        }

        /// <summary>依次尝试多个键名，返回第一个能读成布尔的。</summary>
        public static bool? FirstBool(JsonElement obj, params string[] names)
        {
            foreach (var n in names)
            {
                var b = Bool(obj, n);
                if (b.HasValue) return b;
            }
            return null;
        }

        /// <summary>取整数字段；浮点 / 字符串形式也认（截断取整）；取不到返回 null。</summary>
        public static int? Int(JsonElement obj, string name)
        {
            if (obj.ValueKind != JsonValueKind.Object) return null;
            if (!obj.TryGetProperty(name, out var v)) return null;
            if (v.ValueKind == JsonValueKind.Number)
            {
                if (v.TryGetInt32(out var i)) return i;
                if (v.TryGetDouble(out var d)) return (int)d;
            }
            if (v.ValueKind == JsonValueKind.String &&
                double.TryParse(v.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var p))
            {
                return (int)p;
            }
            return null;
        }

        /// <summary>依次尝试多个键名，返回第一个能读成整数的。</summary>
        public static int? FirstInt(JsonElement obj, params string[] names)
        {
            foreach (var n in names)
            {
                var i = Int(obj, n);
                if (i.HasValue) return i;
            }
            return null;
        }

        /// <summary>
        /// 屏标识：**数字与字符串都读成字符串**。
        /// mac 写数字（<c>CGDirectDisplayID</c>），Windows 写设备名，Electron 恒写 <c>"primary"</c>。
        /// </summary>
        public static string ScreenIdText(JsonElement obj)
        {
            if (obj.ValueKind != JsonValueKind.Object) return string.Empty;
            if (!obj.TryGetProperty("screenId", out var v)) return string.Empty;
            return v.ValueKind switch
            {
                JsonValueKind.String => v.GetString() ?? string.Empty,
                JsonValueKind.Number => v.ToString(),
                _ => string.Empty
            };
        }

        /// <summary>
        /// 布局预设的保存时间 → **毫秒**。
        ///
        /// 规范键是 mac 的 <c>savedAt</c>，存的是**秒**（浮点）；
        /// Windows / Electron 历史上用 <c>createdAt</c>，存的是**毫秒**。
        /// 不折算的话时间戳会差 1000 倍（跑到 1970 年或 5 万年以后），预设排序彻底错乱。
        /// </summary>
        public static long TimestampMs(JsonElement obj)
        {
            if (obj.ValueKind != JsonValueKind.Object) return 0;
            if (obj.TryGetProperty("savedAt", out var s) &&
                s.ValueKind == JsonValueKind.Number && s.TryGetDouble(out var sec))
            {
                return (long)Math.Round(sec * 1000.0);
            }
            if (obj.TryGetProperty("createdAt", out var c) &&
                c.ValueKind == JsonValueKind.Number && c.TryGetDouble(out var ms))
            {
                return (long)Math.Round(ms);
            }
            return 0;
        }
    }

    /// <summary>
    /// 「可能是数字、也可能是字符串」的字段读成字符串。
    ///
    /// 典型是分区的 <c>screenId</c>：
    /// - mac 写的是 <c>Int</c>（<c>CGDirectDisplayID</c>，如 69734406）；
    /// - Windows 写的是设备名字符串（<c>\.\DISPLAY1</c>）；
    /// - Electron 恒写 <c>"primary"</c>。
    ///
    /// 三种取值本来就**互不通用**（换端后都对不上自己的显示器），
    /// 所以这里只负责「读到什么算什么、读不出来给 null」，
    /// 由上层回退到「窗口当前所在显示器」的运行时判定 —— 绝不能因为类型不同就抛异常。
    /// </summary>
    public sealed class FlexibleStringConverter : JsonConverter<string>
    {
        public override string? Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
        {
            switch (reader.TokenType)
            {
                case JsonTokenType.String:
                    return reader.GetString();

                case JsonTokenType.Number:
                    if (reader.TryGetInt64(out var l)) return l.ToString(CultureInfo.InvariantCulture);
                    if (reader.TryGetDouble(out var d)) return d.ToString(CultureInfo.InvariantCulture);
                    return null;

                case JsonTokenType.Null:
                    return null;

                default:
                    // 意料之外的形状（对象 / 数组）也整段吃掉，别把它留给后面的解析器
                    JsonDocument.ParseValue(ref reader).Dispose();
                    return null;
            }
        }

        public override void Write(Utf8JsonWriter writer, string value, JsonSerializerOptions options)
        {
            if (value is null) writer.WriteNullValue();
            else writer.WriteStringValue(value);
        }
    }

    /// <summary>
    /// 布局预设的读写转换器 —— 统一三端在「时间戳键名」与「屏标识类型」上的差异。
    ///
    /// 读：时间戳认 <c>savedAt</c>（秒）与 <c>createdAt</c>（毫秒）两种；
    /// <c>screenId</c> 认数字（mac）与字符串（Windows / Electron）两种 ——
    /// 后者尤其重要：不加转换器时，mac 写下的**数字** screenId 会让
    /// <c>List&lt;LayoutPreset&gt;</c> 反序列化整个抛异常，表现为「导入 mac 配置后预设全没了」。
    ///
    /// 写：时间戳统一写 mac 的规范键 <c>savedAt</c>（**秒**，浮点），
    /// 屏标识写回字符串（Windows 的设备名）。mac 读到认不出的屏会**整条忽略** ——
    /// 这是有意为之：entries 是**屏内坐标**，套到另一块屏上只会跑到屏幕外。
    /// </summary>
    public sealed class LayoutPresetConverter : JsonConverter<LayoutPreset>
    {
        public override LayoutPreset Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
        {
            var preset = new LayoutPreset();

            using var doc = JsonDocument.ParseValue(ref reader);
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return preset;

            preset.Name = JsonCompat.Str(root, "name") ?? string.Empty;
            preset.ScreenId = JsonCompat.ScreenIdText(root);
            preset.AlignMode = JsonCompat.Str(root, "alignMode") ?? "top";
            preset.SavedAtMs = JsonCompat.TimestampMs(root);

            if (root.TryGetProperty("entries", out var arr) && arr.ValueKind == JsonValueKind.Array)
            {
                foreach (var e in arr.EnumerateArray())
                {
                    var id = JsonCompat.Str(e, "id");
                    if (string.IsNullOrEmpty(id)) continue;    // 坏条目只丢自己，不炸整个预设
                    preset.Entries.Add(new LayoutPresetEntry
                    {
                        Id = id!,
                        X = JsonCompat.Num(e, "x"),
                        Y = JsonCompat.Num(e, "y"),
                        Width = JsonCompat.Num(e, "width"),
                        Height = JsonCompat.Num(e, "height")
                    });
                }
            }

            return preset;
        }

        public override void Write(Utf8JsonWriter writer, LayoutPreset value, JsonSerializerOptions options)
        {
            writer.WriteStartObject();
            writer.WriteString("name", value.Name);
            writer.WriteString("screenId", value.ScreenId);
            writer.WriteString("alignMode", value.AlignMode);
            // 规范键 `savedAt`，单位**秒**（mac 用 timeIntervalSince1970）
            writer.WriteNumber("savedAt", value.SavedAtMs / 1000.0);

            writer.WritePropertyName("entries");
            writer.WriteStartArray();
            foreach (var e in value.Entries)
            {
                writer.WriteStartObject();
                writer.WriteString("id", e.Id);
                writer.WriteNumber("x", e.X);
                writer.WriteNumber("y", e.Y);
                writer.WriteNumber("width", e.Width);
                writer.WriteNumber("height", e.Height);
                writer.WriteEndObject();
            }
            writer.WriteEndArray();
            writer.WriteEndObject();
        }
    }
}
