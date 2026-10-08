using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using DeskIsle.Models;
using DeskIsle.Native;
using DeskIsle.Services;

namespace DeskIsle.Views
{
    public partial class SettingsDialog : Window
    {
        private readonly Config _config;
        private readonly Action _onReloadRequested;

        public SettingsDialog(Config config, Action onReloadRequested)
        {
            InitializeComponent();
            _config = config;
            _onReloadRequested = onReloadRequested;

            HotkeyBox.Text = _config.GlobalHotkey;
            SearchHotkeyBox.Text = _config.SearchHotkey;
            StartupCheckBox.IsChecked = StartupService.IsLaunchAtStartup();
            SnappingCheckBox.IsChecked = _config.EdgeSnapping;
            HoverPeekCheckBox.IsChecked = _config.HoverPreview;
            // ⚠️ 无「音效反馈」开关：mac 基线与 Electron 都没有这一项，Windows 端
            // 曾有开关但从未有任何播放代码（假设置项），已按基线删除。

            InitLayoutWidthSettings();
            LoadDisplayInfo();
            RefreshPresets();
            RefreshHistoryInfo();

            MouseDown += (s, e) =>
            {
                if (e.ChangedButton == MouseButton.Left) DragMove();
            };
        }

        private void InitLayoutWidthSettings()
        {
            // ⚠️ 下拉只有 4 / 5 / 6 三项 —— 与 mac（唯一功能基线）的 Picker 逐项对齐，
            // 且 `Config.MaxColumns` 会再夹一次 [4,6]。旧版这里给了 7 / 8，
            // 选了会被静默夹回 6，属于「UI 撒谎」。
            int cols = _config.MaxColumns;
            MaxColsComboBox.SelectedIndex = cols switch
            {
                4 => 0,
                5 => 1,
                _ => 2          // 6 及任何越界值
            };

            bool isCustom = _config.PartitionWidthMode == "custom";
            WidthModeComboBox.SelectedIndex = isCustom ? 1 : 0;
            UpdateWidthModeUI();

            TopHeightOrderComboBox.SelectedIndex = _config.TopHeightOrder == "rightToLeft" ? 1 : 0;

            DefaultHeightBox.Text = ((int)_config.DefaultPartitionHeight).ToString();
            MinHeightBox.Text = ((int)_config.MinPartitionHeight).ToString();

            // 分区背景不透明度（全局）：滑块 0~100 映射到 0.0~1.0
            int bgPercent = (int)Math.Round(_config.PartitionBgOpacity * 100);
            BgOpacitySlider.Value = bgPercent;
            BgOpacityText.Text = bgPercent + "%";
        }

        private void UpdateWidthModeUI()
        {
            bool isCustom = WidthModeComboBox.SelectedIndex == 1;
            AutoWidthPreviewBorder.Visibility = isCustom ? Visibility.Collapsed : Visibility.Visible;
            CustomWidthPanel.Visibility = isCustom ? Visibility.Visible : Visibility.Collapsed;

            if (!isCustom)
            {
                // 用「本窗口所在显示器」的宽度预估（多屏分辨率不同，主屏工作区不再适用）
                var workArea = MonitorService.WorkingAreaDIP(MonitorService.ScreenOf(this), this);
                double calcW = _config.CalculateStandardWidth(workArea.Width);
                AutoWidthPreviewText.Text = $"{(int)calcW} px";
            }
        }

        /// <summary>
        /// 横排列高方向 —— 只影响「顶部横向排序」：从左到右 = 左侧最高、向右递减；
        /// 从右到左 = 右侧最高、向左递减。（与 mac / Electron 同键名 <c>topHeightOrder</c>）
        /// </summary>
        private void TopHeightOrderComboBox_SelectionChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
        {
            if (TopHeightOrderComboBox.SelectedItem is System.Windows.Controls.ComboBoxItem)
            {
                _config.SetSetting("topHeightOrder", TopHeightOrderComboBox.SelectedIndex == 1
                    ? "rightToLeft"
                    : "leftToRight");
                _config.Save();
            }
        }

        private void MaxColsComboBox_SelectionChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
        {
            if (MaxColsComboBox.SelectedItem is System.Windows.Controls.ComboBoxItem)
            {
                int cols = MaxColsComboBox.SelectedIndex switch
                {
                    0 => 4,
                    1 => 5,
                    _ => 6      // 与 mac 的 [4,6] 上限一致
                };
                _config.SetSetting("maxColumns", cols);
                UpdateWidthModeUI();
            }
        }

