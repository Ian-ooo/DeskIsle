using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using DeskIsle.Native;
using DeskIsle.Services;

namespace DeskIsle.Views
{
    /// <summary>
    /// 轻量瞬时提示（Toast）—— 用于「为什么这一下没生效」这类**必须当场说清**的反馈。
    ///
    /// 为什么不用 MessageBox：锁定态下点删除 / 折叠 / 自适应都会被拦，
    /// 若每次都弹一个要用户点「确定」的模态框，锁定就变成了惩罚；
    /// 而完全不提示又会让用户以为程序卡了、反复点。
    /// 一条 1.8 秒自动消失、不抢焦点、鼠标穿透的横幅，正好卡在中间。
    ///
    /// 提示文案分三种（分区锁 / 屏幕锁 / 两者都锁）—— 只说「已锁定」
    /// 会把用户引到一个解不开的地方（他去分区里找不到解锁项，因为锁在屏幕级）。
    ///
    /// 用纯代码构建、不走 XAML：这个窗口只有十来个元素，
    /// 而 XAML + 代码后置的 x:Name 耦合对新增文件来说是纯粹的出错面。
    /// </summary>
    public sealed class ToastWindow : Window
    {
        private const double ToastWidth = 320.0;
        private static ToastWindow? _current;

        private readonly System.Windows.Controls.TextBlock _title;
        private readonly System.Windows.Controls.TextBlock _detail;
        private readonly Border _root;
        private readonly DispatcherTimer _holdTimer;

        private ToastWindow(bool warn)
        {
            WindowStyle = WindowStyle.None;
            AllowsTransparency = true;
            Background = Brushes.Transparent;
            ResizeMode = ResizeMode.NoResize;
            ShowInTaskbar = false;
            Topmost = true;
            ShowActivated = false;          // 绝不抢焦点：用户可能正在打字
            Focusable = false;
            IsHitTestVisible = false;       // 鼠标穿透：别挡住下面真正想点的东西
            FontFamily = (FontFamily)Application.Current.Resources["FluentFontFamily"];
            SizeToContent = SizeToContent.Height;
            Width = ToastWidth;
            Opacity = 0;

            var accent = warn
                ? new SolidColorBrush(Color.FromRgb(255, 185, 0))     // Fluent 琥珀：警告
                : new SolidColorBrush(Color.FromRgb(0, 120, 212));    // Fluent 强调蓝：信息

            var layout = new System.Windows.Controls.StackPanel();

            _title = new System.Windows.Controls.TextBlock
            {
                Foreground = new SolidColorBrush(Color.FromRgb(0xF5, 0xF5, 0xF5)),
                FontSize = 12.5,
                FontWeight = FontWeights.SemiBold,
                TextWrapping = TextWrapping.Wrap
            };
            _detail = new System.Windows.Controls.TextBlock
            {
                Foreground = new SolidColorBrush(Color.FromArgb(0x99, 0xFF, 0xFF, 0xFF)),
                FontSize = 10.5,
                Margin = new Thickness(0, 4, 0, 0),
                TextWrapping = TextWrapping.Wrap
            };

            layout.Children.Add(_title);
            layout.Children.Add(_detail);

            _root = new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(0xF0, 0x1C, 0x1C, 0x22)),
                BorderBrush = new SolidColorBrush(Color.FromArgb(0x33, 0xFF, 0xFF, 0xFF)),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(10),
                Padding = new Thickness(14, 10, 14, 10),
                Child = layout
            };

            // 左侧竖条用强调色标出语气（警告 / 信息），不额外加图标
            var stripe = new Border
            {
                Width = 3,
                CornerRadius = new CornerRadius(2),
                Background = accent,
                Margin = new Thickness(0, 0, 10, 0)
            };

            var grid = new System.Windows.Controls.Grid();
            grid.ColumnDefinitions.Add(new System.Windows.Controls.ColumnDefinition { Width = GridLength.Auto });
            grid.ColumnDefinitions.Add(new System.Windows.Controls.ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            System.Windows.Controls.Grid.SetColumn(stripe, 0);
            System.Windows.Controls.Grid.SetColumn(layout, 1);
            grid.Children.Add(stripe);
            grid.Children.Add(layout);

            _root.Child = grid;
            Content = _root;

            _holdTimer = new DispatcherTimer();
            _holdTimer.Tick += (_, _) =>
            {
                _holdTimer.Stop();
                FadeOutAndClose();
            };
        }

