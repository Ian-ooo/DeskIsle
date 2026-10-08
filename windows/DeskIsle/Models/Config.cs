using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;
using DeskIsle.Services;

namespace DeskIsle.Models
{
    public class Config
    {
        private static readonly JsonSerializerOptions JsonOptions = new()
        {
            WriteIndented = true,
            PropertyNameCaseInsensitive = true
        };

        private readonly string _configDir;
        private readonly string _configPath;
        private readonly string _bakPath;
        private FileSystemWatcher? _watcher;
        private DateTime _lastSaveTime = DateTime.MinValue;
        private readonly object _lock = new();

        public event Action? OnConfigChanged;

        public JsonObject Raw { get; private set; } = new();
        public List<PartitionModel> Partitions { get; private set; } = new();
        public Dictionary<string, object> Settings { get; private set; } = new();

        /// <summary>
        /// 分区显隐（幽灵模式）。多显示器下<b>按显示器独立</b>：键 = 显示器 DeviceName。
        /// 内存态，不落盘（重启后默认全部显示）。
        /// </summary>
        private readonly HashSet<string> _hiddenScreens = new();

        public int Revision { get; private set; }

        /// <summary>指定显示器上的分区当前是否处于隐藏态。</summary>
        public bool IsScreenHidden(string deviceName) => _hiddenScreens.Contains(deviceName);

        public void SetScreenHidden(string deviceName, bool hidden)
        {
            if (string.IsNullOrEmpty(deviceName)) return;
            if (hidden) _hiddenScreens.Add(deviceName);
            else _hiddenScreens.Remove(deviceName);
        }

        public void ToggleScreenHidden(string deviceName)
            => SetScreenHidden(deviceName, !IsScreenHidden(deviceName));

        /// <summary>显示器拔出后清理其隐藏态，避免设备名被复用导致误判。</summary>
        public void PruneHiddenScreens(IEnumerable<string> aliveDeviceNames)
        {
            var keep = new HashSet<string>(aliveDeviceNames);
            _hiddenScreens.IntersectWith(keep);
        }

        public string AlignMode => GetSetting("alignMode", "top");
        public bool IsLayoutLocked => GetSetting("isLayoutLocked", false);
        public bool ShowTopBar => GetSetting("showTopBar", true);
        /// <summary>
        /// 拖动 / 缩放时靠近屏幕边缘或邻近分区自动吸附。
        /// **规范键名是 mac 的 <c>snapToEdges</c>**，Windows 旧名 <c>edgeSnapping</c>
        /// 仅作兼容读取（理由同 <see cref="HoverPreview"/>：键名不统一会静默失效）。
        /// </summary>
        public bool EdgeSnapping => GetSetting("snapToEdges", GetSetting("edgeSnapping", true));
        /// <summary>
        /// 折叠分区悬停时临时展开预览。
        /// **规范键名是 mac 的 <c>hoverPeekCollapsed</c>**，Windows 旧名 <c>hoverPreview</c>
        /// 仅作兼容读取 —— 键名不统一的话，mac / Electron 导出的配置在 Windows 上
        /// 这一项会被静默忽略、退回默认值（用户改了设置却没生效，且无任何提示）。
        /// 与 macOS `PartitionView` 的 `hoverPeekCollapsed` 同源。
        /// </summary>
        public bool HoverPreview =>
            GetSetting("hoverPeekCollapsed", GetSetting("hoverPreview", true));
        public bool LaunchAtLogin => GetSetting("launchAtLogin", false);

        /// <summary>
        /// 显示 / 隐藏分区热键。
        /// **规范键名是 mac 的 <c>globalShortcut</c>**，同时兼容 Windows 历史上写下的
        /// <c>globalHotkey</c> —— 不兼容的话，「在 Windows 上自定义的热键」导出到 mac
        /// 再导回来就会被静默忽略、退回默认值。
        /// </summary>
        public string GlobalHotkey => FirstSetting("Alt+D", "globalShortcut", "globalHotkey");

        /// <summary>
        /// 横排最大列数 —— 取值范围、默认值必须与 macOS <c>Config.maxColumns</c> /
        /// Electron <c>settings.maxColumns</c> **完全一致**（4 ~ 6，默认 5）。
        ///
        /// ⚠️ 这里曾经是 <c>Clamp(x, 4, 8)</c>，而另两端是 <c>[4, 6]</c>：
        /// 同一份配置（<c>maxColumns = 7</c>）在 Windows 上排 7 列、在 mac / Electron 上排 6 列，
        /// 跨端导入同一份备份会得到两种布局。列数是描述 Removes 三端一致性的基础，必须收敛。
        /// </summary>
        public int MaxColumns => Math.Clamp(GetSetting("maxColumns", 5), 4, 6);

