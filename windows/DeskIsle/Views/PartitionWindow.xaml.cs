using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Controls;
using System.Windows.Documents;
using DeskIsle.Controls;
using DeskIsle.Models;
using DeskIsle.Native;
using DeskIsle.Services;

namespace DeskIsle.Views
{
    public partial class PartitionWindow : Window
    {
        private const int ResizeMargin = 8;
        private const int CornerMargin = 14;

        /// <summary>
        /// 可拖着窗口走的标题栏条带高度（与 mac 基线的 <c>PartitionMetrics.headerHeight</c> 对齐）。
        /// 内容区一律不拖 —— 否则会抢走分区内条目的拖拽（把文件拖出去）与文本选择。
        /// </summary>
        private const double HeaderDragHeight = 44;

        /// <summary>
        /// 锁定态下「暂时用不上」的按钮压暗到这个不透明度。
        /// 用 Opacity 而不是 IsEnabled=false 是刻意的：禁用会连 ToolTip 一起吞掉，
        /// 用户只能看到一个灰按钮、也不知道为什么点不动 —— 而这正是最容易让人
        /// 以为程序坏了的情形。
        /// </summary>
        private const double LockedOpacity = 0.35;

        // Fluent 调色板（与托盘、顶栏保持同一组色值）
        // 全部 Freeze：这些笔刷在多个窗口/线程间共享，冻结后是一次性常量，
        // 既没有每次重新分配的代价，也不会因跨线程访问抛异常。
        private static readonly Brush AccentBrush = MakeFrozen(Color.FromRgb(0x00, 0x78, 0xD4));
        private static readonly Brush AmberBrush = MakeFrozen(Color.FromRgb(0xFF, 0xB9, 0x00));
        private static readonly Brush IdleBrush = MakeFrozen(Color.FromArgb(0xA0, 0xFF, 0xFF, 0xFF));

        private static Brush MakeFrozen(Color color)
        {
            var brush = new SolidColorBrush(color);
            brush.Freeze();
            return brush;
        }

        public PartitionModel Model { get; }
        private readonly Config _config;

        /// <summary>
        /// 目录类分区（portal）当前条目数的取数器，由 <see cref="LoadContentView"/> 注入。
        /// 「自适应宽高」必须按**当前实际条目数**定高度；没有它就只能退回写死值，
        /// 表现是「不管文件夹里有多少东西，自适应永远是同一高度」（历史实现就是写死 240）。
        /// </summary>
        private Func<int>? _entryCountProvider;

        private bool _isHoverPeeked;
        private IntPtr _hwnd;

        /// <summary>
        /// 程序重排（AlignPartitions 的动画移动）进行中的引用计数（X / Y 两个动画各计 1）。
        /// 必须抑制磁吸：动画每帧都会触发 LocationChanged，若照常磁吸，
        /// 排版结果会被二次改写成磁吸自己的基准，出现「间隔滞后一个才恢复」。
        /// </summary>
        private int _programmaticMoveCount;
        private bool IsProgrammaticMove => _programmaticMoveCount > 0;

        /// <summary>应用级宿主（跨分区联动、全局配置都挂在它上面）。</summary>
        private static App? Host => Application.Current as App;

        /// <summary>顶层分区上边距：与 App.AlignPartitions / LayoutEngine 保持同一口径</summary>
        private double TopMargin => _config.ShowTopBarFor(ScreenId) ? 76.0 : 24.0;

        /// <summary>本分区窗口当前所在显示器（分区被拖到哪块屏就归属哪块屏）。</summary>
        public System.Windows.Forms.Screen CurrentScreen => MonitorService.ScreenOf(this);

        /// <summary>本分区所属显示器的标识（DeviceName）。</summary>
        public string ScreenId => MonitorService.DeviceIdOf(CurrentScreen);

        /// <summary>
        /// 判断「本屏是否被锁定」时用哪个屏标识。
        /// 窗口句柄还没建立时（构造函数阶段）<see cref="ScreenId"/> 会回退到**主屏**，
        /// 在副屏上会错判；这时改用配置里记下的归属屏。
        /// </summary>
        private string LockScreenId =>
            _hwnd == IntPtr.Zero && !string.IsNullOrEmpty(Model.ScreenId) ? Model.ScreenId! : ScreenId;

        /// <summary>本屏是否被「锁定分区位置」（多显示器下每屏独立）。</summary>
        private bool ScreenLocked => _config.IsScreenLocked(LockScreenId);

        /// <summary>本分区是否处于「动不了」的状态 —— 分区自身锁定，或本屏被锁定。</summary>
        public bool IsLockedHere => Model.IsLocked || ScreenLocked;

        /// <summary>
        /// 本分区所在显示器的工作区（WPF 逻辑单位）。
        /// 多显示器下吸附 / 越界校正都必须以它为基准，不能用 SystemParameters.WorkArea（恒为主屏）。
        /// </summary>
        public Rect CurrentWorkArea => MonitorService.WorkingAreaDIP(CurrentScreen, this);

        public PartitionWindow(PartitionModel model, Config config)
        {
            InitializeComponent();
            Model = model;
            _config = config;

            Left = model.X;
            Top = model.Y;
            Width = model.Width > 0 ? model.Width : LayoutEngine.DefaultPartitionWidth;
            Height = model.IsCollapsed ? 44 : (model.Height > 0 ? model.Height : 200);

            LoadContentView();
            ApplyCardBackground();              // 分区背景不透明度（全局设置）
            RefreshChrome();
            ApplyMinHeight();                   // 缩放下限跟随「分区最小高度」（句柄就绪后会再刷一次）
            _config.OnConfigChanged += ApplyCardBackground;
            // 分区窗口会被整批关闭重建（导入配置、显示器变化），不退订就会累积
            // 一堆已死窗口的事件订阅，每重建一次多一份。
            Closed += (_, _) => _config.OnConfigChanged -= ApplyCardBackground;

            Loaded += OnLoaded;
            LocationChanged += OnLocationChanged;
            SizeChanged += OnSizeChanged;
        }

