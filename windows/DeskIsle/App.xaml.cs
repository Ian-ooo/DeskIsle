using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows;
using System.Windows.Forms;
using System.Windows.Interop;
using System.Windows.Threading;
using DeskIsle.Models;
using DeskIsle.Native;
using DeskIsle.Services;
using DeskIsle.Views;
using Application = System.Windows.Application;

namespace DeskIsle
{
    public partial class App : Application
    {
        private Mutex? _singleInstanceMutex;
        private Config _config = null!;
        private readonly List<PartitionWindow> _partitionWindows = new();
        /// <summary>
        /// 每台显示器一个顶栏（键 = 显示器 DeviceName）。
        /// 多显示器下各屏顶栏只控制本屏分区（显隐 / 对齐 / 新建），互不干扰。
        /// </summary>
        private readonly Dictionary<string, TopBarWindow> _topBarWindows = new();
        private NotifyIcon? _notifyIcon;
        private ContextMenuStrip? _trayMenu;
        private ToolStripMenuItem? _presetMenu;
        private ToolStripMenuItem? _searchMenuItem;
        /// <summary>
        /// 托盘里的「锁定本屏分区位置」。
        /// 保留引用是因为它要显示**勾选态**：顶栏那枚锁定按钮已于 2026-09-30 移除，
        /// 托盘成了唯一入口，若这里也不打勾，用户只能靠「试着拖一下、发现拖不动」
        /// 来反推自己锁没锁 —— 纯负反馈。菜单每次打开都按当前配置重新同步。
        /// </summary>
        private ToolStripMenuItem? _lockMenuItem;
        /// <summary>「分区排版对齐」子菜单里的四个模式项，键 = 模式名（top/left/right/grid）。</summary>
        private readonly Dictionary<string, ToolStripMenuItem> _alignModeItems = new();
        private HotKeyManager? _hotKeyManager;
        /// <summary>承载全局热键的专用消息窗口（**不是**某个顶栏，见 <see cref="InitHotKey"/>）。</summary>
        private HwndSource? _hotkeySource;

        protected override void OnStartup(StartupEventArgs e)
        {
            const string mutexName = "DeskIsle_SingleInstance_Mutex_x64";
            _singleInstanceMutex = new Mutex(true, mutexName, out bool createdNew);
            if (!createdNew)
            {
                System.Windows.MessageBox.Show("DeskIsle 桌岛 已在运行中。", "提示", MessageBoxButton.OK, MessageBoxImage.Information);
                Shutdown();
                return;
            }

            base.OnStartup(e);

            _config = new Config();
            _config.OnConfigChanged += OnConfigUpdated;

            InitSystemTray();
            InitWindows();
            InitHotKey();


            // 显示器插拔 / 分辨率变化：清理失效的按屏状态并重建顶栏（每屏一个）
            Microsoft.Win32.SystemEvents.DisplaySettingsChanged += OnDisplaySettingsChanged;
            Microsoft.Win32.SystemEvents.PowerModeChanged += OnPowerModeChanged;
        }

        private void OnPowerModeChanged(object? sender, Microsoft.Win32.PowerModeChangedEventArgs e)
        {
            if (e.Mode == Microsoft.Win32.PowerModes.Suspend)
            {
                // 系统休眠：修剪全局搜索目录缓存，并主动回收工作集内存
                GlobalSearchWindow.InvalidateDirectoryCache();
                try
                {
                    GC.Collect(2, GCCollectionMode.Forced, false);
                    GC.WaitForPendingFinalizers();
                }
                catch { }
            }
        }

        /// <summary>
        /// 显示器集合变化后：清理已拔掉显示器的隐藏态，并按新集合重建顶栏，
        /// 保证每块屏有且只有一个顶栏。
        /// </summary>
        private void OnDisplaySettingsChanged(object? sender, EventArgs e)
        {
            Dispatcher.Invoke(() =>
            {
                var alive = MonitorService.AliveDeviceIds();
                _config.PruneHiddenScreens(alive);
                _config.PruneScreenSettings(alive);
                EnsurePartitionsInBounds();
                RebuildTopBars();
                UpdateAllTopBars();
            });
        }

        /// <summary>
        /// 分辨率/显示器断开变化后，把跑到屏幕外的分区弹性拉回来（只纠正越界，不动正常分区）。
        /// </summary>
        private void EnsurePartitionsInBounds()
        {
            var alive = MonitorService.AliveDeviceIds();
            var primaryScreen = MonitorService.PrimaryScreen();
            string primaryId = MonitorService.DeviceIdOf(primaryScreen);

            foreach (var win in _partitionWindows)
            {
                var model = win.Model;
                // 若分区所属的显示器已被拔掉/不存在，迁移到主屏
                if (string.IsNullOrEmpty(model.ScreenId) || !alive.Contains(model.ScreenId))
                {
                    model.ScreenId = primaryId;
                }

                var screen = MonitorService.ScreenFromDeviceId(model.ScreenId) ?? primaryScreen;
                Rect workArea;
                try { workArea = MonitorService.WorkingAreaDIP(screen, win); }
                catch { workArea = SystemParameters.WorkArea; }

                const double margin = 16.0;
                double topMargin = 72.0; // 顶栏避让区
                double w = model.Width > 0 ? model.Width : 260;
                double h = model.IsCollapsed ? 44 : (model.Height > 0 ? model.Height : 300);

                double minX = workArea.Left + margin;
                double maxX = workArea.Right - w - margin;
                double minY = workArea.Top + topMargin;
                double maxY = workArea.Bottom - h - margin;

                double curX = win.Left;
                double curY = win.Top;

                // 越界检查与弹性纠偏
                double newX = curX;
                double newY = curY;

                if (maxX >= minX)
                {
                    newX = Math.Min(Math.Max(curX, minX), maxX);
                }
                else
                {
                    newX = minX;
                }

                if (maxY >= minY)
                {
                    newY = Math.Min(Math.Max(curY, minY), maxY);
                }
                else
                {
                    newY = minY;
                }

                if (Math.Abs(newX - curX) > 1.0 || Math.Abs(newY - curY) > 1.0)
                {
                    win.Left = newX;
                    win.Top = newY;
                    model.X = (int)Math.Round(newX);
                    model.Y = (int)Math.Round(newY);
                }
            }

            _config.SaveSoon();
        }