        /// <summary>
        /// 横排列高方向 —— **只影响「顶部横向排序」（top）**：
        /// <c>leftToRight</c> = 左侧最高、向右依次递减或相等（默认）；
        /// <c>rightToLeft</c> = 右侧最高、向左依次递减或相等。
        ///
        /// 读取时对未知值回退到默认，老配置无需迁移。与 mac / Electron 同键名。
        ///
        /// ⚠️ 受分区顺序限制，方向**不总是做得到**（末位是全序列最高分区时，最后一列必然最高
        /// ⇒「左侧最高」无解），此时由 <c>LayoutEngine.BalancedColumnRanges</c> 退化为「违例最小」。
        /// </summary>
        public string TopHeightOrder
        {
            get
            {
                var v = GetSetting("topHeightOrder", "leftToRight");
                return string.Equals(v, "rightToLeft", StringComparison.OrdinalIgnoreCase)
                    ? "rightToLeft"
                    : "leftToRight";
            }
        }

        public string PartitionWidthMode => GetSetting("partitionWidthMode", "auto");
        public double CustomPartitionWidth => GetSetting("customPartitionWidth", 280.0);
        public double DefaultPartitionHeight => Math.Max(140.0, GetSetting("defaultPartitionHeight", 200.0));

        /// <summary>
        /// 分区最小高度（全局）：**新建分区**的初始高度、**自适应宽高**算出的高度都不会低于它。
        ///
        /// 未显式设置时**跟随 <see cref="DefaultPartitionHeight"/>**（默认 200）：
        /// 老配置无需迁移、升级后行为不变，且符合「默认与分区默认高度一致」的预期 ——
        /// 用户改「默认高度」而从未碰过这一项时，下限跟着走。
        /// 一旦用户显式设定过，就以设定值为准，不再随默认高度变化。
        /// 硬下限同样取 140（与默认高度的可输入下限一致），避免把分区压得只剩标题栏。
        /// 键名 <c>minPartitionHeight</c>，与 mac 基线一致。
        /// </summary>
        public double MinPartitionHeight
        {
            get
            {
                double v = GetSetting("minPartitionHeight", -1.0);
                return v < 0 ? DefaultPartitionHeight : Math.Max(140.0, v);
            }
        }

        /// <summary>
        /// 分区背景不透明度（全局，滑动可调）：0 = 最通透（仅毛玻璃），1 = 深色实底。
        /// 默认 0.6 —— 与历史卡片底色 #991C1C22 的等效不透明度一致，老配置升级后视觉不变。
        /// </summary>
        public double PartitionBgOpacity => Math.Clamp(GetSetting("partitionBgOpacity", 0.6), 0.0, 1.0);

        // ── 与 mac 基线对齐的配置维度 ────────────────────────────────────────

        /// <summary>当前代码期望的配置结构版本（与 mac 基线一致）。</summary>
        public const int CurrentSchemaVersion = 3;

        /// <summary>
        /// 配置结构版本号。版本历史：
        /// 1 —— 早期（无版本号、无按屏字段）；
        /// 2 —— 引入按屏字段（alignModeByScreen / lockedByScreen / topBarByScreen）+ 独立搜索热键；
        /// 3 —— 引入布局预设（layoutPresets）。
        ///
        /// ⚠️ **两个位置都要读**：mac 写在**顶层** <c>raw["schemaVersion"]</c>，
        /// 而 Windows / Electron 历史上写在 <c>settings["schemaVersion"]</c>。
        /// 只读一处的话，会把一份「其实已经是 v3」的配置当成 v1 重新迁移一遍 ——
        /// 版本语义失真，后续排查完全对不上。
        /// </summary>
        public int SchemaVersion => NodeInt(TopNode("schemaVersion")) ?? GetSetting("schemaVersion", 1);

        /// <summary>
        /// 全局搜索热键 —— 与显隐热键 <see cref="GlobalHotkey"/> **独立注册**，
        /// 改一个不会把另一个顶掉（与 mac 端 id=1 / id=2 的分派方式对应）。
        /// 规范键名是 mac 的 <c>searchShortcut</c>，兼容 Windows 旧名 <c>searchHotkey</c>。
        /// </summary>
        public string SearchHotkey => FirstSetting("Alt+F", "searchShortcut", "searchHotkey");

        /// <summary>
        /// 配置结构迁移 —— 对齐 mac 端 <c>Config.migrate()</c> 的三条原则：
        /// 1. **新增字段一律可选、读取器自带默认值**；
        /// 2. **只登记版本号、不搬运数据** —— 同一份配置跑两次结果完全一致（幂等），
        ///    这样即使被旧版本回写、再被新版本读到，也不会重复或错乱；
        /// 3. **版本号缺失一律视为 1**。
        /// </summary>
        /// <returns>是否真的发生了迁移（调用方据此把版本号落盘）。</returns>
        public bool Migrate()
        {
            int from = SchemaVersion;
            if (from >= CurrentSchemaVersion) return false;

            if (from < 2)
            {
                // v1 → v2：引入按屏表与独立搜索热键。
                // 只补空表、**不动旧字段** —— 读取侧统一「表为空则回退旧全局键」
                // （见 ScreenFlag / AlignModeFor），因此不需要把 showTopBar 搬进 topBarByScreen。
                if (!Settings.ContainsKey("alignModeByScreen")) Settings["alignModeByScreen"] = new Dictionary<string, string>();
                if (!Settings.ContainsKey("lockedByScreen")) Settings["lockedByScreen"] = new Dictionary<string, bool>();
                if (!Settings.ContainsKey("topBarByScreen")) Settings["topBarByScreen"] = new Dictionary<string, bool>();
                // 规范键名是 mac 的 searchShortcut；旧名 searchHotkey 由 SearchHotkey 属性兼容读取
                if (!Settings.ContainsKey("searchShortcut") && !Settings.ContainsKey("searchHotkey"))
                {
                    Settings["searchShortcut"] = "Alt+F";
                }
            }

            if (from < 3)
            {
                // v2 → v3：引入布局预设（**顶层落点**，与 mac 一致）
                if (!Raw.ContainsKey("layoutPresets")) Raw["layoutPresets"] = new JsonArray();
            }

            // 版本号写在**顶层**（mac 的规范落点），顺手清掉 settings 里的旧副本
            Raw["schemaVersion"] = CurrentSchemaVersion;
            Settings.Remove("schemaVersion");

            Save();
            return true;
        }