        private void OnLoaded(object sender, RoutedEventArgs e)
        {
            _hwnd = new WindowInteropHelper(this).Handle;
            var source = HwndSource.FromHwnd(_hwnd);
            source?.AddHook(WndProc);

            Win32.ApplyAcrylic(_hwnd);
            UpdateWindowLevel();

            PreviewMouseDown += (_, _) => ActivateAsNormalWindow();
            PreviewMouseRightButtonDown += (_, _) => ActivateAsNormalWindow();
            Deactivated += (_, _) => DeactivateToDesktop();

            // 句柄就绪后屏归属才是准的，这里刷一次以修正「构造阶段按主屏算出来的锁定态」
            RefreshChrome();
            ApplyMinHeight();                   // 按真实所在屏重算一次缩放下限
        }

        /// <summary>
        /// 应用「全局设置 → 分区背景不透明度」到卡片底色。
        /// 保留原深色 #1C1C22，仅改 alpha —— 原静态值 #99（≈60%），故默认值取 0.6，升级后视觉不变。
        /// 由 Config.OnConfigChanged 触发，拖动滑条时可实时刷新所有分区窗口。
        /// </summary>
        private void ApplyCardBackground()
        {
            var st = Model.Style;

            // 背景色：per-partition 优先，缺省沿用历史的 #1C1C22（Windows 端卡片底色）。
            // ⚠️ 这里的「底色」与 mac 不同 —— mac 叠的是纯黑，Windows 叠的是深灰蓝，
            // 两端各自的 historical 观感要保住，**只有不透明度是被 Style 覆盖的那部分**。
            Color baseColor = ParseHexColor(st?.BgColor, Color.FromRgb(0x1C, 0x1C, 0x22));
            var opacity = PartitionLook.ClampBgOpacity(st?.BgOpacity ?? _config.PartitionBgOpacity);
            CardBorder.Background = new SolidColorBrush(Color.FromArgb(
                (byte)Math.Round(opacity * 255), baseColor.R, baseColor.G, baseColor.B));

            // 圆角：per-partition 优先，缺省按 mac 基线的 16（历史上 XAML 写死 8，见 PartitionLook 注释）。
            double radius = PartitionLook.ClampCornerRadius(st?.BorderRadius ?? PartitionLook.DefaultCornerRadius);
            CardBorder.CornerRadius = new CornerRadius(radius);

            ApplyBackdrop();
        }

        /// <summary>
        /// 应用模糊档位到 DWM 系统背景。句柄没就绪时跳过 —— <see cref="OnLoaded"/> 里会再调一次。
        /// </summary>
        private void ApplyBackdrop()
        {
            if (_hwnd == IntPtr.Zero) return;
            var amount = Model.Style?.BlurAmount ?? PartitionLook.DefaultBlurAmount;
            Win32.ApplyBackdrop(_hwnd, BackdropFor(PartitionLook.TierFor(amount)));
        }

        /// <summary>
        /// 档位 → Windows 的 DWM 系统背景类型。
        ///
        /// ⚠️ 本端特有的映射：DWM 只有三档（无 / Mica / Acrylic），而 mac 的 Material 与
        /// Electron 的 CSS blur 是四档 —— Thin 与 Regular 在 Windows 上只能落到同一种
        /// （Acrylic，最强的那档）。这是平台能力差异，不是漏实现。
        /// </summary>
        private static int BackdropFor(PartitionLook.BlurTier tier) => tier switch
        {
            PartitionLook.BlurTier.None => Win32.DWMSBT_NONE,
            PartitionLook.BlurTier.UltraThin => Win32.DWMSBT_MAINWINDOW,   // Mica
            _ => Win32.DWMSBT_TRANSIENTWINDOW                              // Acrylic（Thin / Regular）
        };

        /// <summary>
        /// 解析 <c>#RRGGBB</c> / <c>#AARRGGBB</c> 形式的色值；parse 失败一律返回 fallback ——
        /// 用户手输的 hex 可能是随便打的（少一位、中文符号），这里绝不能抛到 UI 外面去。
        /// </summary>
        private static Color ParseHexColor(string? hex, Color fallback)
        {
            if (string.IsNullOrWhiteSpace(hex)) return fallback;
            var s = hex.Trim().TrimStart('#');
            if (s.Length != 6 && s.Length != 8) return fallback;
            try
            {
                if (s.Length == 6) s = "FF" + s;   // 补齐 alpha
                return Color.FromArgb(
                    Convert.ToByte(s.Substring(0, 2), 16),
                    Convert.ToByte(s.Substring(2, 2), 16),
                    Convert.ToByte(s.Substring(4, 2), 16),
                    Convert.ToByte(s.Substring(6, 2), 16));
            }
            catch
            {
                return fallback;
            }
        }

        private void LoadContentView()
        {
            switch (Model.Type)
            {
                case "portal":
                    var portal = new PortalView();
                    portal.BindData(Model, () => _config.Save());
                    ContentHost.Content = portal;
                    _entryCountProvider = () => portal.EntryCount;
                    break;
                case "notes":
                    var notes = new NotesView();
                    notes.BindData(Model, () => _config.Save());
                    ContentHost.Content = notes;
                    break;
                case "todo":
                    var todo = new TodoView();
                    todo.BindData(Model, () => { _config.Save(); RefreshChrome(); });
                    ContentHost.Content = todo;
                    break;
                default:
                    ContentHost.Content = new System.Windows.Controls.Grid();
                    break;
            }
        }

        public void UpdateWindowLevel()
        {
            if (_hwnd == IntPtr.Zero) return;

            if (Model.IsAlwaysOnTop)
            {
                Topmost = true;
                Win32.SetWindowPos(_hwnd, Win32.HWND_TOPMOST, 0, 0, 0, 0, Win32.SWP_NOMOVE | Win32.SWP_NOSIZE | Win32.SWP_NOACTIVATE);
            }
            else
            {
                Topmost = false;
                Win32.SetWindowPos(_hwnd, Win32.HWND_BOTTOM, 0, 0, 0, 0, Win32.SWP_NOMOVE | Win32.SWP_NOSIZE | Win32.SWP_NOACTIVATE);
            }
        }