        // MARK: - 托盘

        private void InitSystemTray()
        {
            _notifyIcon = new NotifyIcon
            {
                Text = "DeskIsle 桌岛",
                Visible = true,
                Icon = LoadAppIcon()
            };

            _trayMenu = new ContextMenuStrip();
            // 菜单每次打开都刷新勾选态：锁定可以在多处改变（托盘、分区设置），
            // 而且它是**按屏**的 —— 光标移到另一块屏后，同一个菜单项的含义就变了。
            _trayMenu.Opening += (_, _) => SyncTrayMenuState();
            BuildTrayMenu();
            _notifyIcon.ContextMenuStrip = _trayMenu;
            _notifyIcon.DoubleClick += (_, _) => ToggleGhostMode();
        }

        private static Icon LoadAppIcon()
        {
            string iconPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Resources", "app.ico");
            try
            {
                if (File.Exists(iconPath)) return new Icon(iconPath);
            }
            catch
            {
                // 图标读取失败不该阻止程序启动
            }
            return SystemIcons.Application;
        }

        /// <summary>
        /// 托盘菜单每次打开前的状态同步。
        /// 锁定项打勾与否取决于**光标所在屏**（多屏独立），所以只能在打开那一刻算 ——
        /// 构建菜单时算一次是不够的：用户换个屏再点开，同一个菜单项该反映另一块屏。
        /// </summary>
        private void SyncTrayMenuState()
        {
            if (_lockMenuItem == null) return;
            var screen = MonitorService.ScreenUnderCursor();
            _lockMenuItem.Checked = _config.IsScreenLocked(MonitorService.DeviceIdOf(screen));
        }

        /// <summary>重建托盘菜单。新增托盘项时**只改这一处**，不必到处找菜单定义。</summary>
        private void BuildTrayMenu()
        {
            if (_trayMenu == null) return;
            _trayMenu.Items.Clear();

            _trayMenu.Items.Add(new ToolStripMenuItem("🏝️ DeskIsle 桌岛") { Enabled = false });
            _trayMenu.Items.Add(new ToolStripSeparator());

            _trayMenu.Items.Add(new ToolStripMenuItem("➕ 新建分区...", null, (_, _) => OpenNewPartitionDialog()));

            // 全局搜索：托盘入口 + 显示当前快捷键（真正注册走 RegisterHotKey，
            // 这里只是把组合显示出来，让用户知道有这个东西可点）
            _searchMenuItem = new ToolStripMenuItem("🔍 全局搜索...", null, (_, _) => OpenGlobalSearch())
            {
                ShortcutKeyDisplayString = _config.SearchHotkey
            };
            _trayMenu.Items.Add(_searchMenuItem);

            _trayMenu.Items.Add(new ToolStripSeparator());

            // 显隐只作用于「光标所在显示器」上的分区（多屏下每屏独立控制）
            _trayMenu.Items.Add(new ToolStripMenuItem("👁️ 显示/隐藏本屏分区", null, (_, _) => ToggleGhostMode()));

            // 锁定是**状态型**开关 ⇒ 打勾，且用 CheckOnClick=false：勾选态由配置决定，
            // 不能让 WinForms 自己翻（它不知道「按屏」这回事，光标换块屏就对不上了）。
            _lockMenuItem = new ToolStripMenuItem("🔒 锁定本屏分区位置", null, (_, _) => ToggleScreenLock())
            {
                CheckOnClick = false
            };
            _trayMenu.Items.Add(_lockMenuItem);

            var alignMenu = new ToolStripMenuItem("📐 分区排版对齐");
            _alignModeItems.Clear();
            foreach (var (mode, label) in new[]
                     {
                         ("top", "顶部横向排序"), ("left", "左侧纵向对齐"),
                         ("right", "右侧纵向对齐"), ("grid", "网格平铺自适应")
                     })
            {
                var m = mode;
                var mi = new ToolStripMenuItem(label, null, (_, _) => AlignPartitions(m));
                _alignModeItems[m] = mi;
                alignMenu.DropDownItems.Add(mi);
            }
            alignMenu.DropDownOpening += (_, _) => RefreshAlignMenuChecks();
            alignMenu.DropDownItems.Add(new ToolStripSeparator());
            // 执行型两项：点后正常收起菜单
            alignMenu.DropDownItems.Add(new ToolStripMenuItem("重新对齐分区", null, (_, _) => RealignPartitions()));
            alignMenu.DropDownItems.Add(new ToolStripMenuItem("所有分区自适应高度", null, (_, _) => AutoFitAllPartitions()));
            _trayMenu.Items.Add(alignMenu);

            // 布局预设：内容随配置变化，每次下拉时重建（见 RefreshPresetMenu）
            _presetMenu = new ToolStripMenuItem("🗂️ 布局预设");
            _presetMenu.DropDownOpening += (_, _) => RefreshPresetMenu();
            RefreshPresetMenu();
            _trayMenu.Items.Add(_presetMenu);

            _trayMenu.Items.Add(new ToolStripSeparator());
            _trayMenu.Items.Add(new ToolStripMenuItem("🧭 显示顶部导航栏", null, (_, _) => ToggleTopBarVisibility()));
            _trayMenu.Items.Add(new ToolStripSeparator());
            _trayMenu.Items.Add(new ToolStripMenuItem("⚙️ 全局设置与备份...", null, (_, _) => OpenSettingsDialog()));
            _trayMenu.Items.Add(new ToolStripSeparator());
            _trayMenu.Items.Add(new ToolStripMenuItem("⏻ 退出 DeskIsle", null, (_, _) => QuitApp()));
        }

