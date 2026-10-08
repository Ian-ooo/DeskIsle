using System;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using DeskIsle.Models;
using DeskIsle.Native;
using DeskIsle.Services;

namespace DeskIsle.Views
{
    public partial class TopBarWindow : Window
    {
        private readonly Config _config;
        /// <summary>本顶栏所属显示器。多显示器下每屏一个顶栏实例，各自只控制本屏分区。</summary>
        private readonly System.Windows.Forms.Screen _screen;
        private readonly Action _onNewPartition;
        private readonly Action _onToggleGhost;
        private readonly Action<string> _onAlign;
        private readonly Action _onOpenSettings;
        private readonly Action _onHideTopBar;
        private readonly Action _onQuit;

        /// <summary>
        /// 用户是否手动拖动过这条顶栏。
        /// 拖动过之后就不再做「居中跟随宽度」—— 否则内容一变，
        /// 精心挪过去的顶栏会自己跳回屏幕中间。
        /// </summary>
        private bool _userMoved;

        private static readonly Brush AmberBrush = MakeFrozen(Color.FromRgb(0xFF, 0xB9, 0x00));
        private static readonly Brush IdleBrush = MakeFrozen(Color.FromArgb(0xC8, 0xFF, 0xFF, 0xFF));

        private static Brush MakeFrozen(Color color)
        {
            var brush = new SolidColorBrush(color);
            brush.Freeze();
            return brush;
        }

        private static App? Host => Application.Current as App;

        public TopBarWindow(
            System.Windows.Forms.Screen screen,
            Config config,
            Action onNewPartition,
            Action onToggleGhost,
            Action<string> onAlign,
            Action onOpenSettings,
            Action onHideTopBar,
            Action onQuit)
        {
            InitializeComponent();
            _screen = screen;
            _config = config;
            _onNewPartition = onNewPartition;
            _onToggleGhost = onToggleGhost;
            _onAlign = onAlign;
            _onOpenSettings = onOpenSettings;
            _onHideTopBar = onHideTopBar;
            _onQuit = onQuit;

            Loaded += (_, _) =>
            {
                var handle = new WindowInteropHelper(this).Handle;
                Win32.ApplyAcrylic(handle);
                ApplyMaxWidth();
                PositionTopCenter();
            };

            // 宽度随内容变化（状态高亮、按钮图标切换都会改宽度），换完要重新居中。
            // 用 SizeChanged 而不是写死宽度常量 —— 这样「再加一个按钮」不会把品牌名挤掉。
            SizeChanged += (_, _) =>
            {
                ApplyMaxWidth();
                PositionTopCenter();
            };

            UpdateState();
            _config.OnConfigChanged += UpdateState;

            // 顶栏会在「显示器插拔 / 分辨率变化」时被整批关闭重建，
            // 不在这里退订就会累积一堆已死窗口的事件订阅（每插拔一次多一份）。
            Closed += (_, _) => _config.OnConfigChanged -= UpdateState;

            // 允许拖拽顶部栏（仅当真的发生了位移才记为「用户自定义位置」）
            MouseDown += (s, e) =>
            {
                if (e.ChangedButton != System.Windows.Input.MouseButton.Left) return;
                double beforeLeft = Left;
                DragMove();
                if (Math.Abs(Left - beforeLeft) > 0.5) _userMoved = true;
            };
        }

        /// <summary>本顶栏所属显示器标识（DeviceName）。</summary>
        public string ScreenId => MonitorService.DeviceIdOf(_screen);

        public void PositionTopCenter()
        {
            if (_userMoved) return;
            try
            {
                // 定位到「本顶栏所属显示器」顶部居中（原来固定用主屏工作区）
                var workArea = MonitorService.WorkingAreaDIP(_screen, this);
                // SizeToContent=Width 时 Width 是 NaN，首次布局前 ActualWidth 也为 0 —— 用最小宽度兜底
                double w = ActualWidth > 0 ? ActualWidth : (double.IsNaN(Width) ? MinWidth : Width);
                Left = workArea.Left + (workArea.Width - w) / 2;
                Top = workArea.Top + 16;
            }
            catch
            {
                // 定位失败不该让顶栏消失，留在原处也能用
            }
        }

        /// <summary>
        /// 宽度上限 = 本屏工作区宽 − 40（左右各留 20 的呼吸位）。
        /// 必须在代码里算：XAML 无法表达「屏幕宽度」这类运行时量。
        /// </summary>
        private void ApplyMaxWidth()
        {
            try
            {
                var workArea = MonitorService.WorkingAreaDIP(_screen, this);
                double max = Math.Max(MinWidth, workArea.Width - 40);
                if (double.IsInfinity(MaxWidth) || Math.Abs(MaxWidth - max) > 0.5) MaxWidth = max;
            }
            catch { }
        }

        public void UpdateState()
        {
            Dispatcher.Invoke(() =>
            {
                UpdateNormalState();

                ApplyMaxWidth();
                PositionTopCenter();
            });
        }

        private void UpdateNormalState()
        {
            // Fluent View: &#xE890;
            // 显隐按钮反映**本屏**状态（多显示器下每屏独立）
            GhostBtn.Foreground = _config.IsScreenHidden(ScreenId) ? AmberBrush : IdleBrush;

            // 对齐高亮反映**本屏**的模式（多显示器下每屏独立设置）
            string mode = _config.AlignModeFor(ScreenId);
            AlignTopBtn.IsChecked = mode == "top";
            AlignLeftBtn.IsChecked = mode == "left";
            AlignRightBtn.IsChecked = mode == "right";
            AlignGridBtn.IsChecked = mode == "grid";
        }

        // MARK: - 常规条

        private void NewPartition_Click(object sender, RoutedEventArgs e) => _onNewPartition();
        private void Search_Click(object sender, RoutedEventArgs e) => Host?.OpenGlobalSearch();
        private void GhostMode_Click(object sender, RoutedEventArgs e) => _onToggleGhost();
        private void AlignTop_Click(object sender, RoutedEventArgs e) => _onAlign("top");
        private void AlignLeft_Click(object sender, RoutedEventArgs e) => _onAlign("left");
        private void AlignRight_Click(object sender, RoutedEventArgs e) => _onAlign("right");
        private void AlignGrid_Click(object sender, RoutedEventArgs e) => _onAlign("grid");
        private void Settings_Click(object sender, RoutedEventArgs e) => _onOpenSettings();
        private void HideTopBar_Click(object sender, RoutedEventArgs e) => _onHideTopBar();
        private void Quit_Click(object sender, RoutedEventArgs e) => _onQuit();
    }
}