        public void ActivateAsNormalWindow()
        {
            if (Model.IsAlwaysOnTop) return;
            if (_hwnd == IntPtr.Zero) return;
            Win32.SetWindowPos(_hwnd, Win32.HWND_TOP, 0, 0, 0, 0, Win32.SWP_NOMOVE | Win32.SWP_NOSIZE);
            Activate();
        }

        public void DeactivateToDesktop()
        {
            if (Model.IsAlwaysOnTop) return;
            if (_hwnd == IntPtr.Zero) return;
            Win32.SetWindowPos(_hwnd, Win32.HWND_BOTTOM, 0, 0, 0, 0, Win32.SWP_NOMOVE | Win32.SWP_NOSIZE | Win32.SWP_NOACTIVATE);
        }

        // MARK: - 标题栏外观（标题 / 图标 / 折叠 / 锁定压暗）

        /// <summary>
        /// 刷新标题栏的全部视觉状态。任何会影响标题栏的操作（锁定、置顶、折叠、
        /// 标题改名、屏幕锁定变化）之后都必须调它一次。
        /// </summary>
        public void RefreshChrome()
        {
            if (!Dispatcher.CheckAccess())
            {
                Dispatcher.Invoke(RefreshChrome);
                return;
            }
            UpdateHeaderUI();
            ApplyLockVisuals();
        }

        private void UpdateHeaderUI()
        {
            var (icon, text) = PartitionTitle.Split(Model.Title, Model.Type);
            IconText.Text = icon;
            TitleDisplay.Text = text;

            if (Model.Type == "todo")
            {
                int total = Model.Todos.Count;
                if (total > 0)
                {
                    int done = Model.Todos.Count(t => t.Completed);
                    BadgeText.Text = $"{done}/{total}";
                    bool allDone = done == total;
                    if (allDone)
                    {
                        BadgeText.Foreground = new SolidColorBrush(Color.FromRgb(0x4A, 0xDE, 0x80));
                        BadgeBorder.Background = new SolidColorBrush(Color.FromArgb(0x38, 0x4A, 0xDE, 0x80));
                    }
                    else
                    {
                        BadgeText.Foreground = (Brush)FindResource("TextSecondaryBrush");
                        BadgeBorder.Background = new SolidColorBrush(Color.FromArgb(0x26, 0xFF, 0xFF, 0xFF));
                    }
                    BadgeBorder.Visibility = Visibility.Visible;
                }
                else
                {
                    BadgeBorder.Visibility = Visibility.Collapsed;
                }
            }
            else
            {
                BadgeBorder.Visibility = Visibility.Collapsed;
            }

            // Fluent Chevron Glyph: &#xE70D; (ChevronDown) / &#xE70E; (ChevronUp)
            CollapseBtn.Content = Model.IsCollapsed ? "\uE70D" : "\uE70E";
            ContentArea.Visibility = Model.IsCollapsed ? Visibility.Collapsed : Visibility.Visible;

            // 标题色 / 正文色：留空 = 跟随系统（不写死，深浅主题都能读）。
            var st = Model.Style;
            if (!string.IsNullOrWhiteSpace(st?.HeaderColor))
                TitleDisplay.Foreground = new SolidColorBrush(ParseHexColor(st!.HeaderColor, AccentColor));
            if (!string.IsNullOrWhiteSpace(st?.TextColor))
                ContentArea.SetValue(TextElement.ForegroundProperty,
                                     new SolidColorBrush(ParseHexColor(st!.TextColor, Colors.White)));
        }

        /// <summary>Windows 端标题的默认强调色（与 mac / Electron 的 #38bdf8 同源）。</summary>
        private static Color AccentColor => Color.FromRgb(0x38, 0xBD, 0xF8);

        /// <summary>
        /// 锁定态下把「动不了」的按钮压暗并改写提示语。
        ///
        /// 「锁定」按钮自身**永不压暗** —— 它是锁定态下唯一还能操作的按钮，
        /// 压暗它等于把用户锁在外面，而这正是人们抱怨「锁定之后解不开」的根因。
        /// 「设置」也不压暗：面板里能看到锁定来源，是排查问题的入口。
        /// </summary>
        private void ApplyLockVisuals()
        {
            bool locked = Model.IsLocked;
            LockBtn.Content = locked ? "\uE72E" : "\uE785";
            LockBtn.Foreground = locked ? AmberBrush : IdleBrush;
            LockBtn.ToolTip = locked ? "解锁该分区" : "锁定分区位置与尺寸";

            double dim = IsLockedHere ? LockedOpacity : 1.0;
            PinBtn.Opacity = dim;
            FitBtn.Opacity = dim;
            CollapseBtn.Opacity = dim;
            DeleteBtn.Opacity = dim;

            // 置顶改的是窗口层级（可见行为的一部分），属于「改变分区自己」——
            // 锁定时一并压暗，判定在 Pin_Click 里与 mac / Electron 同源。
            PinBtn.Foreground = Model.IsAlwaysOnTop ? AccentBrush : IdleBrush;
            PinBtn.ToolTip = Model.IsAlwaysOnTop ? "取消置顶" : "置顶该分区";

            FitBtn.ToolTip = LockedTooltip("自适应宽高 (宽度恢复为280)", "自适应宽高");
            CollapseBtn.ToolTip = LockedTooltip(Model.IsCollapsed ? "展开分区" : "折叠分区", Model.IsCollapsed ? "展开" : "折叠");
            DeleteBtn.ToolTip = LockedTooltip("删除分区", "删除");
        }