        /// <summary>
        /// 重建「布局预设」子菜单。
        /// 在每次下拉时重建，而不是在保存/删除后手动刷新 —— 前者只有一处代码，
        /// 不会出现「在设置面板里加了预设、托盘里却没有」这种不一致。
        /// </summary>
        private void RefreshPresetMenu()
        {
            if (_presetMenu == null) return;
            _presetMenu.DropDownItems.Clear();

            var presets = _config.GetLayoutPresets();
            var cursorScreen = MonitorService.DeviceIdOf(MonitorService.ScreenUnderCursor());

            if (presets.Count == 0)
            {
                _presetMenu.DropDownItems.Add(new ToolStripMenuItem("（尚无预设）") { Enabled = false });
            }
            else
            {
                foreach (var preset in presets)
                {
                    var captured = preset;
                    bool sameScreen = captured.ScreenId == cursorScreen;
                    var item = new ToolStripMenuItem($"应用：{captured.Name}", null, (_, _) => ApplyLayoutPreset(captured));
                    item.ToolTipText = sameScreen
                        ? $"恢复到保存时的位置与尺寸（{captured.Entries.Count} 个分区）"
                        : "该预设属于另一块显示器，应用后会夹回本屏可视范围";
                    _presetMenu.DropDownItems.Add(item);
                }
            }

            _presetMenu.DropDownItems.Add(new ToolStripSeparator());
            _presetMenu.DropDownItems.Add(new ToolStripMenuItem("💾 保存当前布局为预设...", null, (_, _) => SaveLayoutPresetInteractive()));

            if (presets.Count > 0)
            {
                var deleteMenu = new ToolStripMenuItem("🗑️ 删除预设");
                foreach (var preset in presets)
                {
                    var captured = preset;
                    deleteMenu.DropDownItems.Add(new ToolStripMenuItem(captured.Name, null, (_, _) => DeleteLayoutPreset(captured.Name)));
                }
                _presetMenu.DropDownItems.Add(deleteMenu);
            }
        }

        private void UpdateSearchShortcutDisplay()
        {
            if (_searchMenuItem != null) _searchMenuItem.ShortcutKeyDisplayString = _config.SearchHotkey;
        }

        /// <summary>
        /// 给四个对齐模式项打 ✓（与 mac 托盘一致：当前模式那一项显示勾选）。
        /// 勾的是**光标所在屏**的模式 —— 每屏各自一套，多屏下光看勾也能知道这块屏用的哪种。
        /// </summary>
        private void RefreshAlignMenuChecks()
        {
            if (_alignModeItems.Count == 0) return;
            var sid = MonitorService.DeviceIdOf(MonitorService.ScreenUnderCursor());
            var cur = _config.AlignModeFor(sid);
            foreach (var kv in _alignModeItems)
            {
                kv.Value.Checked = string.Equals(kv.Key, cur, StringComparison.OrdinalIgnoreCase);
            }
        }

        // MARK: - 窗口构建

        private void InitWindows()
        {
            // 1. 初始化顶部导航栏 —— 每台显示器一个
            RebuildTopBars();

            // 2. 初始化各分区窗口
            RebuildPartitionWindows();

            // 3. 「全屏应用前置时让位」守卫（Windows 特有：没有 Space 概念，Topmost 窗口会盖住全屏应用）
            _fullScreenGuard = new FullScreenGuard(
                isScreenHidden: sid => _config.IsScreenHidden(sid),
                setPartitionsVisible: SetPartitionsVisibleForScreen);
            _fullScreenGuard.Start();
        }

        private FullScreenGuard? _fullScreenGuard;

        /// <summary>
        /// 淡入 / 淡出某一屏的分区（供全屏守卫调用，与「手动显隐」走同一套动画）。
        /// </summary>
        private void SetPartitionsVisibleForScreen(string screenId, bool visible)
        {
            foreach (var win in _partitionWindows)
            {
                if (win.ScreenId != screenId) continue;
                if (visible) win.FadeIn(120);
                else win.FadeOut(120);
            }
        }