        /// <summary>分区背景不透明度滑块：写入全局设置（各分区窗口经 OnConfigChanged 实时刷新）。</summary>
        private void BgOpacitySlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
        {
            if (_config == null || BgOpacityText == null) return;   // InitializeComponent 期间兜底
            int percent = (int)Math.Round(e.NewValue);
            BgOpacityText.Text = percent + "%";
            _config.SetSetting("partitionBgOpacity", Math.Clamp(e.NewValue / 100.0, 0.0, 1.0));
        }

        private void WidthModeComboBox_SelectionChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
        {
            if (WidthModeComboBox.SelectedItem is System.Windows.Controls.ComboBoxItem)
            {
                string mode = WidthModeComboBox.SelectedIndex == 1 ? "custom" : "auto";
                _config.SetSetting("partitionWidthMode", mode);
                UpdateWidthModeUI();
            }
        }

        private void WidthPreset_Click(object sender, RoutedEventArgs e)
        {
            if (sender is System.Windows.Controls.Button btn && btn.Tag is string tagStr && double.TryParse(tagStr, out double width))
            {
                _config.SetSetting("partitionWidthMode", "custom");
                _config.SetSetting("customPartitionWidth", width);
                WidthModeComboBox.SelectedIndex = 1;
                UpdateWidthModeUI();
            }
        }

        private void DefaultHeightBox_LostFocus(object sender, RoutedEventArgs e)
        {
            if (double.TryParse(DefaultHeightBox.Text.Trim(), out double height))
            {
                // 与「分区最小高度」同一套夹取（含上限 = 屏幕可用高 - 60），
                // 否则填 5000 会出现「最小高度 990 / 默认高度 5000」的自相矛盾
                double finalHeight = ClampHeight(height);
                _config.SetSetting("defaultPartitionHeight", finalHeight);
                DefaultHeightBox.Text = ((int)finalHeight).ToString();
            }
            else
            {
                DefaultHeightBox.Text = ((int)_config.DefaultPartitionHeight).ToString();
            }
        }

        private void HeightPreset_Click(object sender, RoutedEventArgs e)
        {
            if (sender is System.Windows.Controls.Button btn && btn.Tag is string tagStr && double.TryParse(tagStr, out double height))
            {
                // 与「分区最小高度」同一套夹取（含上限 = 屏幕可用高 - 60），
                // 否则填 5000 会出现「最小高度 990 / 默认高度 5000」的自相矛盾
                double finalHeight = ClampHeight(height);
                _config.SetSetting("defaultPartitionHeight", finalHeight);
                DefaultHeightBox.Text = ((int)finalHeight).ToString();
            }
        }

        /// <summary>任一「分区高度」偏好的可输入上限 = 本屏工作区高 - 60（与 mac 同口径）。</summary>
        private double ClampHeight(double height)
        {
            var workArea = MonitorService.WorkingAreaDIP(MonitorService.ScreenOf(this), this);
            return PartitionMetrics.ClampedPartitionHeight(height, workArea.Height);
        }

        /// <summary>「分区最小高度」的可输入上限 = 本屏工作区高 - 60（与 mac 同口径）。</summary>
        private double ClampMinHeight(double height) => ClampHeight(height);

        private void MinHeightBox_LostFocus(object sender, RoutedEventArgs e)
        {
            if (double.TryParse(MinHeightBox.Text.Trim(), out double height))
            {
                double finalHeight = ClampMinHeight(height);
                _config.SetSetting("minPartitionHeight", finalHeight);
                MinHeightBox.Text = ((int)finalHeight).ToString();
            }
            else
            {
                MinHeightBox.Text = ((int)_config.MinPartitionHeight).ToString();
            }
        }

        private void MinHeightPreset_Click(object sender, RoutedEventArgs e)
        {
            if (sender is System.Windows.Controls.Button btn && btn.Tag is string tagStr && double.TryParse(tagStr, out double height))
            {
                double finalHeight = ClampMinHeight(height);
                _config.SetSetting("minPartitionHeight", finalHeight);
                MinHeightBox.Text = ((int)finalHeight).ToString();
            }
        }