        /// <summary>锁定态下把提示语换成「为什么点不动 + 该怎么解」。</summary>
        private string LockedTooltip(string normal, string action)
        {
            if (!IsLockedHere) return normal;
            if (Model.IsLocked && ScreenLocked) return $"已锁定（本屏 + 分区）：先解锁才能{action}";
            return Model.IsLocked
                ? $"分区已锁定：先解锁才能{action}"
                : $"本屏已锁定：先解锁本屏才能{action}";
        }

        /// <summary>
        /// 拦截因锁定而禁止的操作，并弹出**说清原因**的瞬时提示。
        /// 返回 true 表示「已被拦下，调用方应直接 return」。
        ///
        /// 提示分三种措辞是必要的：只说「已锁定」的话，分区锁的用户会去翻全局设置，
        /// 屏幕锁的用户会去翻分区标题栏 —— 两边都找不到解锁入口。
        /// </summary>
        private bool BlockedByLock(string action)
        {
            bool self = Model.IsLocked;
            bool screen = ScreenLocked;
            if (!self && !screen) return false;

            if (self && screen)
            {
                ToastWindow.ShowToast($"本屏与分区均已锁定，无法{action}",
                    "请先解锁本屏（导航栏或托盘菜单），再点标题栏的解锁按钮");
            }
            else if (self)
            {
                ToastWindow.ShowToast($"分区已锁定，无法{action}", "请先点标题栏最左侧的解锁按钮");
            }
            else
            {
                ToastWindow.ShowToast($"本屏已锁定，无法{action}", "请先在导航栏或托盘菜单解锁本屏");
            }
            return true;
        }

        // MARK: - 标题行内重命名 (限制 10 汉字)
        private void TitleArea_MouseDown(object sender, MouseButtonEventArgs e)
        {
            if (e.ClickCount != 2) return;
            BeginTitleRename();
        }

        /// <summary>
        /// 进入标题行内重命名。两个入口共用一个实现：
        /// ① 标题栏不是 HTCAPTION 时走 WPF 的 <c>TitleArea_MouseDown</c>；
        /// ② 是 HTCAPTION 时双击只发「非客户区」消息，由 WndProc 转发到这里。
        /// </summary>
        private void BeginTitleRename()
        {
            if (BlockedByLock("重命名")) return;

            TitleDisplay.Visibility = Visibility.Collapsed;
            TitleEditBox.Visibility = Visibility.Visible;
            TitleEditBox.Text = TitleDisplay.Text;
            TitleEditBox.Focus();
            TitleEditBox.SelectAll();
        }

        private void TitleEditBox_KeyDown(object sender, KeyEventArgs e)
        {
            if (e.Key == Key.Enter)
            {
                CommitTitle();
            }
            else if (e.Key == Key.Escape)
            {
                CancelTitle();
            }
        }

        private void TitleEditBox_LostFocus(object sender, RoutedEventArgs e)
        {
            CommitTitle();
        }

        private void CommitTitle()
        {
            if (TitleEditBox.Visibility != Visibility.Visible) return;
            string clean = TitleEditBox.Text.Trim();
            if (clean.Length > 10) clean = clean[..10];
            if (string.IsNullOrEmpty(clean)) clean = TitleDisplay.Text;

            Model.Title = PartitionTitle.Compose(IconText.Text, clean);
            TitleDisplay.Text = clean;
            TitleEditBox.Visibility = Visibility.Collapsed;
            TitleDisplay.Visibility = Visibility.Visible;

            _config.Save();
        }

        private void CancelTitle()
        {
            TitleEditBox.Visibility = Visibility.Collapsed;
            TitleDisplay.Visibility = Visibility.Visible;
        }

        // MARK: - 标题按钮操作
        private void Pin_Click(object sender, RoutedEventArgs e)
        {
            // 置顶改的是窗口层级（可见行为的一部分），算「改变分区自己」——
            // 锁定时一并拦下，与 mac 的 `setPinned` 和 Electron 的 `togglePin` 同源。
            if (BlockedByLock(Model.IsAlwaysOnTop ? "取消置顶" : "置顶")) return;
            Model.IsAlwaysOnTop = !Model.IsAlwaysOnTop;
            UpdateWindowLevel();
            AfterModelChanged();
        }

        private void Lock_Click(object sender, RoutedEventArgs e)
        {
            Model.IsLocked = !Model.IsLocked;
            AfterModelChanged();
        }

        private void AutoFit_Click(object sender, RoutedEventArgs e)
        {
            // 显式点「自适应宽高」→ 折叠中的分区顺势展开
            AutoFit(resetWidth: true, expandIfCollapsed: true);
        }

        private void Collapse_Click(object sender, RoutedEventArgs e)
        {
            if (BlockedByLock(Model.IsCollapsed ? "展开" : "折叠")) return;
            Model.IsCollapsed = !Model.IsCollapsed;
            Height = Model.IsCollapsed ? 44 : Math.Max(140.0, Model.Height);
            ApplyMinHeight();
            AfterModelChanged();
        }

        /// <summary>分区设置（⚙）。</summary>
        private void Settings_Click(object sender, RoutedEventArgs e)
        {
            // 设置面板**不因锁定而禁用**：它是用户查清「哪一层锁着」的入口，
            // 面板内的尺寸控件会自行按锁定状态禁用并写明原因。
            bool applied = PartitionSettingsDialog.Edit(
                Model,
                _config,
                onApplied: ApplyModelToWindow,
                // 设置面板里的「按内容自适应高度」按钮也是显式点击 → 折叠时顺势展开
                onAutoFit: () => AutoFit(resetWidth: false, silent: true, expandIfCollapsed: true));

            if (applied) Host?.AfterPartitionSettingsChanged(this);
        }

        private void Delete_Click(object sender, RoutedEventArgs e)
        {
            if (BlockedByLock("删除")) return;

            var res = MessageBox.Show("确定要移除该分区吗？\n（此操作仅移除分区视窗，不会删除本地任何物理文件）",
                                      "移除分区", MessageBoxButton.OKCancel, MessageBoxImage.Question);
            if (res == MessageBoxResult.OK)
            {
                _config.Partitions.Remove(Model);
                _config.Save();
                Host?.AfterPartitionRemoved(Model.Id);
                Close();
            }
        }