        /// <summary>
        /// 按当前显示器集合重建顶栏：每屏一个实例，各顶栏只控制本屏分区。
        /// 顶栏回调统一按「该顶栏所属显示器」路由。
        /// </summary>
        private void RebuildTopBars()
        {
            foreach (var tb in _topBarWindows.Values)
            {
                tb.Close();
            }
            _topBarWindows.Clear();

            foreach (var screen in MonitorService.AllScreens())
            {
                var sid = MonitorService.DeviceIdOf(screen);
                // 每块显示器按**自己的**显隐设置决定是否创建顶栏
                if (!_config.ShowTopBarFor(sid)) continue;
                var bar = CreateTopBar(screen);
                bar.Show();
                _topBarWindows[sid] = bar;
            }
        }

        /// <summary>为指定显示器创建一个顶栏，回调统一按「该顶栏所属显示器」路由。</summary>
        private TopBarWindow CreateTopBar(System.Windows.Forms.Screen screen)
        {
            return new TopBarWindow(
                screen,
                _config,
                onNewPartition: () => OpenNewPartitionDialog(screen),
                onToggleGhost: () => ToggleGhostMode(screen),
                onAlign: mode => AlignPartitions(mode, screen),
                onOpenSettings: OpenSettingsDialog,
                onHideTopBar: () => SetTopBarVisibility(false, screen),
                onQuit: QuitApp
            );
        }

        private void RebuildPartitionWindows()
        {
            foreach (var win in _partitionWindows)
            {
                win.Close();
            }
            _partitionWindows.Clear();

            foreach (var model in _config.Partitions)
            {
                var win = new PartitionWindow(model, _config);
                // 先建立窗口句柄，才能查到它落在哪块显示器上（未显示时按 Left/Top 判定所在屏）
                _ = new WindowInteropHelper(win).EnsureHandle();
                // 旧配置迁移：缺少所属显示器时按当前位置补上
                if (string.IsNullOrEmpty(model.ScreenId))
                {
                    model.ScreenId = MonitorService.DeviceIdOf(win.CurrentScreen);
                }
                _partitionWindows.Add(win);
                // 按分区所在显示器的显隐态决定是否显示（多屏下每屏独立）
                if (!_config.IsScreenHidden(win.ScreenId))
                {
                    win.Show();
                }
            }
            RefreshPartitionChrome();
        }

        /// <summary>刷新所有显示器上的顶栏状态（显隐 / 锁定 / 对齐高亮）。</summary>
        private void UpdateAllTopBars()
        {
            foreach (var tb in _topBarWindows.Values) tb.UpdateState();
        }

        /// <summary>刷新所有分区窗口的标题栏（锁定压暗 / 标题 / 折叠态）。</summary>
        private void RefreshPartitionChrome()
        {
            foreach (var win in _partitionWindows) win.RefreshChrome();
        }

        // MARK: - 全局热键

        /// <summary>
        /// 初始化全局热键。
        ///
        /// **关键点：不复用某块屏的顶栏作为消息窗口。**
        /// 顶栏会在「显示器插拔 / 分辨率变化」时被整批关闭重建，
        /// 挂在它上面的热键会随窗口句柄一起失效 —— 现象就是
        /// 「改完分辨率后，快捷键再也没反应了」，而且没有任何报错。
        /// 这里专门造一个不可见的 1×1 消息窗口，生命周期与进程一致。
        /// </summary>
        private void InitHotKey()
        {
            _hotkeySource = CreateHotkeySource();
            if (_hotkeySource == null)
            {
                System.Diagnostics.Debug.WriteLine("[DeskIsle] 无法创建热键消息窗口，全局快捷键不可用");
                return;
            }

            _hotKeyManager = new HotKeyManager();
            _hotKeyManager.Initialize(_hotkeySource);

            // 槽位分派：与 mac 端 EventHotKeyID.id = 1 / 2 一一对应。
            // 新增热键必须用新槽位 id 并在 HotKeyManager 里加分支，
            // 否则两个热键会互相顶掉（同一个 id 只有一个注册生效）。
            _hotKeyManager.SetCallback(HotKeyManager.SlotToggleHide,
                () => Dispatcher.Invoke(new Action(() => ToggleGhostMode())));
            _hotKeyManager.SetCallback(HotKeyManager.SlotGlobalSearch,
                () => Dispatcher.Invoke(new Action(OpenGlobalSearch)));

            ApplyHotkeySettings();
        }

        private HwndSource? CreateHotkeySource()
        {
            try
            {
                var parameters = new HwndSourceParameters("DeskIsleHotkeySink")
                {
                    PositionX = -4000,
                    PositionY = -4000,
                    Width = 1,
                    Height = 1,
                    WindowStyle = Win32.WS_POPUP,
                    ExtendedWindowStyle = Win32.WS_EX_TOOLWINDOW | Win32.WS_EX_NOACTIVATE
                };
                return new HwndSource(parameters);
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"[DeskIsle] HwndSource 创建失败：{ex.Message}");
            }

            // 退路：借用任意一个已存在的顶栏窗口（旧实现的做法）。
            // 它有「顶栏重建后失效」的毛病，但总好过快捷键完全不可用。
            var bar = _topBarWindows.Values.FirstOrDefault();
            if (bar == null) return null;
            var handle = new WindowInteropHelper(bar).EnsureHandle();
            return HwndSource.FromHwnd(handle);
        }