        /// <summary>
        /// 把「被另两端放进 <c>settings</c> 的顶层字段」搬回顶层，统一规范落点。
        ///
        /// <c>schemaVersion</c> / <c>layoutPresets</c> 在 mac（基线）是**顶层**字段，
        /// 而 Windows / Electron 历史上写在 <c>settings</c> 里。两个位置长期并存，
        /// 文件里就等于有「两个版本的真相」：每次互导都会触发一次假迁移，
        /// 而且谁后保存谁说了算 —— 这种问题极难排查。
        ///
        /// 顺带清掉旧热键别名（规范键存在时才删，否则会把用户唯一的那份设置删掉）。
        ///
        /// **幂等**：搬完就把 <c>settings</c> 里那份删掉，再跑一次什么都不做。
        /// 返回是否发生了改动（调用方据此决定是否立刻落盘一次）。
        /// </summary>
        private bool NormalizeKeyLocations()
        {
            bool changed = false;

            foreach (var key in new[] { "schemaVersion", "layoutPresets" })
            {
                bool inTop = Raw.ContainsKey(key);
                bool inSettings = Settings.ContainsKey(key);

                if (!inTop && inSettings)
                {
                    Raw[key] = ToNode(Settings[key]);       // 顶层还没有 → 搬上去
                    Settings.Remove(key);
                    changed = true;
                }
                else if (inTop && inSettings)
                {
                    Settings.Remove(key);                   // 顶层已有权威值 → 丢掉 settings 里的副本
                    changed = true;
                }
            }

            foreach (var (canonical, legacy) in new[]
                     {
                         ("globalShortcut", "globalHotkey"),
                         ("searchShortcut", "searchHotkey")
                     })
            {
                if (Settings.ContainsKey(canonical) && Settings.ContainsKey(legacy))
                {
                    Settings.Remove(legacy);
                    changed = true;
                }
            }

            return changed;
        }

        /// <summary>读顶层字段；不存在返回 null。</summary>
        private JsonNode? TopNode(string key)
            => Raw.TryGetPropertyValue(key, out var node) ? node : null;

        /// <summary>把 JsonNode 宽松地读成整数：数字（含小数）与字符串数字都认。</summary>
        private static int? NodeInt(JsonNode? node)
        {
            if (node is not JsonValue value) return null;
            if (value.TryGetValue(out int i)) return i;
            if (value.TryGetValue(out double d)) return (int)d;
            if (value.TryGetValue(out string? s) && int.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out var p))
            {
                return p;
            }
            return null;
        }

        /// <summary>把 <c>settings</c> 里那个「解析出来是 JsonElement」的值转成可写回 <see cref="Raw"/> 的 JsonNode。</summary>
        private static JsonNode? ToNode(object? value)
        {
            switch (value)
            {
                case null:
                    return null;
                case JsonNode node:
                    return node.DeepClone();
                case JsonElement element:
                    return element.ValueKind is JsonValueKind.Undefined or JsonValueKind.Null
                        ? null
                        : JsonNode.Parse(element.GetRawText());
                default:
                    return JsonSerializer.SerializeToNode(value, JsonOptions);
            }
        }

        /// <summary>按顺序取第一个非空的字符串设置项，都没有就用默认值。</summary>
        private string FirstSetting(string fallback, params string[] keys)
        {
            foreach (var key in keys)
            {
                var v = GetSetting(key, string.Empty);
                if (!string.IsNullOrWhiteSpace(v)) return v;
            }
            return fallback;
        }

        /// <summary>
        /// 读取布局预设列表。解析失败一律返回空表 ——
        /// 一条脏数据不该让整个预设列表消失（更不该让程序起不来）。
        /// 规范落点是**顶层** <c>raw["layoutPresets"]</c>，同时兼容旧的 <c>settings</c> 落点。
        /// </summary>
        public List<LayoutPreset> GetLayoutPresets()
        {
            if (TopNode("layoutPresets") is JsonArray topArray)
            {
                return DeserializePresets(topArray.ToJsonString());
            }

            if (Settings.TryGetValue("layoutPresets", out var val))
            {
                if (val is JsonElement e && e.ValueKind == JsonValueKind.Array)
                {
                    return DeserializePresets(e.GetRawText());
                }
                if (val is List<LayoutPreset> list) return new List<LayoutPreset>(list);
            }
            return new List<LayoutPreset>();
        }