        /// <summary>把模型里的尺寸 / 置顶 / 折叠状态套回窗口（设置面板点「完成」后调用）。</summary>
        private void ApplyModelToWindow()
        {
            Width = Model.Width > 0 ? Model.Width : LayoutEngine.DefaultPartitionWidth;
            Height = Model.IsCollapsed ? 44 : Math.Max(140.0, Model.Height);
            ApplyMinHeight();
            UpdateWindowLevel();
            _config.Save();
            RefreshChrome();
        }

        /// <summary>
        /// 按 <see cref="PartitionModel.IsCollapsed"/> 套用折叠态（折叠时高度收到 44）。
        /// </summary>
        public void ApplyCollapsedState()
        {
            Height = Model.IsCollapsed ? 44 : Math.Max(140.0, Model.Height);
            ApplyMinHeight();
            RefreshChrome();
        }

        /// <summary>应用布局预设：位置与尺寸一起落定（调用方已确认该分区未被锁定）。</summary>
        public void ApplyPresetGeometry(double x, double y, double width, double height)
        {
            Model.Width = Math.Max(160.0, width);
            Model.Height = Math.Max(140.0, height);
            Model.IsCollapsed = false;   // 预设记的是「展开态下的尺寸」，恢复即展开
            Width = Model.Width;
            Height = Model.Height;
            AnimateMoveTo(x, y, 180);
            RefreshChrome();
        }

        /// <summary>
        /// 用户设置的「分区最小高度」在本屏的**实际生效值**（夹上限后）。
        /// 全局偏好设置的是用户意图，落到某一块屏幕上还要再夹一次「屏幕可用高 - 60」。
        /// </summary>
        private double UserMinHeight()
            => PartitionMetrics.ClampedUserMinHeight(_config.MinPartitionHeight, CurrentWorkArea.Height);

        /// <summary>
        /// 把「分区最小高度」应用到窗口的缩放下限（此前是 XAML 里写死的 <c>MinHeight="40"</c>，
        /// 于是设了 300 的用户照样能把分区拖成 40 高 —— 设置形同虚设）。
        ///
        /// ⚠️ **折叠态必须降回 44**：折叠窗口本身就只有标题栏那么高，
        /// 照搬下限会把折叠起来的分区硬撑开。
        /// </summary>
        private void ApplyMinHeight()
        {
            MinHeight = Model.IsCollapsed ? 44 : Math.Max(40.0, UserMinHeight());
        }

        /// <summary>模型变更后的统一收尾：落盘 + 通知宿主刷新顶栏与标题栏。</summary>
        private void AfterModelChanged()
        {
            _config.Save();
            RefreshChrome();
            Host?.OnPartitionStateChanged();
        }

        // MARK: - 边缘自适应与重置
        /// <summary>
        /// 自适应宽高。<paramref name="silent"/> = true 时锁定态下不弹提示
        /// （用于「设置面板里点按钮」等已有其他反馈的场合，避免提示叠两条）。
        /// <paramref name="expandIfCollapsed"/> = 折叠中的分区是否**顺势展开**：
        /// 只有「用户显式点自适应」的入口才传 true（标题栏按钮、设置面板的
        /// 「按内容自适应高度」按钮、双击底边 / 右下角）—— 他想看内容，展开符合预期；
        /// 而「所有分区自适应高度」批量必须保持折叠，否则一次操作把所有折叠分区全展开。
        /// </summary>
        public void AutoFit(bool resetWidth = true, bool silent = false, bool expandIfCollapsed = false)
        {
            if (IsLockedHere)
            {
                if (!silent) BlockedByLock("自适应宽高");
                return;
            }

            if (resetWidth)
            {
                // 用本分区所在显示器的宽度计算标准宽度（多屏分辨率不同）
                var workArea = CurrentWorkArea;
                double standardW = _config.CalculateStandardWidth(workArea.Width);
                Width = standardW;
                Model.Width = standardW;
            }

            // 内容高度口径全部集中在 PartitionMetrics（与视图侧的 padding / 行高一一对应）。
            // ⚠️ 修复前 portal / 未知类型一律是写死的 240 —— 一个装了 50 个文件的
            // 映射文件夹点「自适应宽高」只有 240 高，内容被裁掉大半；而只有 3 个文件时又空出一大截。
            double contentH = Model.Type switch
            {
                "todo" => PartitionMetrics.TodoContentHeight(
                    Model.Todos.Count(t => !t.Completed),
                    Model.Todos.Count(t => t.Completed),
                    Model.IsCompletedCollapsed),
                // 便签按**内容逐行**算（与 mac / Electron 同源的口径，见 Services/PartitionMetrics.cs）。
                // ⚠️ 修复前这里是写死的 `Math.Clamp(180, 160, 600)` —— 一份 21 行的账号清单
                // 点「自适应宽高」永远只有 180 高，内容被裁掉大半，用户会认为该功能坏了。
                "notes" => PartitionMetrics.NotesContentHeight(Model.NoteContent, Model.Width),
                "portal" => PartitionMetrics.ListContentHeight(_entryCountProvider?.Invoke() ?? 0),
                _ => 120
            };

            // 夹取口径走 `PartitionMetrics.WindowHeight` —— 不再在这里手抄一遍
            // （mac 的 `autoFitHeight` 踩过同一个坑：手抄版与共用版差一个 `max(minHeight, …)`）。
            // 下限用**用户设置的最小高度**（缺省时 PartitionMetrics 退回自己的物理下限），
            // 并夹一层上限：填了 5000 也不能把窗口顶得比屏幕还高。
            double minH = UserMinHeight();
            double estHeight = PartitionMetrics.WindowHeight(contentH, CurrentWorkArea.Height, minH);

            // ⚠️ 折叠态默认**保持折叠**：此前这里无条件写 `IsCollapsed = false`，
            // 于是跑一次「所有分区自适应高度」会把所有折叠中的分区一次性全部展开 ——
            // 折叠本来就是为了省地方。保持折叠时只更新「存储的展开高度」（下次展开即生效），
            // 屏幕上的窗口仍是标题栏高度（44）；只有显式入口才顺势展开。
            bool wasCollapsed = Model.IsCollapsed;
            Model.Height = estHeight;
            if (wasCollapsed && expandIfCollapsed) Model.IsCollapsed = false;
            ApplyCollapsedState();          // 折叠 → 44；展开 → estHeight（含缩放下限刷新）

            // ⚠️ 自适应后必须夹回本屏工作区（mac 的 `autoFitHeight` 有这一步，本端此前没有）：
            // 只改高度、不收位置的话，靠近底边的分区长高后下半截会掉到工作区外面。
            if (!Model.IsCollapsed) ClampIntoWorkArea(estHeight);

            AfterModelChanged();
        }