        private void LoadDisplayInfo()
        {
            try
            {
                var screens = System.Windows.Forms.Screen.AllScreens;
                DisplaysCountText.Text = $"已连接 {screens.Length} 台显示器";
                var list = new System.Collections.Generic.List<DisplayItemViewModel>();
                for (int i = 0; i < screens.Length; i++)
                {
                    var s = screens[i];
                    string rawName = s.DeviceName.Replace(@"\\.\DISPLAY", "显示器 ");
                    list.Add(new DisplayItemViewModel
                    {
                        Name = string.IsNullOrWhiteSpace(rawName) ? $"显示器 {i + 1}" : rawName,
                        Resolution = $"{s.Bounds.Width} × {s.Bounds.Height} px",
                        PrimaryVisibility = s.Primary ? Visibility.Visible : Visibility.Collapsed
                    });
                }
                DisplaysItemsControl.ItemsSource = list;
            }
            catch
            {
                DisplaysCountText.Text = "显示器信息加载完成";
            }
        }

        public class DisplayItemViewModel
        {
            public string Name { get; set; } = string.Empty;
            public string Resolution { get; set; } = string.Empty;
            public Visibility PrimaryVisibility { get; set; } = Visibility.Collapsed;
        }

        // MARK: - 全局热键录制

        private void HotkeyBox_KeyDown(object sender, KeyEventArgs e)
            => CaptureHotkey(e, HotkeyBox, "globalShortcut", "显示 / 隐藏分区");

        private void SearchHotkeyBox_KeyDown(object sender, KeyEventArgs e)
            => CaptureHotkey(e, SearchHotkeyBox, "searchShortcut", "全局搜索");