        /// <summary>
        /// 按配置重新注册两个全局热键。
        /// 设置面板里改完快捷键后必须调用它 —— 否则改的只是配置文件，
        /// 实际生效的仍是启动时那一次注册（这正是修复前的历史缺陷）。
        /// </summary>
        public void ApplyHotkeySettings()
        {
            if (_hotKeyManager == null) return;

            RegisterHotkeySlot(HotKeyManager.SlotToggleHide, _config.GlobalHotkey, "显示 / 隐藏分区");
            RegisterHotkeySlot(HotKeyManager.SlotGlobalSearch, _config.SearchHotkey, "全局搜索");
            UpdateSearchShortcutDisplay();
        }

        private void RegisterHotkeySlot(int slot, string text, string label)
        {
            if (_hotKeyManager == null) return;

            string other = slot == HotKeyManager.SlotToggleHide ? _config.SearchHotkey : _config.GlobalHotkey;
            if (HotkeyParser.IsSameCombo(text, other))
            {
                // 同一个组合只会投给先注册的那个，后注册的静默失效 ——
                // 与其让用户以为「设了没用」，不如当场说清。
                ToastWindow.ShowToast($"{label}热键与另一个热键重复：{text}",
                    "请到「全局设置 → 热键与交互」改成不同的组合", warn: true, durationMs: 2800);
                return;
            }

            if (!HotkeyParser.TryParse(text, out uint modifiers, out uint virtualKey))
            {
                ToastWindow.ShowToast($"{label}热键「{text}」无法识别",
                    "请到「全局设置 → 热键与交互」重新录制（至少要带一个修饰键）", warn: true, durationMs: 2800);
                return;
            }

            if (!_hotKeyManager.Register(slot, modifiers, virtualKey))
            {
                ToastWindow.ShowToast($"{label}热键 {HotkeyParser.Describe(modifiers, virtualKey)} 注册失败",
                    "该组合可能已被其他程序占用，请换一个", warn: true, durationMs: 2800);
            }
        }

        // MARK: - 全局搜索

        /// <summary>打开全局搜索面板（顶栏按钮 / 托盘菜单 / 全局热键三个入口共用）。</summary>
        public void OpenGlobalSearch()
        {
            GlobalSearchWindow.Open(_config, RevealPartition);
        }

        /// <summary>把某个分区窗口唤到最前（搜索结果的「待办 / 便签」条目用）。</summary>
        public void RevealPartition(string partitionId)
        {
            var win = _partitionWindows.FirstOrDefault(w => w.Model.Id == partitionId);
            if (win == null) return;
            if (!win.IsVisible) win.Show();
            win.ActivateAsNormalWindow();
            win.Activate();
        }

        // MARK: - 布局预设

        private void SaveLayoutPresetInteractive()
        {
            var screen = MonitorService.ScreenUnderCursor();
            var sid = MonitorService.DeviceIdOf(screen);
            int count = _partitionWindows.Count(w => w.ScreenId == sid);

            if (count == 0)
            {
                ToastWindow.ShowToast("本屏还没有分区，无法保存布局预设",
                    "先把光标移到有分区的那块屏，或新建一个分区", warn: false);
                return;
            }

            string defaultName = $"{AlignModeLabel(_config.AlignModeFor(sid))} · {DateTime.Now:MM-dd HH:mm}";
            string? input = TextPromptDialog.Prompt(
                "保存布局预设",
                $"把本屏 {count} 个分区的位置与尺寸存成一份命名快照（同名会覆盖）",
                defaultName,
                "保存");

            if (string.IsNullOrWhiteSpace(input)) return;
            string name = input!.Trim();

            if (SaveLayoutPreset(name, out string error))
            {
                ToastWindow.ShowToast($"已保存布局预设「{name}」", $"{count} 个分区的位置与尺寸已记录", warn: false);
            }
            else
            {
                ToastWindow.ShowToast("保存布局预设失败", error);
            }
        }

        /// <summary>
        /// 把「光标所在屏」上分区的当前布局存成命名预设（同名覆盖）。
        /// 设置面板与托盘菜单共用此入口 —— 命名方式不同，落盘逻辑只此一处。
        /// </summary>
        public bool SaveLayoutPreset(string name, out string error)
        {
            error = string.Empty;
            name = (name ?? string.Empty).Trim();
            if (name.Length == 0)
            {
                error = "预设名称不能为空";
                return false;
            }

            string sid = MonitorService.DeviceIdOf(MonitorService.ScreenUnderCursor());
            var wins = _partitionWindows.Where(w => w.ScreenId == sid).ToList();
            if (wins.Count == 0)
            {
                error = "本屏还没有分区，无法保存布局预设";
                return false;
            }

            var presets = _config.GetLayoutPresets();
            presets.RemoveAll(p => string.Equals(p.Name, name, StringComparison.OrdinalIgnoreCase));
            presets.Add(new LayoutPreset
            {
                Name = name,
                ScreenId = sid,
                AlignMode = _config.AlignModeFor(sid),
                SavedAtMs = DateTimeOffset.Now.ToUnixTimeMilliseconds(),
                Entries = wins.Select(w => new LayoutPresetEntry
                {
                    Id = w.Model.Id,
                    X = w.Model.X,
                    Y = w.Model.Y,
                    Width = w.Model.Width,
                    Height = w.Model.Height
                }).ToList()
            });
            _config.SetLayoutPresets(presets);
            return true;
        }