        /// <summary>
        /// 把窗口收回到**本屏工作区**内（自适应长高 / 变宽后靠边的分区可能越界）。
        ///
        /// 与 mac <c>autoFitHeight</c> 的 x / y 夹取同口径：左右留 <see cref="LayoutEngine.Margin"/>，
        /// 顶部留给顶栏（<see cref="TopMargin"/>），底部留 <see cref="LayoutEngine.Margin"/>。
        ///
        /// ⚠️ 改写位置期间必须抑制磁吸（<see cref="_programmaticMoveCount"/>）：
        /// <c>LocationChanged</c> 每帧都会触发，照常磁吸会把自适应结果二次挪走。
        /// </summary>
        private void ClampIntoWorkArea(double height)
        {
            var wa = CurrentWorkArea;
            double maxLeft = wa.Right - Width - LayoutEngine.Margin;
            double maxTop = wa.Bottom - height - LayoutEngine.Margin;
            double left = Math.Max(wa.Left + LayoutEngine.Margin, Math.Min(Left, maxLeft));
            double top = Math.Max(wa.Top + TopMargin, Math.Min(Top, maxTop));
            if (Math.Abs(left - Left) < 0.5 && Math.Abs(top - Top) < 0.5) return;

            _programmaticMoveCount++;
            try
            {
                Left = left;
                Top = top;
                Model.X = left;
                Model.Y = top;
            }
            finally
            {
                if (_programmaticMoveCount > 0) _programmaticMoveCount--;
            }
        }

        public void ResetWidth(double width = LayoutEngine.DefaultPartitionWidth)
        {
            if (IsLockedHere) return;   // 该入口只来自双击右边缘，而那条路径已被 WndProc 拦住，这里兜底
            Width = width;
            Model.Width = width;
            AfterModelChanged();
        }

        // MARK: - 折叠悬停预览 (Hover Peek) 与弹簧感应展开 (Spring-Loaded Folders)
        private DispatcherTimer? _springLoadHeaderTimer;

        private void Window_MouseEnter(object sender, MouseEventArgs e)
        {
            // 悬停预览只是**临时展开看一眼**，不改折叠态、也不落盘，
            // 因此锁定态下照常工作（「锁了就看不了内容」是无谓的惩罚）。
            if (Model.IsCollapsed && _config.HoverPreview)
            {
                _isHoverPeeked = true;
                Height = Math.Max(Model.Height, 200);
                ContentArea.Visibility = Visibility.Visible;
            }
        }

        private void Window_MouseLeave(object sender, MouseEventArgs e)
        {
            if (_isHoverPeeked)
            {
                _isHoverPeeked = false;
                Height = 44;
                ContentArea.Visibility = Visibility.Collapsed;
            }
        }

        private void Window_DragLeave(object sender, DragEventArgs e)
        {
            var pos = e.GetPosition(this);
            if (pos.X < 0 || pos.Y < 0 || pos.X >= ActualWidth || pos.Y >= ActualHeight)
            {
                _springLoadHeaderTimer?.Stop();
                _springLoadHeaderTimer = null;
                if (_isHoverPeeked)
                {
                    _isHoverPeeked = false;
                    Height = 44;
                    ContentArea.Visibility = Visibility.Collapsed;
                    CollapseBtn.Content = "\uE70D";
                }
            }
        }

        private void Header_DragOver(object sender, DragEventArgs e)
        {
            if (e.Data.GetDataPresent(DataFormats.FileDrop))
            {
                e.Effects = DragDropEffects.Copy | DragDropEffects.Move;
                e.Handled = true;

                if (Model.IsCollapsed && !_isHoverPeeked && _springLoadHeaderTimer == null)
                {
                    _springLoadHeaderTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(450) };
                    _springLoadHeaderTimer.Tick += (_, _) =>
                    {
                        _springLoadHeaderTimer?.Stop();
                        _springLoadHeaderTimer = null;
                        if (Model.IsCollapsed)
                        {
                            _isHoverPeeked = true;
                            Height = Math.Max(Model.Height, 200);
                            ContentArea.Visibility = Visibility.Visible;
                            CollapseBtn.Content = "\uE70E";
                        }
                    };
                    _springLoadHeaderTimer.Start();
                }
            }
            else
            {
                e.Effects = DragDropEffects.None;
            }
        }

        private void Header_DragLeave(object sender, DragEventArgs e)
        {
            _springLoadHeaderTimer?.Stop();
            _springLoadHeaderTimer = null;
        }