        private static List<LayoutPreset> DeserializePresets(string json)
        {
            try
            {
                return JsonSerializer.Deserialize<List<LayoutPreset>>(json, JsonOptions) ?? new List<LayoutPreset>();
            }
            catch
            {
                return new List<LayoutPreset>();
            }
        }

        public void SetLayoutPresets(List<LayoutPreset> presets)
        {
            // 规范落点只写顶层；settings 里那份一律删掉，避免同一个东西存两份、互相矛盾
            Raw["layoutPresets"] = JsonSerializer.SerializeToNode(presets, JsonOptions) ?? new JsonArray();
            Settings.Remove("layoutPresets");
            Save();
            OnConfigChanged?.Invoke();
        }

        // ── 历史快照（滚动备份）────────────────────────────────────────────
        private const int HistoryMax = 20;
        /// <summary>同一分钟内只留一份：拖动分区、连续调设置会高频保存，没有这个闸门会瞬间用满名额。</summary>
        private const int HistoryMinIntervalMs = 60_000;

        public string HistoryDir => Path.Combine(_configDir, "history");
        private DateTime _lastHistoryAt = DateTime.MinValue;

        /// <summary>
        /// 把**当前磁盘上这一份**配置复制进 <c>history/</c>。
        ///
        /// 必须在「写入新配置之前」调用 —— 快照的意义就是「改坏之前长什么样」。
        /// <paramref name="force"/> 用于「恢复历史」：恢复本身也要先留一份，
        /// 这样点错了还能再回滚，而不是一次单向操作。
        /// </summary>
        public void PushHistorySnapshot(bool force = false)
        {
            try
            {
                if (!File.Exists(_configPath)) return;

                var now = DateTime.Now;
                if (!force && (now - _lastHistoryAt).TotalMilliseconds < HistoryMinIntervalMs) return;

                Directory.CreateDirectory(HistoryDir);
                string target = Path.Combine(HistoryDir, $"deskisle_config-{now:yyyyMMdd-HHmmss}.json");
                File.Copy(_configPath, target, true);
                _lastHistoryAt = now;

                // 超出上限就删最旧的几份
                var files = new DirectoryInfo(HistoryDir)
                    .GetFiles("deskisle_config-*.json")
                    .OrderByDescending(f => f.LastWriteTime)
                    .ToList();
                for (int i = HistoryMax; i < files.Count; i++)
                {
                    try { files[i].Delete(); } catch { }
                }
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"[DeskIsle] PushHistorySnapshot failed: {ex.Message}");
            }
        }

        /// <summary>列出历史快照，新的在前。用户想「回到刚才那一下」远比回滚到三天前常见。</summary>
        public List<(string Name, DateTime Time, long Size)> ListHistorySnapshots()
        {
            var result = new List<(string, DateTime, long)>();
            try
            {
                if (!Directory.Exists(HistoryDir)) return result;
                foreach (var f in new DirectoryInfo(HistoryDir).GetFiles("deskisle_config-*.json"))
                {
                    result.Add((f.Name, f.LastWriteTime, f.Length));
                }
                result.Sort((a, b) => b.Item2.CompareTo(a.Item2));
            }
            catch { }
            return result;
        }

        /// <summary>
        /// 恢复某份历史快照（<paramref name="name"/> 为空则取最近一份）。
        /// 成功时把配置重新加载进内存，并触发 <see cref="OnConfigChanged"/>。
        /// </summary>
        public bool RestoreHistorySnapshot(string? name, out string restored, out string error)
        {
            restored = string.Empty;
            error = string.Empty;
            try
            {
                var snapshots = ListHistorySnapshots();
                if (snapshots.Count == 0)
                {
                    error = "尚无可恢复的历史快照";
                    return false;
                }

                string targetName = string.IsNullOrWhiteSpace(name) ? snapshots[0].Name : name!;
                string targetPath = Path.Combine(HistoryDir, targetName);
                if (!File.Exists(targetPath))
                {
                    error = $"快照不存在：{targetName}";
                    return false;
                }

                string json = File.ReadAllText(targetPath);
                var node = JsonNode.Parse(json);
                if (node is not JsonObject obj)
                {
                    error = "快照内容不是合法配置";
                    return false;
                }

                // 恢复动作本身也先留一份，保证「点错了还能回去」
                PushHistorySnapshot(true);

                lock (_lock)
                {
                    // 同样走原子提交：快照里若混进脏数据，也不该把内存状态搞成半成品
                    ApplyRaw(obj);
                    // 老快照里 schemaVersion / layoutPresets 可能还落在 settings 里 ——
                    // 下面的 Save() 会把它们按规范落点写回顶层，恢复一次就顺手归一了。
                    NormalizeKeyLocations();
                }
                Save();
                restored = targetName;
                OnConfigChanged?.Invoke();
                return true;
            }
            catch (Exception ex)
            {
                error = ex.Message;
                return false;
            }
        }

        /// <summary>
        /// 指定显示器的对齐模式（多显示器下每屏独立）。
        /// 存放于 <c>settings.alignModeByScreen[deviceName]</c>；未设置时回退全局 <see cref="AlignMode"/>。
        /// </summary>
        public string AlignModeFor(string? screenId)
        {
            if (!string.IsNullOrEmpty(screenId) && Settings.TryGetValue("alignModeByScreen", out var val))
            {
                try
                {
                    if (val is JsonElement elem && elem.ValueKind == JsonValueKind.Object)
                    {
                        if (elem.TryGetProperty(screenId, out var m) && m.ValueKind == JsonValueKind.String)
                        {
                            var s = m.GetString();
                            if (!string.IsNullOrEmpty(s)) return s!;
                        }
                    }
                    else if (val is Dictionary<string, string> d &&
                             d.TryGetValue(screenId, out var s2) && !string.IsNullOrEmpty(s2))
                    {
                        return s2;
                    }
                }
                catch { }
            }
            return AlignMode;
        }

        /// <summary>
        /// 记录某显示器的对齐模式。同时更新全局 <c>alignMode</c>：
        /// 新接入的显示器、以及旧版本读配置时都能拿到合理默认值。
        /// </summary>
        public void SetAlignModeFor(string? screenId, string mode)
        {
            Settings["alignMode"] = mode;
            if (!string.IsNullOrEmpty(screenId))
            {
                var table = GetAlignModeTable();
                table[screenId] = mode;
                Settings["alignModeByScreen"] = table;
            }
            Save();
            OnConfigChanged?.Invoke();
        }

        /// <summary>读取按屏对齐模式表（自动兼容 JsonElement / 字典两种形态）。</summary>
        private Dictionary<string, string> GetAlignModeTable()
        {
            if (Settings.TryGetValue("alignModeByScreen", out var val))
            {
                try
                {
                    if (val is JsonElement elem && elem.ValueKind == JsonValueKind.Object)
                    {
                        return JsonSerializer.Deserialize<Dictionary<string, string>>(elem.GetRawText(), JsonOptions)
                               ?? new Dictionary<string, string>();
                    }
                    if (val is Dictionary<string, string> d)
                    {
                        return new Dictionary<string, string>(d);
                    }
                }
                catch { }
            }
            return new Dictionary<string, string>();
        }

        /// <summary>指定显示器上分区是否被「锁定分区位置」（多屏独立）。</summary>
        public bool IsScreenLocked(string? screenId)
            => ScreenFlag("lockedByScreen", "isLayoutLocked", screenId, false);

        public void SetScreenLocked(string? screenId, bool locked)
            => SetScreenFlag("lockedByScreen", "isLayoutLocked", screenId, locked);

        /// <summary>指定显示器是否显示顶部导航栏（多屏独立）。</summary>
        public bool ShowTopBarFor(string? screenId)
            => ScreenFlag("topBarByScreen", "showTopBar", screenId, true);

        public void SetShowTopBarFor(string? screenId, bool on)
            => SetScreenFlag("topBarByScreen", "showTopBar", screenId, on);

        /// <summary>
        /// 读「按屏布尔表」：表为空时回退旧版全局键（自然完成迁移）；
        /// 表非空后逐屏独立，未显式设置的屏取 defaultValue。
        /// </summary>
        private bool ScreenFlag(string key, string legacyKey, string? screenId, bool defaultValue)
        {
            if (Settings.TryGetValue(key, out var val))
            {
                var table = ToBoolTable(val);
                if (table.Count > 0)
                {
                    return (screenId != null && table.TryGetValue(screenId, out var b)) ? b : defaultValue;
                }
            }
            return GetSetting(legacyKey, defaultValue);
        }

        /// <summary>写「按屏布尔表」（同时更新旧版全局键，供降级使用）。</summary>
        private void SetScreenFlag(string key, string legacyKey, string? screenId, bool on)
        {
            Settings[legacyKey] = on;
            if (!string.IsNullOrEmpty(screenId))
            {
                var table = ToBoolTable(Settings.TryGetValue(key, out var v) ? v : null);
                table[screenId] = on;
                Settings[key] = table;
            }
            Save();
            OnConfigChanged?.Invoke();
        }

        private static Dictionary<string, bool> ToBoolTable(object? val)
        {
            try
            {
                if (val is JsonElement e && e.ValueKind == JsonValueKind.Object)
                {
                    return JsonSerializer.Deserialize<Dictionary<string, bool>>(e.GetRawText(), JsonOptions)
                           ?? new Dictionary<string, bool>();
                }
                if (val is Dictionary<string, bool> d) return new Dictionary<string, bool>(d);
            }
            catch { }
            return new Dictionary<string, bool>();
        }

        /// <summary>清理已拔掉显示器的按屏设置（对齐模式 / 锁定 / 顶栏显隐），避免设备名复用导致误判。</summary>
        public void PruneScreenSettings(IEnumerable<string> aliveDeviceNames)
        {
            var alive = new HashSet<string>(aliveDeviceNames);
            bool changed = false;

            var align = GetAlignModeTable();
            var nextAlign = align.Where(kv => alive.Contains(kv.Key))
                                 .ToDictionary(kv => kv.Key, kv => kv.Value);
            if (nextAlign.Count != align.Count)
            {
                Settings["alignModeByScreen"] = nextAlign;
                changed = true;
            }

            foreach (var key in new[] { "lockedByScreen", "topBarByScreen" })
            {
                var table = ToBoolTable(Settings.TryGetValue(key, out var v) ? v : null);
                var next = table.Where(kv => alive.Contains(kv.Key))
                                .ToDictionary(kv => kv.Key, kv => kv.Value);
                if (next.Count != table.Count)
                {
                    Settings[key] = next;
                    changed = true;
                }
            }

            if (changed) Save();
        }

        public double CalculateStandardWidth(double screenWidth)
        {
            if (PartitionWidthMode == "custom")
            {
                return CustomPartitionWidth > 0 ? CustomPartitionWidth : 280.0;
            }
            int cols = MaxColumns;
            double gap = 16.0;
            double totalGaps = (cols + 1) * gap;
            double avail = screenWidth > 0 ? screenWidth : 1920.0;
            double calculated = Math.Floor((avail - totalGaps) / cols);
            return Math.Max(200.0, calculated);
        }

        public Config()
        {
            string appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            _configDir = Path.Combine(appData, "DeskIsle");
            _configPath = Path.Combine(_configDir, "deskisle_config.json");
            _bakPath = Path.Combine(_configDir, "deskisle_config.json.bak");

            if (!Directory.Exists(_configDir))
            {
                Directory.CreateDirectory(_configDir);
            }

            Load();
            StartWatcher();
        }

        public bool Load()
        {
            lock (_lock)
            {
                try
                {
                    if (!File.Exists(_configPath))
                    {
                        InitDefaultConfig();
                        Save();
                        return true;
                    }

                    string json = File.ReadAllText(_configPath);
                    if (JsonNode.Parse(json) is JsonObject obj)
                    {
                        // 原子提交：解析全成功才换内存状态，见 ApplyRaw 的说明
                        ApplyRaw(obj);
                        SettleAfterLoad();
                        return true;
                    }

                    System.Diagnostics.Debug.WriteLine("[DeskIsle] Config root is not a JSON object");
                }
                catch (Exception ex)
                {
                    System.Diagnostics.Debug.WriteLine($"[DeskIsle] Config load failed: {ex.Message}");
                }

                // ── 主文件读不出来（解析失败 / 根不是对象）──
                // 先把这个坏文件**改名留档**：它是「出事那一刻的原样」，
                // 而下面无论走 .bak 恢复还是重建默认配置，都会把它覆盖掉 ——
                // 不先留一份，用户就再也看不到原始内容到底长什么样。
                PreserveCorruptConfig();

                // 再试 .bak：它通常就是「上一次保存前」的版本，能救回来的话用户几乎无感。
                if (File.Exists(_bakPath))
                {
                    try
                    {
                        string bakJson = File.ReadAllText(_bakPath);
                        if (JsonNode.Parse(bakJson) is JsonObject bakObj)
                        {
                            ApplyRaw(bakObj);
                            SettleAfterLoad(forceSave: true);
                            return true;
                        }
                    }
                    catch { }
                }

                // ── 主文件与 .bak 都救不回来 ── 用一份全新配置顶上。
                // 关键：不能就这么放着 —— 之后任意一次 Save() 都会把它静默覆盖。
                // 坏文件已在上面留档（名字带时间戳），出问题可以去 %AppData%\DeskIsle\ 里找回。
                InitDefaultConfig();
                Save();
                return true;
            }
        }

        /// <summary>
        /// 读盘之后的收尾动作，两条路径（主文件 / <c>.bak</c> 救回）共用：
        /// 先把「被另两端放进 <c>settings</c> 的顶层字段」搬回顶层，再登记版本号。
        ///
        /// 迁移是**幂等**的（只登记版本号、不搬运数据），重复执行安全。
        /// 注意调用点仍在 <c>lock (_lock)</c> 内 —— C# 的 lock 是可重入的，
        /// 内部 <c>Save()</c> 再取一次不会死锁。
        /// </summary>
        /// <param name="forceSave">
        /// 无条件落盘一次。<c>.bak</c> 救回时必须为 true ——
        /// 坏文件已被留档改名，磁盘上此刻**根本没有主配置文件**；
        /// 不写回去的话下次启动会走「文件不存在」分支、拿一份全新默认配置顶上，
        /// 用户刚被救回来的配置等于又丢一次。
        /// </param>
        private void SettleAfterLoad(bool forceSave = false)
        {
            bool moved = NormalizeKeyLocations();
            bool migrated = Migrate();
            // 归一后的落点要落盘一次，否则每次启动都要白搬一遍（Migrate 内部已经存过了）
            if (forceSave || (moved && !migrated)) Save();
        }

        /// <summary>
        /// 把一份解析不出来的配置改名留档（不删除）。
        /// 与 <c>history/</c> 快照的区别：快照是**定期滚动**的，可能已经把出事那一刻挤掉；
        /// 这里是对「读都读不出来的坏文件」专门留的原件，只增不减。
        /// </summary>
        private void PreserveCorruptConfig()
        {
            try
            {
                if (!File.Exists(_configPath)) return;
                string target = Path.Combine(_configDir,
                    $"deskisle_config.corrupt-{DateTime.Now:yyyyMMdd-HHmmss}.json");
                File.Move(_configPath, target);
                System.Diagnostics.Debug.WriteLine($"[DeskIsle] 配置无法解析，已留档为 {target}");
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"[DeskIsle] PreserveCorruptConfig failed: {ex.Message}");
            }
        }

        public void Save()
        {
            lock (_lock)
            {
                try
                {
                    _lastSaveTime = DateTime.UtcNow;

                    // 留一份历史快照（内容是**改之前**的磁盘版本）。
                    // 必须在覆写 _configPath 之前调用；内置 60s 闸门，
                    // 所以拖动分区这类高频保存不会刷爆 history/。
                    PushHistorySnapshot();

                    // 同步 Partitions 和 Settings 到 Raw
                    Raw["partitions"] = JsonSerializer.SerializeToNode(Partitions, JsonOptions);
                    Raw["settings"] = JsonSerializer.SerializeToNode(Settings, JsonOptions);

                    if (File.Exists(_configPath))
                    {
                        try { File.Copy(_configPath, _bakPath, true); } catch { }
                    }

                    string tmpPath = _configPath + ".tmp";
                    string json = Raw.ToJsonString(JsonOptions);
                    File.WriteAllText(tmpPath, json);

                    if (File.Exists(_configPath)) File.Delete(_configPath);
                    File.Move(tmpPath, _configPath);

                    Revision++;
                }
                catch (Exception ex)
                {
                    System.Diagnostics.Debug.WriteLine($"[DeskIsle] Config save failed: {ex.Message}");
                }
            }
        }

        public void Update(Action<Config> action)
        {
            lock (_lock)
            {
                action(this);
                Save();
            }
            OnConfigChanged?.Invoke();
        }

        public T GetSetting<T>(string key, T defaultValue)
        {
            if (Settings.TryGetValue(key, out var val))
            {
                if (val is JsonElement elem)
                {
                    try
                    {
                        if (typeof(T) == typeof(bool)) return (T)(object)elem.GetBoolean();
                        if (typeof(T) == typeof(string)) return (T)(object)elem.GetString()!;
                        if (typeof(T) == typeof(int)) return (T)(object)elem.GetInt32();
                        if (typeof(T) == typeof(double)) return (T)(object)elem.GetDouble();
                    }
                    catch { }
                }
                else if (val is T typedVal)
                {
                    return typedVal;
                }
            }
            return defaultValue;
        }

        public void SetSetting<T>(string key, T value)
        {
            Settings[key] = value!;
            Save();
            OnConfigChanged?.Invoke();
        }

        /// <summary>
        /// 解析并**原子提交**：先把 partitions / settings 都解析成功，最后才一次性替换内存状态。
        ///
        /// 为什么必须这样：修复前是「先把 <see cref="Raw"/> 换成新对象、再解析」，
        /// 一旦解析中途抛异常（例如导入 mac / Electron 的配置时 <c>files</c> 形状不合、
        /// 或 <c>screenId</c> 是数字而非字符串），就会停在一个**半成品状态**：
        /// <c>Raw</c> 已是新内容、<c>Partitions</c> 却还是空表。
        /// 此后任何一次 <see cref="Save"/> 都会按老规矩把 <c>Partitions</c> 序列化回 <c>Raw</c>
        /// —— 于是**用户刚导入的分区在磁盘上被空表覆盖**。
        ///
        /// 现在解析失败时内存状态**原样不动**，最坏结果也只是「这次没读进来」，
        /// 磁盘上那份配置仍然完好（另外还有 <c>.bak</c> 与 <c>history/</c> 两重兜底）。
        /// </summary>
        private void ApplyRaw(JsonObject obj)
        {
            var parts = obj["partitions"] is JsonArray partsArray
                ? JsonSerializer.Deserialize<List<PartitionModel>>(partsArray.ToJsonString(), JsonOptions) ?? new List<PartitionModel>()
                : new List<PartitionModel>();

            var settings = obj["settings"] is JsonObject settingsObj
                ? JsonSerializer.Deserialize<Dictionary<string, object>>(settingsObj.ToJsonString(), JsonOptions) ?? new Dictionary<string, object>()
                : new Dictionary<string, object>();

            // ↓ 两个都解析成功了，才开始改内存 —— 上面任何一步抛异常都不会留下半成品
            Raw = obj;
            // 已下线类型的分区（当前是 collection 文件收集箱）：代码里已经没有对应视图，
            // 留着会被渲染成一个**用户自己删不掉**的空壳 —— 读盘时就剔掉。
            // 判据在 Services/RemovedPartition（与 mac DeskIsleCore 同源）。
            var filtered = RemovedPartition.DroppingRemovedTypes(parts);
            if (filtered.dropped > 0)
            {
                System.Diagnostics.Debug.WriteLine(
                    $"[DeskIsle] 已剔除 {filtered.dropped} 个已下线类型的分区（{string.Join(" / ", RemovedPartition.RemovedTypes)}）");
            }
            Partitions = filtered.kept;
            Settings = settings;
            Revision++;
        }

        private void InitDefaultConfig()
        {
            // 分区表**留空** —— 与 README「纯粹开箱：不预置任何示例分区，首次运行是完全干净的桌面」
            // 以及 mac / Electron 两端的行为保持一致。
            //
            // 这里曾经预置「映射文件夹 / 今日待办 / 随手便签」三个示例分区（还带示例内容）。
            // 问题在于：新用户打开看到的是三个**不属于自己**的分区，得先逐个删掉才能开始用；
            // 而且三方不一致会让「跨端导入 / 对照行为」时无从判断差异来自示例还是来自配置。
            Partitions = new List<PartitionModel>();

            Settings = new Dictionary<string, object>
            {
                ["alignMode"] = "top",
                ["isLayoutLocked"] = false,
                ["showTopBar"] = true,
                ["snapToEdges"] = true,
                ["hoverPeekCollapsed"] = true,
                ["launchAtLogin"] = false,
                // 规范键名 = mac 的 globalShortcut / searchShortcut（Windows 旧名由读取器兼容）
                ["globalShortcut"] = "Alt+D",
                ["searchShortcut"] = "Alt+F",
                // 与 mac 基线对齐的新字段：全新安装直接写成最新版结构，
                // 免得「装完第一次跑不迁移、第二次才迁移」这种前后不一致。
                ["alignModeByScreen"] = new Dictionary<string, string>(),
                ["lockedByScreen"] = new Dictionary<string, bool>(),
                ["topBarByScreen"] = new Dictionary<string, bool>()
            };

            Raw = new JsonObject
            {
                ["partitions"] = JsonSerializer.SerializeToNode(Partitions, JsonOptions),
                ["settings"] = JsonSerializer.SerializeToNode(Settings, JsonOptions),
                // schemaVersion / layoutPresets 是**顶层**字段（mac 的规范落点）
                ["schemaVersion"] = CurrentSchemaVersion,
                ["layoutPresets"] = new JsonArray()
            };
        }

        private void StartWatcher()
        {
            try
            {
                // 盯**目录**而不是文件：保存是「写 .tmp → 删原文件 → Move」，
                // 原文件被删掉的那一刻，盯在它上面的 watcher 就已经失效了。
                // 盯目录 + 按路径过滤则不受影响（这是三端一致的结论）。
                _watcher = new FileSystemWatcher(_configDir, "*.json")
                {
                    NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.FileName | NotifyFilters.CreationTime,
                    EnableRaisingEvents = true
                };

                // ⚠️ 三个事件**都必须监听**，只听 Changed 是不够的：
                // 无论本程序还是外部编辑器（VSCode / 记事本…），保存走的都是
                // 「删掉原文件 + 把临时文件挪过来」的原子替换 —— 对文件系统而言这是
                // **新建**一个文件，触发的是 Created / Renamed，而不是 Changed。
                // 只听 Changed 的后果是：外部改配置后程序毫无反应，只能重启才生效
                // （这正是「热重载仅覆盖部分场景」的根因）。
                _watcher.Changed += (_, e) => HandleExternalChange(e.FullPath);
                _watcher.Created += (_, e) => HandleExternalChange(e.FullPath);
                _watcher.Renamed += (_, e) => HandleExternalChange(e.FullPath);
            }
            catch { }
        }

        /// <summary>
        /// 配置文件发生变动时（无论来自本程序还是外部）尝试重读。
        /// </summary>
        private void HandleExternalChange(string path)
        {
            if (!path.Equals(_configPath, StringComparison.OrdinalIgnoreCase)) return;

            // 第 1 道过滤：自己刚写的（时间窗口，挡住绝大多数自触发）。
            if ((DateTime.UtcNow - _lastSaveTime).TotalSeconds < 1.0) return;

            System.Threading.Thread.Sleep(50); // 等写入平息，避免读到写了一半的文件

            // 第 2 道过滤：内容比对。时间窗口终究是个估计值 —— 外部工具若在窗口内
            // 改了文件就会被误吞。比对「磁盘上这一份」与「内存里这一份」是否一致则没有这个问题，
            // 代价只是多读一次文件（配置改动是低频事件，完全付得起）。
            try
            {
                if (File.Exists(_configPath))
                {
                    string diskJson = File.ReadAllText(_configPath);
                    string? mineJson = null;
                    lock (_lock)
                    {
                        mineJson = Raw.ToJsonString(JsonOptions);
                    }
                    if (string.Equals(NormalizeJsonForCompare(diskJson),
                                      NormalizeJsonForCompare(mineJson ?? ""),
                                      StringComparison.Ordinal))
                    {
                        return;   // 内容一致 ⇒ 这次变动不是「有人改了配置」，忽略
                    }
                }
            }
            catch
            {
                // 比对失败不影响主流程：照常往下走，让 Load() 自己兜住
            }

            if (Load())
            {
                OnConfigChanged?.Invoke();
            }
        }

        /// <summary>
        /// 把 JSON **规范化**后再比对：忽略空白与缩进差异。
        /// 否则「外部编辑器按自己的风格重排了缩进」会被误判成内容变化，
        /// 于是每次都白白重载一次 —— 表现是分区莫名重建、窗口闪一下。
        /// </summary>
        private static string NormalizeJsonForCompare(string json)
        {
            try
            {
                if (JsonNode.Parse(json) is JsonNode node)
                {
                    return node.ToJsonString();   // 不带缩进的紧凑形式
                }
            }
            catch
            {
                // 解析不了就退回原样比对：此时 Load() 也会走坏文件留档流程，不该在这里掩盖
            }
            return json;
        }
    }
}