        /// <summary>应用布局预设：只动**没被锁定**的分区，并把它夹回可视范围。</summary>
        public void ApplyLayoutPreset(LayoutPreset preset)
        {
            if (preset == null || preset.Entries.Count == 0) return;

            // 优先用预设自己所属的那块屏（同屏恢复才是原意）；
            // 那块屏已经不在了才退到光标所在屏。
            var targetScreen = MonitorService.AllScreens()
                                    .FirstOrDefault(s => MonitorService.DeviceIdOf(s) == preset.ScreenId)
                                ?? MonitorService.ScreenUnderCursor();
            string targetSid = MonitorService.DeviceIdOf(targetScreen);

            // 取一个目标屏上的窗口做 DPI 换算参考（多屏缩放不同）
            System.Windows.Media.Visual? reference = null;
            foreach (var w in _partitionWindows)
            {
                if (w.ScreenId == targetSid) { reference = w; break; }
            }
            if (reference == null) reference = _partitionWindows.FirstOrDefault();
            if (reference == null) reference = _topBarWindows.Values.FirstOrDefault();

            var workArea = MonitorService.WorkingAreaDIP(targetScreen, reference);

            _config.SetAlignModeFor(targetSid, preset.AlignMode);

            int applied = 0, skippedLocked = 0, missing = 0;
            foreach (var entry in preset.Entries)
            {
                var win = _partitionWindows.FirstOrDefault(w => w.Model.Id == entry.Id);
                if (win == null) { missing++; continue; }
                if (win.IsLockedHere) { skippedLocked++; continue; }

                double w = Math.Max(160.0, entry.Width);
                double h = Math.Max(140.0, entry.Height);
                // 预设属于别的屏、或屏幕布局变过时，原坐标可能落在屏外 —— 一律夹回来，
                // 否则「点了应用之后分区不见了」是最容易把人吓到的一类体验。
                double x = Clamp(entry.X, workArea.Left, Math.Max(workArea.Left, workArea.Right - w));
                double y = Clamp(entry.Y, workArea.Top, Math.Max(workArea.Top, workArea.Bottom - h));

                win.ApplyPresetGeometry(x, y, w, h);
                applied++;
            }

            _config.Save();
            RefreshPartitionChrome();
            UpdateAllTopBars();

            var parts = new List<string> { $"已应用预设「{preset.Name}」({applied} 个分区)" };
            if (skippedLocked > 0) parts.Add($"{skippedLocked} 个因锁定跳过");
            if (missing > 0) parts.Add($"{missing} 个分区已不存在");
            ToastWindow.ShowToast(string.Join("，", parts), null, warn: skippedLocked > 0);
        }

        public void DeleteLayoutPreset(string name)
        {
            var presets = _config.GetLayoutPresets();
            int removed = presets.RemoveAll(p => string.Equals(p.Name, name, StringComparison.OrdinalIgnoreCase));
            if (removed == 0) return;

            _config.SetLayoutPresets(presets);
            ToastWindow.ShowToast($"已删除布局预设「{name}」", null, warn: false);
        }

        private static string AlignModeLabel(string? mode) => mode switch
        {
            "left" => "左侧",
            "right" => "右侧",
            "grid" => "网格",
            _ => "顶部"
        };

        private static double Clamp(double value, double min, double max) =>
            value < min ? min : (value > max ? max : value);

        // MARK: - 新建 / 设置

        /// <summary>
        /// 新建分区。分区会创建在**触发操作的显示器**上（默认 = 光标所在屏），
        /// 并只重排该屏布局，其他显示器不受影响。
        /// </summary>
        public void OpenNewPartitionDialog(System.Windows.Forms.Screen? target = null)
        {
            var screen = target ?? MonitorService.ScreenUnderCursor();
            var sid = MonitorService.DeviceIdOf(screen);

            // 取一个已在目标屏上的窗口做 DPI 换算参考（多屏缩放不同）
            System.Windows.Media.Visual? anchor = _partitionWindows.FirstOrDefault(w => w.ScreenId == sid);
            if (anchor == null && _topBarWindows.Count > 0) anchor = _topBarWindows.Values.First();

            var workArea = MonitorService.WorkingAreaDIP(screen, anchor);

            var dlg = new NewPartitionDialog(_config);
            if (dlg.ShowDialog() == true && dlg.ResultPartition != null)
            {
                var model = dlg.ResultPartition;

                // 初始位置给一个安全起点（与排版基准同口径），随后立即按当前排版模式重排
                model.X = workArea.Left + LayoutEngine.Margin;
                model.Y = workArea.Top + (_config.ShowTopBarFor(sid) ? 76.0 : 24.0);
                // 记录所属显示器：重启后仍归到这块屏（按屏对齐 / 按屏显隐）
                model.ScreenId = sid;

                _config.Partitions.Add(model);
                _config.Save();

                var win = new PartitionWindow(model, _config);
                _partitionWindows.Add(win);
                win.Show();

                // 与 macOS / Electron 一致：新建后立即按当前对齐模式重排，
                // 但**只重排该分区所在的那块屏**。
                AlignPartitions(_config.AlignMode, MonitorService.ScreenOf(win));
                win.RefreshChrome();
                GlobalSearchWindow.InvalidateDirectoryCache();
            }
        }