        private void Header_Drop(object sender, DragEventArgs e)
        {
            _springLoadHeaderTimer?.Stop();
            _springLoadHeaderTimer = null;

            if (_isHoverPeeked)
            {
                _isHoverPeeked = false;
                if (Model.IsCollapsed)
                {
                    Height = 44;
                    ContentArea.Visibility = Visibility.Collapsed;
                    CollapseBtn.Content = "\uE70D";
                }
            }

            if (!e.Data.GetDataPresent(DataFormats.FileDrop)) return;
            var paths = e.Data.GetData(DataFormats.FileDrop) as string[];
            if (paths == null || paths.Length == 0) return;

            if (Model.Type == "portal")
            {
                if (!string.IsNullOrEmpty(Model.FolderPath) && Directory.Exists(Model.FolderPath))
                {
                    FolderDrop.OnDrop(e, Model.FolderPath, () => (ContentHost.Content as PortalView)?.ReloadItems());
                }
            }
            else if (Model.Type == "notes")
            {
                string addition = string.Join(Environment.NewLine, paths);
                Model.NoteContent = string.IsNullOrEmpty(Model.NoteContent) ? addition : Model.NoteContent + Environment.NewLine + addition;
                _config.Save();
                (ContentHost.Content as NotesView)?.BindData(Model, () => _config.Save());
                e.Handled = true;
            }
            else if (Model.Type == "todo")
            {
                Model.Todos ??= new List<TodoItem>();
                foreach (var p in paths)
                {
                    string name = Path.GetFileName(p);
                    if (!string.IsNullOrEmpty(name))
                    {
                        Model.Todos.Add(new TodoItem { Text = name, Completed = false });
                    }
                }
                _config.Save();
                (ContentHost.Content as TodoView)?.BindData(Model, () => { _config.Save(); RefreshChrome(); });
                e.Handled = true;
            }
        }

        // MARK: - 拖拽磁吸与尺寸联动
        private void OnLocationChanged(object? sender, EventArgs e)
        {
            // 锁定不只是「不让拖」：程序重排（对齐 / 应用布局预设）同样不该动它
            if (IsLockedHere) return;

            // 程序重排（动画移动）期间跳过磁吸：排版结果不应被磁吸二次改写
            if (_config.EdgeSnapping && !IsProgrammaticMove && !Keyboard.Modifiers.HasFlag(ModifierKeys.Alt))
            {
                // 以「本分区所在显示器」的工作区做边缘吸附（原用主屏工作区，副屏上会吸错位置）
                var workArea = CurrentWorkArea;
                var (snappedX, snappedY) = SnappingManager.Snap(
                    Model.Id, Left, Top, Width, Height, _config.Partitions, workArea, TopMargin);
                Left = snappedX;
                Top = snappedY;
            }

            Model.X = Left;
            Model.Y = Top;
            // 分区被拖到另一块显示器时同步它的屏幕归属（重启后仍归到正确的显示器分组）
            var sid = MonitorService.DeviceIdOf(CurrentScreen);
            if (Model.ScreenId != sid) Model.ScreenId = sid;
            _config.Save();
        }

        private void OnSizeChanged(object sender, SizeChangedEventArgs e)
        {
            if (!Model.IsCollapsed && !_isHoverPeeked)
            {
                Model.Width = Width;
                Model.Height = Height;
                _config.Save();
            }
        }

        /// <summary>
        /// 该点是否压在指定元素（及其子孙）上。
        ///
        /// 用于把「标题栏可拖区」里的控件挑出来：它们需要自己收鼠标事件，
        /// 不能被 <c>HTCAPTION</c> 吞掉。
        /// </summary>
        private bool IsOverElement(Point clientPoint, FrameworkElement element)
        {
            if (element == null) return false;
            HitTestResult? hit;
            try { hit = VisualTreeHelper.HitTest(this, clientPoint); }
            catch { return false; }   // 点在窗口外 / 视觉树还没建好：按「可拖」处理，不至于拖不动
            for (DependencyObject? d = hit?.VisualHit; d != null; d = VisualTreeHelper.GetParent(d))
            {
                if (ReferenceEquals(d, element)) return true;
                if (ReferenceEquals(d, this)) break;
            }
            return false;
        }