        /// <summary>
        /// 录制一个全局热键。
        ///
        /// 两个必须处理的细节：
        /// 1. 按住 Alt 时 WPF 把 <c>e.Key</c> 报成 <c>Key.System</c>，真正的键在 <c>e.SystemKey</c>。
        ///    不特判就会录出 <c>"Alt+System"</c> —— 一个谁也注册不上的组合；
        /// 2. 录完**必须立刻重新注册**（<see cref="App.ApplyHotkeySettings"/>），
        ///    否则改的只是配置文件，真正生效的仍是启动时那一次注册 ——
        ///    这正是修复前的历史缺陷。
        /// </summary>
        private void CaptureHotkey(KeyEventArgs e, TextBox box, string settingKey, string label)
        {
            Key key = e.Key == Key.System ? e.SystemKey : e.Key;

            // 只按下了修饰键：继续等用户按到真正的键
            if (key is Key.LeftAlt or Key.RightAlt or Key.LeftCtrl or Key.RightCtrl
                or Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin
                or Key.System or Key.None)
            {
                return;
            }

            e.Handled = true;

            var mods = Keyboard.Modifiers;
            if (mods == ModifierKeys.None)
            {
                System.Windows.MessageBox.Show(
                    "全局快捷键至少要包含一个修饰键（Ctrl / Alt / Shift / Win）—— 否则它会连正常打字一起抢走。",
                    "提示", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            uint win32Mods = ToWin32Modifiers(mods);
            uint virtualKey = (uint)KeyInterop.VirtualKeyFromKey(key);
            string text = HotkeyParser.Describe(win32Mods, virtualKey);

            // 键名是**规范键**（mac 的 globalShortcut / searchShortcut）；
            // 对方那一个直接走 Config 的属性读 —— 它内部已经兼容 Windows 的旧键名，
            // 用 GetSetting 硬读规范键的话，老配置下会读到默认值、把一个不冲突的组合误报成冲突。
            bool editingToggle = settingKey == "globalShortcut";
            string otherLabel = editingToggle ? "全局搜索" : "显示 / 隐藏分区";
            string otherText = editingToggle ? _config.SearchHotkey : _config.GlobalHotkey;

            if (HotkeyParser.IsSameCombo(text, otherText))
            {
                // 同一组合只会投给先注册的那个，后注册的静默失效 —— 当场说清，别让用户以为设了没用
                System.Windows.MessageBox.Show(
                    $"「{label}」的快捷键 {text} 已被「{otherLabel}」占用，请换一个组合。",
                    "快捷键冲突", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            box.Text = text;
            _config.SetSetting(settingKey, text);

            (Application.Current as App)?.ApplyHotkeySettings();
        }

        private static uint ToWin32Modifiers(ModifierKeys mods)
        {
            uint result = 0;
            if (mods.HasFlag(ModifierKeys.Control)) result |= Win32.MOD_CONTROL;
            if (mods.HasFlag(ModifierKeys.Alt)) result |= Win32.MOD_ALT;
            if (mods.HasFlag(ModifierKeys.Shift)) result |= Win32.MOD_SHIFT;
            if (mods.HasFlag(ModifierKeys.Windows)) result |= Win32.MOD_WIN;
            return result;
        }

        // MARK: - 布局预设

        /// <summary>预设列表行的展示模型（列表只读展示，动作通过行上的按钮触发）。</summary>
        public sealed class PresetItemViewModel
        {
            public LayoutPreset Preset { get; init; } = new();
            public string Name { get; init; } = string.Empty;
            public string Summary { get; init; } = string.Empty;
        }

        private void RefreshPresets()
        {
            var presets = _config.GetLayoutPresets();
            var items = presets.Select(p => new PresetItemViewModel
            {
                Preset = p,
                Name = p.Name,
                Summary = $"{p.Entries.Count} 个分区 · {AlignLabel(p.AlignMode)} · {ScreenLabel(p.ScreenId)}"
            }).ToList();

            PresetsItemsControl.ItemsSource = items;
            PresetsEmptyText.Visibility = items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        }

        private void PresetSave_Click(object sender, RoutedEventArgs e)
        {
            var app = Application.Current as App;
            if (app == null) return;

            string name = PresetNameBox.Text.Trim();
            if (name.Length == 0)
            {
                // 空名不报错，改用能自解释的默认名 —— 这里的目的是「存下来」，不是考用户起名
                string sid = MonitorService.DeviceIdOf(MonitorService.ScreenUnderCursor());
                name = $"{AlignLabel(_config.AlignModeFor(sid))} · {DateTime.Now:MM-dd HH:mm}";
            }

            if (app.SaveLayoutPreset(name, out string error))
            {
                PresetNameBox.Text = string.Empty;
                RefreshPresets();
            }
            else
            {
                System.Windows.MessageBox.Show(error, "无法保存布局预设", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }

        private void PresetApply_Click(object sender, RoutedEventArgs e)
        {
            if (sender is not FrameworkElement elem || elem.DataContext is not PresetItemViewModel vm) return;
            (Application.Current as App)?.ApplyLayoutPreset(vm.Preset);
        }

        private void PresetDelete_Click(object sender, RoutedEventArgs e)
        {
            if (sender is not FrameworkElement elem || elem.DataContext is not PresetItemViewModel vm) return;

            (Application.Current as App)?.DeleteLayoutPreset(vm.Name);
            RefreshPresets();
        }

        // MARK: - 历史快照

        private void RefreshHistoryInfo()
        {
            var snapshots = _config.ListHistorySnapshots();
            if (snapshots.Count == 0)
            {
                HistoryInfoText.Text = "尚无快照 —— 下次配置变更时会自动留存一份";
                HistoryRestoreBtn.IsEnabled = false;
                return;
            }

            HistoryRestoreBtn.IsEnabled = true;
            HistoryInfoText.Text = $"已留存 {snapshots.Count} 份（上限 20 份）· 最近一份 {snapshots[0].Time:MM-dd HH:mm}";
        }

        private void HistoryRestore_Click(object sender, RoutedEventArgs e)
        {
            var snapshots = _config.ListHistorySnapshots();
            if (snapshots.Count == 0)
            {
                System.Windows.MessageBox.Show("还没有可恢复的历史快照。", "提示", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }

            var res = System.Windows.MessageBox.Show(
                $"将把配置恢复到最近一份快照（{snapshots[0].Time:yyyy-MM-dd HH:mm:ss}）的状态。\n" +
                "恢复前会先把当前配置也存成一份快照，因此这一步本身也可以再回滚。\n\n确定继续吗？",
                "恢复历史快照", MessageBoxButton.OKCancel, MessageBoxImage.Question);
            if (res != MessageBoxResult.OK) return;

            if (_config.RestoreHistorySnapshot(null, out string restored, out string error))
            {
                _onReloadRequested?.Invoke();
                RefreshHistoryInfo();
                RefreshPresets();
                System.Windows.MessageBox.Show($"已恢复到快照 {restored}。", "提示", MessageBoxButton.OK, MessageBoxImage.Information);
            }
            else
            {
                System.Windows.MessageBox.Show($"恢复失败：{error}", "错误", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }

        // MARK: - 系统常驻 / 交互

        private void StartupCheckBox_Click(object sender, RoutedEventArgs e)
        {
            bool enable = StartupCheckBox.IsChecked == true;
            StartupService.SetLaunchAtStartup(enable);
            _config.SetSetting("launchAtLogin", enable);
        }

        private void SnappingCheckBox_Click(object sender, RoutedEventArgs e)
        {
            // 规范键名 = mac 的 snapToEdges（旧名 edgeSnapping 由读取器兼容）
            _config.SetSetting("snapToEdges", SnappingCheckBox.IsChecked == true);
        }

        /// <summary>
        /// 「折叠分区悬停展开」开关 —— 对齐 mac 基线的 <c>hoverPeekCollapsed</c>。
        /// 分区窗口一直在读这个键，但此前 Windows 端没有任何入口能改它。
        /// </summary>
        private void HoverPeekCheckBox_Click(object sender, RoutedEventArgs e)
        {
            // 规范键名 = mac 的 hoverPeekCollapsed（旧名 hoverPreview 由读取器兼容）
            _config.SetSetting("hoverPeekCollapsed", HoverPeekCheckBox.IsChecked == true);
        }

        // MARK: - 导入导出

        private void ExportConfig_Click(object sender, RoutedEventArgs e)
        {
            var sfd = new Microsoft.Win32.SaveFileDialog
            {
                Filter = "JSON 文件 (*.json)|*.json",
                FileName = $"deskisle_backup_{DateTime.Now:yyyy-MM-dd}.json",
                Title = "导出配置备份"
            };

            if (sfd.ShowDialog(this) == true)
            {
                try
                {
                    string json = _config.Raw.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
                    File.WriteAllText(sfd.FileName, json);
                    System.Windows.MessageBox.Show("配置备份导出成功！", "提示", MessageBoxButton.OK, MessageBoxImage.Information);
                }
                catch (Exception ex)
                {
                    System.Windows.MessageBox.Show($"导出失败: {ex.Message}", "错误", MessageBoxButton.OK, MessageBoxImage.Error);
                }
            }
        }

        private void ImportConfig_Click(object sender, RoutedEventArgs e)
        {
            var ofd = new Microsoft.Win32.OpenFileDialog
            {
                Filter = "JSON 文件 (*.json)|*.json",
                Title = "导入配置备份"
            };

            if (ofd.ShowDialog(this) == true)
            {
                try
                {
                    string json = File.ReadAllText(ofd.FileName);
                    var node = JsonNode.Parse(json);
                    if (node is JsonObject obj && obj.ContainsKey("partitions"))
                    {
                        var res = System.Windows.MessageBox.Show(
                            "导入新配置将覆盖当前桌面分区布局，确定继续吗？",
                            "确认导入", MessageBoxButton.OKCancel, MessageBoxImage.Question);
                        if (res == MessageBoxResult.OK)
                        {
                            string appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
                            string configPath = Path.Combine(appData, "DeskIsle", "deskisle_config.json");
                            // 覆盖前先留一份快照 —— 导入是最容易「一次毁掉整套摆法」的操作
                            _config.PushHistorySnapshot(force: true);
                            File.WriteAllText(configPath, json);
                            _config.Load();
                            _onReloadRequested?.Invoke();
                            RefreshPresets();
                            RefreshHistoryInfo();
                            System.Windows.MessageBox.Show("配置已成功导入并生效！", "提示", MessageBoxButton.OK, MessageBoxImage.Information);
                        }
                    }
                    else
                    {
                        System.Windows.MessageBox.Show("无效的 DeskIsle 配置文件格式！", "警告", MessageBoxButton.OK, MessageBoxImage.Warning);
                    }
                }
                catch (Exception ex)
                {
                    System.Windows.MessageBox.Show($"导入失败: {ex.Message}", "错误", MessageBoxButton.OK, MessageBoxImage.Error);
                }
            }
        }

        private void Done_Click(object sender, RoutedEventArgs e)
        {
            Close();
        }

        // MARK: - 小工具

        private static string AlignLabel(string? mode) => mode switch
        {
            "left" => "左侧纵向",
            "right" => "右侧纵向",
            "grid" => "网格平铺",
            _ => "顶部横向"
        };

        private static string ScreenLabel(string? screenId)
        {
            if (string.IsNullOrEmpty(screenId)) return "未知显示器";
            return screenId!.Replace(@"\\.\", string.Empty);
        }
    }
}