        public void OpenSettingsDialog()
        {
            var dlg = new SettingsDialog(_config, () =>
            {
                RebuildPartitionWindows();
                UpdateAllTopBars();
                ApplyHotkeySettings();
                GlobalSearchWindow.InvalidateDirectoryCache();
            });
            dlg.ShowDialog();

            // 设置面板里可能加了 / 删了布局预设，托盘菜单下次下拉时会自行重建，
            // 这里只需刷新「全局搜索」的快捷键显示。
            UpdateSearchShortcutDisplay();
        }

        // MARK: - 显隐 / 锁定 / 顶栏 / 对齐

        /// <summary>
        /// 「显示 / 隐藏分区」：只作用于**指定显示器**上的分区（默认 = 光标所在屏）。
        /// 多屏下每屏独立控制，互不影响。
        /// </summary>
        public void ToggleGhostMode(System.Windows.Forms.Screen? target = null)
        {
            var screen = target ?? MonitorService.ScreenUnderCursor();
            var sid = MonitorService.DeviceIdOf(screen);
            _config.ToggleScreenHidden(sid);
            bool hidden = _config.IsScreenHidden(sid);

            foreach (var win in _partitionWindows)
            {
                if (win.ScreenId != sid) continue;   // 只处理本屏分区
                if (hidden) win.FadeOut(120);
                else win.FadeIn(120);
            }
            _topBarWindows.TryGetValue(sid, out var bar);
            bar?.UpdateState();
        }

        /// <summary>
        /// 「锁定分区位置」：只作用于**指定显示器**上的分区（默认 = 光标所在屏）。
        /// 多显示器下每屏独立锁定，互不影响。
        /// </summary>
        public void ToggleScreenLock(System.Windows.Forms.Screen? target = null)
        {
            var screen = target ?? MonitorService.ScreenUnderCursor();
            var sid = MonitorService.DeviceIdOf(screen);
            bool locked = !_config.IsScreenLocked(sid);
            _config.SetScreenLocked(sid, locked);

            // 屏幕锁定改变了所有分区的可动状态 → 标题栏的压暗与提示语都要跟着变
            RefreshPartitionChrome();
            UpdateAllTopBars();
        }

        public void ToggleTopBarVisibility()
        {
            // 切换「光标所在屏」的顶栏
            var sid = MonitorService.DeviceIdOf(MonitorService.ScreenUnderCursor());
            SetTopBarVisibility(!_config.ShowTopBarFor(sid));
        }

        /// <summary>
        /// 显示 / 隐藏**指定显示器**的顶部导航栏（默认 = 光标所在屏）。
        /// 每屏的顶栏独立存在或销毁，其他显示器不受影响。
        /// </summary>
        public void SetTopBarVisibility(bool visible, System.Windows.Forms.Screen? target = null)
        {
            var screen = target ?? MonitorService.ScreenUnderCursor();
            var sid = MonitorService.DeviceIdOf(screen);
            _config.SetShowTopBarFor(sid, visible);

            if (visible)
            {
                if (!_topBarWindows.TryGetValue(sid, out var bar))
                {
                    bar = CreateTopBar(screen);
                    _topBarWindows[sid] = bar;
                }
                bar.Show();
            }
            else if (_topBarWindows.TryGetValue(sid, out var existing))
            {
                existing.Close();
                _topBarWindows.Remove(sid);
            }
            UpdateAllTopBars();
        }

        /// <summary>
        /// 分区排版对齐。**只重排指定显示器上**的分区（默认 = 光标所在屏），
        /// 其他显示器上的分区保持原位不动 —— 多屏下每屏独立排版。
        ///
        /// 与 mac 的 `align(mode:onScreenID:)` / Electron 的 `alignPartitions` 一致：
        /// **不跳过锁定分区**。这是一条显式的整屏排版命令，若把锁定项挑出去，
        /// 剩下的分区会按「含锁定项」的序号落位 → 留下空洞甚至互相叠压，比不排还难看。
        /// 锁定防的是**手滑拖动**，不是「用户主动点重新排版」。
        /// </summary>
        public void AlignPartitions(string mode, System.Windows.Forms.Screen? target = null)
        {
            var screen = target ?? MonitorService.ScreenUnderCursor();
            var sid = MonitorService.DeviceIdOf(screen);

            // 记录**本屏**的对齐模式（多显示器下每屏独立；全局 alignMode 同步更新作为默认值）
            _config.SetAlignModeFor(sid, mode);

            // 只取本屏分区（以窗口当前所在显示器归类）
            var localWins = _partitionWindows.Where(w => w.ScreenId == sid).ToList();
            if (localWins.Count == 0)
            {
                UpdateAllTopBars();
                return;
            }
            var localModels = localWins.Select(w => w.Model).ToList();

            // 坐标基准 = **本屏工作区**（逻辑单位），不再是主屏的 SystemParameters.WorkArea
            var workArea = MonitorService.WorkingAreaDIP(screen, localWins[0]);
            // 依据顶栏可见性计算视觉顶部边距：上方留白 16px + 顶栏 44px + 导航栏底部与顶层分区距离 16px = 76.0px
            // 顶部边距按**本屏**是否显示顶栏计算
            double topMargin = _config.ShowTopBarFor(sid) ? 76.0 : 24.0;

            var coords = LayoutEngine.CalculateLayout(
                mode, localModels, workArea.Width, workArea.Height,
                topMargin, 32.0, _config.MaxColumns, _config.TopHeightOrder);

            foreach (var win in localWins)
            {
                if (coords.TryGetValue(win.Model.Id, out var pt))
                {
                    win.AnimateMoveTo(workArea.Left + pt.X, workArea.Top + pt.Y, 160);
                }
            }
            _config.Save();
            UpdateAllTopBars();
        }