        // MARK: - Win32 8向非客户区缩放与双击
        private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
        {
            switch (msg)
            {
                case Win32.WM_NCHITTEST:
                    // 分区自身锁定 或 本屏锁定 → 都不给缩放命中区
                    if (IsLockedHere)
                    {
                        handled = false;
                        return IntPtr.Zero;
                    }

                    int x = unchecked((short)(long)lParam);
                    int y = unchecked((short)((long)lParam >> 16));
                    var clientPoint = PointFromScreen(new Point(x, y));

                    // 四个拐角判断
                    if (clientPoint.X <= CornerMargin && clientPoint.Y <= CornerMargin)
                    {
                        handled = true;
                        return (IntPtr)Win32.HTTOPLEFT;
                    }
                    if (clientPoint.X >= ActualWidth - CornerMargin && clientPoint.Y <= CornerMargin)
                    {
                        handled = true;
                        return (IntPtr)Win32.HTTOPRIGHT;
                    }
                    if (clientPoint.X <= CornerMargin && clientPoint.Y >= ActualHeight - CornerMargin)
                    {
                        handled = true;
                        return (IntPtr)Win32.HTBOTTOMLEFT;
                    }
                    if (clientPoint.X >= ActualWidth - CornerMargin && clientPoint.Y >= ActualHeight - CornerMargin)
                    {
                        handled = true;
                        return (IntPtr)Win32.HTBOTTOMRIGHT;
                    }

                    // 四边判断
                    if (clientPoint.Y <= ResizeMargin)
                    {
                        handled = true;
                        return (IntPtr)Win32.HTTOP;
                    }
                    if (clientPoint.Y >= ActualHeight - ResizeMargin)
                    {
                        handled = true;
                        return (IntPtr)Win32.HTBOTTOM;
                    }
                    if (clientPoint.X <= ResizeMargin)
                    {
                        handled = true;
                        return (IntPtr)Win32.HTLEFT;
                    }
                    if (clientPoint.X >= ActualWidth - ResizeMargin)
                    {
                        handled = true;
                        return (IntPtr)Win32.HTRIGHT;
                    }

                    // 标题栏拖拽区域（**只有这一条能拖窗口**）
                    //
                    // ⚠️ 必须避开右侧那排按钮：整条 44px 无差别返回 HTCAPTION 的话，按下鼠标会被
                    // Windows 判成「非客户区」消息（WM_NCLBUTTONDOWN），WPF 控件收不到
                    // WM_LBUTTONDOWN —— 表现是「标题栏按钮全都点不动，只会拖着窗口跑」。
                    if (clientPoint.Y <= HeaderDragHeight)
                    {
                        handled = true;
                        return IsOverElement(clientPoint, HeaderActions)
                            ? (IntPtr)Win32.HTCLIENT      // 按钮自己收点击
                            : (IntPtr)Win32.HTCAPTION;    // 其余（标题 / 空白）拖窗口
                    }
                    break;

                case Win32.WM_NCLBUTTONDBLCLK:
                    // 双击边缘的三条「一键改尺寸」捷径同样受锁定约束
                    if (IsLockedHere) break;
                    int hitArea = wParam.ToInt32();
                    if (hitArea == Win32.HTBOTTOM)
                    {
                        // 双击底边：仅自适应高度（双击是显式操作 → 折叠时顺势展开）
                        AutoFit(resetWidth: false, expandIfCollapsed: true);
                        handled = true;
                    }
                    else if (hitArea == Win32.HTRIGHT)
                    {
                        ResetWidth(LayoutEngine.DefaultPartitionWidth);
                        handled = true;
                    }
                    else if (hitArea == Win32.HTBOTTOMRIGHT)
                    {
                        // 双击右下角：自适应高度并初始化宽度（同上，折叠时顺势展开）
                        AutoFit(resetWidth: true, expandIfCollapsed: true);
                        handled = true;
                    }
                    else if (hitArea == Win32.HTCAPTION)
                    {
                        // 标题栏整条都是 HTCAPTION，双击消息走的是「非客户区」，
                        // WPF 侧的 MouseLeftButtonDown 收不到 —— 重命名必须在这里补上。
                        int dx = unchecked((short)(long)lParam);
                        int dy = unchecked((short)((long)lParam >> 16));
                        if (IsOverElement(PointFromScreen(new Point(dx, dy)), TitleArea))
                        {
                            BeginTitleRename();
                        }
                        else
                        {
                            ToggleCollapse();
                        }
                        handled = true;
                    }
                    break;

                // MARK: - P2: Win+D 桌面常驻与穿透防护
                case Win32.WM_WINDOWPOSCHANGING:
                    // 按本分区所在显示器的显隐态判断（多屏下每屏独立）
                    if (!_config.IsScreenHidden(ScreenId) && !Model.IsAlwaysOnTop)
                    {
                        try
                        {
                            var pos = Marshal.PtrToStructure<Win32.WINDOWPOS>(lParam);
                            // 如果系统尝试隐藏非幽灵模式的常规浮岛 (如按下 Win+D 显示桌面)，清除隐藏标记保持常驻
                            if ((pos.flags & Win32.SWP_HIDEWINDOW) != 0)
                            {
                                pos.flags &= ~Win32.SWP_HIDEWINDOW;
                                Marshal.StructureToPtr(pos, lParam, true);
                                handled = true;
                            }
                        }
                        catch { }
                    }
                    break;

                case Win32.WM_ACTIVATE:
                    if ((wParam.ToInt32() & 0xFFFF) == Win32.WA_INACTIVE && !Model.IsAlwaysOnTop)
                    {
                        DeactivateToDesktop();
                    }
                    break;

                case Win32.WM_SYSCOMMAND:
                    // 拦截针对浮岛窗口的系统级最小化指令
                    if ((wParam.ToInt32() & 0xFFF0) == Win32.SC_MINIMIZE)
                    {
                        handled = true;
                        return IntPtr.Zero;
                    }
                    break;
            }

            return IntPtr.Zero;
        }

        // MARK: - P3: 120ms 流畅淡入淡出动效与排版平滑位移
        public void FadeIn(int durationMs = 120)
        {
            Visibility = Visibility.Visible;
            var anim = new DoubleAnimation
            {
                From = 0.0,
                To = 1.0,
                Duration = TimeSpan.FromMilliseconds(durationMs),
                EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut }
            };
            BeginAnimation(OpacityProperty, anim);
        }

        public void FadeOut(int durationMs = 120, Action? onCompleted = null)
        {
            var anim = new DoubleAnimation
            {
                From = Opacity,
                To = 0.0,
                Duration = TimeSpan.FromMilliseconds(durationMs),
                EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseIn }
            };
            anim.Completed += (_, _) =>
            {
                Visibility = Visibility.Hidden;
                onCompleted?.Invoke();
            };
            BeginAnimation(OpacityProperty, anim);
        }

        public void AnimateMoveTo(double targetLeft, double targetTop, int durationMs = 160)
        {
            // 抑制磁吸直到 X / Y 两个动画都结束
            _programmaticMoveCount += 2;

            var animX = new DoubleAnimation
            {
                To = targetLeft,
                Duration = TimeSpan.FromMilliseconds(durationMs),
                EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }
            };
            var animY = new DoubleAnimation
            {
                To = targetTop,
                Duration = TimeSpan.FromMilliseconds(durationMs),
                EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }
            };

            animX.Completed += (_, _) =>
            {
                BeginAnimation(LeftProperty, null);
                Left = targetLeft;
                Model.X = targetLeft;
                EndProgrammaticMove();
            };
            animY.Completed += (_, _) =>
            {
                BeginAnimation(TopProperty, null);
                Top = targetTop;
                Model.Y = targetTop;
                EndProgrammaticMove();
            };

            BeginAnimation(LeftProperty, animX);
            BeginAnimation(TopProperty, animY);
        }

        /// <summary>释放一次程序移动的抑制计数（X / Y 动画各调一次）</summary>
        private void EndProgrammaticMove()
        {
            if (_programmaticMoveCount > 0) _programmaticMoveCount--;
        }
    }
}