        protected override void OnSourceInitialized(EventArgs e)
        {
            base.OnSourceInitialized(e);

            // 再加两道 Win32 保险（ShowActivated / Focusable 已经拦了大部分情况）：
            // WS_EX_NOACTIVATE 保证点击也不会激活它，WS_EX_TRANSPARENT 让它彻底鼠标穿透。
            var handle = new WindowInteropHelper(this).Handle;
            if (handle == IntPtr.Zero) return;
            var ex = Win32.GetWindowLongPtr(handle, Win32.GWL_EXSTYLE).ToInt64();
            ex |= Win32.WS_EX_NOACTIVATE | Win32.WS_EX_TOOLWINDOW | Win32.WS_EX_TRANSPARENT;
            Win32.SetWindowLongPtr(handle, Win32.GWL_EXSTYLE, new IntPtr(ex));
        }

        /// <summary>
        /// 弹一条提示。
        /// </summary>
        /// <param name="title">主句（一句话说清「没做成什么」）</param>
        /// <param name="detail">副句（告诉用户「那该怎么办」）</param>
        /// <param name="warn">true = 琥珀色警告语气，false = 蓝色信息语气</param>
        /// <param name="durationMs">停留时长（不含淡入淡出）</param>
        public static void ShowToast(string title, string? detail = null, bool warn = true, int durationMs = 1800)
        {
            var app = Application.Current;
            if (app == null) return;

            app.Dispatcher.Invoke(() =>
            {
                // 复用同一个实例：连着点两下删除只会刷新文案，
                // 不会叠出两条互相错位的横幅。
                if (_current != null)
                {
                    _current.Retarget(title, detail, warn, durationMs);
                    return;
                }

                var toast = new ToastWindow(warn);
                _current = toast;
                toast._title.Text = title;
                toast._detail.Text = detail ?? string.Empty;
                toast._detail.Visibility = string.IsNullOrEmpty(detail) ? Visibility.Collapsed : Visibility.Visible;
                toast._holdTimer.Interval = TimeSpan.FromMilliseconds(Math.Max(600, durationMs));

                toast.Show();
                // SizeToContent 的高度要等一次布局走完才拿得到，否则定位会按 0 计算，
                // 横幅会出现在屏幕最底端外侧（看起来像「提示没出来」）。
                toast.UpdateLayout();
                toast.Reposition();
                toast.FadeIn();
                toast._holdTimer.Start();
            });
        }

        private void Retarget(string title, string? detail, bool warn, int durationMs)
        {
            _title.Text = title;
            _detail.Text = detail ?? string.Empty;
            _detail.Visibility = string.IsNullOrEmpty(detail) ? Visibility.Collapsed : Visibility.Visible;
            _holdTimer.Interval = TimeSpan.FromMilliseconds(Math.Max(600, durationMs));
            _holdTimer.Stop();
            _holdTimer.Start();

            // 从当前透明度继续淡入（可能是上一次的淡出中途被打断）
            if (Opacity < 1.0) FadeIn();
        }

        /// <summary>落位到「光标所在屏」底部居中偏上 —— 提示应该出现在用户视线正在的地方。</summary>
        private void Reposition()
        {
            try
            {
                var screen = MonitorService.ScreenUnderCursor();
                var workArea = MonitorService.WorkingAreaDIP(screen, this);
                double w = ActualWidth > 0 ? ActualWidth : ToastWidth;
                double h = ActualHeight > 0 ? ActualHeight : 48;
                Left = workArea.Left + (workArea.Width - w) / 2;
                Top = workArea.Bottom - h - 72;
            }
            catch
            {
                // 定位失败不该让提示本身报错：留在系统默认位置也能看
            }
        }

        private void FadeIn()
        {
            var anim = new DoubleAnimation
            {
                From = Opacity,
                To = 1.0,
                Duration = TimeSpan.FromMilliseconds(140),
                EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut }
            };
            BeginAnimation(OpacityProperty, anim);
        }

        private void FadeOutAndClose()
        {
            var anim = new DoubleAnimation
            {
                From = Opacity,
                To = 0.0,
                Duration = TimeSpan.FromMilliseconds(180),
                EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseIn }
            };
            anim.Completed += (_, _) =>
            {
                BeginAnimation(OpacityProperty, null);
                if (ReferenceEquals(_current, this)) _current = null;
                Close();
            };
            BeginAnimation(OpacityProperty, anim);
        }
    }
}