        /// <summary>
        /// 「重新对齐分区」：用**目标屏自己的对齐模式**重排（每屏独立设置），
        /// 默认 = 光标所在屏。与 mac 的 `realign(onScreenID:)` 同源。
        /// </summary>
        public void RealignPartitions(System.Windows.Forms.Screen? target = null)
        {
            var screen = target ?? MonitorService.ScreenUnderCursor();
            var sid = MonitorService.DeviceIdOf(screen);
            AlignPartitions(_config.AlignModeFor(sid), screen);
        }

        /// <summary>
        /// 「所有分区自适应高度」：只作用于**指定显示器**上的分区（默认 = 光标所在屏）。
        /// 多显示器下每屏独立，其他屏的分区保持原样 —— 与 mac 的 `autoFitAll(onScreenID:)` 同源。
        /// 锁定的分区跳过，最后汇总提示一次。
        ///
        /// ⚠️ `resetWidth` 必须是 **false**：菜单名写的是「高度」，传 true 会把每个分区的宽度
        /// 一并重置成标准宽度 —— 用户手工拖出来的宽度被一次批量操作抹掉，属于名实不符。
        /// 只在这个入口「只调高度」；标题栏「自适应**宽高**」按钮与双击右下角仍照旧重置宽度。
        /// </summary>
        public void AutoFitAllPartitions(System.Windows.Forms.Screen? target = null)
        {
            var sid = MonitorService.DeviceIdOf(target ?? MonitorService.ScreenUnderCursor());

            int skipped = 0, changed = 0;
            foreach (var win in _partitionWindows.Where(w => w.ScreenId == sid))
            {
                if (win.IsLockedHere) { skipped++; continue; }
                win.AutoFit(resetWidth: false, silent: true);
                changed++;
            }
            _config.Save();
            RefreshPartitionChrome();

            if (changed == 0 && skipped == 0)
            {
                ToastWindow.ShowToast("本屏还没有分区",
                    "先把光标移到有分区的那块屏，或新建一个分区", warn: false);
                return;
            }
            NoteSkippedLocked(skipped, "自适应高度");
        }

        /// <summary>
        /// 批量 / 全局操作里被锁定的分区**静默跳过**，只提示一次总数 ——
        /// 逐个弹提示会把界面刷屏，用户反而看不清到底哪些没生效。
        /// 与 mac 的 `noteSkippedLocked` 措辞一致。
        /// </summary>
        private void NoteSkippedLocked(int count, string action)
        {
            if (count <= 0) return;
            ToastWindow.ShowToast($"已跳过 {count} 个锁定分区",
                $"解锁后才会{action}", warn: false);
        }

        // MARK: - 跨模块联动

        /// <summary>某个分区的模型状态变了（锁定 / 置顶 / 折叠）→ 刷新顶栏的聚合高亮。</summary>
        public void OnPartitionStateChanged()
        {
            UpdateAllTopBars();
            RefreshPartitionChrome();
        }

        /// <summary>分区设置面板点「完成」后的收尾。</summary>
        public void AfterPartitionSettingsChanged(PartitionWindow win)
        {
            // 分区可能刚被改名 / 改尺寸 / 改了置顶 → 顶栏与标题栏都要重算
            _ = win;
            UpdateAllTopBars();
            RefreshPartitionChrome();

        }

        /// <summary>某个分区被移除后清掉残留状态（搜索缓存）。</summary>
        ///
        /// ⚠️ 这里**没有**「从选择集移除」的对应步骤：多选批量操作在 mac 端（唯一功能基线）
        /// 根本不存在，全仓库搜不到任何选择集 / 批量条的实现。
        /// 历史遗留：此处曾有一行 `_selectedIds.Remove(id);`，而 `_selectedIds` **从未被声明**
        /// —— 是个悬空标识符，会直接导致 `dotnet build` 编译失败（CS0103）。
        /// 对照 mac 基线后确认为移植残留，已删除。
        public void AfterPartitionRemoved(string id)
        {
            _ = id;
            UpdateAllTopBars();
            GlobalSearchWindow.InvalidateDirectoryCache();
        }

        private void OnConfigUpdated()
        {
            UpdateAllTopBars();
        }

        // MARK: - 退出

        public void QuitApp()
        {
            _config.Save();
            _notifyIcon?.Dispose();
            _hotKeyManager?.Dispose();
            _hotkeySource?.Dispose();
            _singleInstanceMutex?.ReleaseMutex();
            Shutdown();
        }

        protected override void OnExit(ExitEventArgs e)
        {
            try
            {
                Microsoft.Win32.SystemEvents.DisplaySettingsChanged -= OnDisplaySettingsChanged;
                Microsoft.Win32.SystemEvents.PowerModeChanged -= OnPowerModeChanged;
            }
            catch { }
            _notifyIcon?.Dispose();
            _hotKeyManager?.Dispose();
            _hotkeySource?.Dispose();
            base.OnExit(e);
        }
    }
}
