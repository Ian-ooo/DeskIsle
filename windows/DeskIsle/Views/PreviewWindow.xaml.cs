using System;
using System.IO;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media.Imaging;
using DeskIsle.Services;

namespace DeskIsle.Views
{
    /// <summary>
    /// 图片**预览窗口** —— 双击图片时弹出（对应 mac 的 <c>QuickPreviewPanel</c>、
    /// Electron 的 <c>ImagePreview</c>）。
    ///
    /// 为什么不直接 <c>Process.Start</c>：那会把系统的「照片」应用拉到前台，
    /// 用户只是想看一眼，整个前台却被换走了 —— 与 mac / Electron 端口径一致的做法
    /// 是自己画一个浮层。
    ///
    /// 关闭方式：右上角 ✕ / Esc / 点击图片以外的区域。
    /// </summary>
    public partial class PreviewWindow : Window
    {
        private static PreviewWindow? _currentInstance;
        private string? _hostPath;

        public static bool IsShowing => _currentInstance != null && _currentInstance.IsVisible;
        public static string? CurrentPath => _currentInstance?._hostPath;

        private PreviewWindow()
        {
            InitializeComponent();
            Closed += (_, _) =>
            {
                if (_currentInstance == this) _currentInstance = null;
            };
        }

        /// <summary>
        /// 预览一张图片。**同步返回**（见下方「为什么要先 Show 后定位」）。
        /// 加载失败（文件没了 / 格式解不开）时返回 false，调用方据此回退到外部打开。
        private static readonly System.Collections.Generic.HashSet<string> TextExtensions = new(StringComparer.OrdinalIgnoreCase)
        {
            ".txt", ".md", ".markdown", ".json", ".js", ".jsx", ".ts", ".tsx",
            ".cs", ".xaml", ".xml", ".html", ".htm", ".css", ".scss", ".py",
            ".c", ".cpp", ".h", ".hpp", ".sql", ".ini", ".conf", ".env",
            ".yml", ".yaml", ".toml", ".log", ".csv", ".bat", ".cmd", ".ps1"
        };

        /// <summary>
        /// 预览文件（图片或文本代码文件）。**同步返回**。
        /// 加载失败（文件没了 / 格式解不开）时返回 false，调用方据此回退到外部打开。
        /// </summary>
        public static bool Show(string path)
        {
            if (string.IsNullOrEmpty(path) || !File.Exists(path)) return false;

            string ext = Path.GetExtension(path);
            if (TextExtensions.Contains(ext))
            {
                try
                {
                    string text;
                    using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                    using (var reader = new StreamReader(stream))
                    {
                        var buf = new char[256 * 1024];
                        int read = reader.ReadBlock(buf, 0, buf.Length);
                        text = new string(buf, 0, read);
                    }
                    var win = _currentInstance ?? new PreviewWindow { Opacity = 0 };
                    _currentInstance = win;
                    win._hostPath = path;
                    win.PreviewImage.Visibility = Visibility.Collapsed;
                    win.PreviewTextBox.Visibility = Visibility.Visible;
                    win.PreviewTextBox.Text = text;
                    win.NameText.Text = Path.GetFileName(path);

                    int lines = text.Split('\n').Length;
                    string bytesText = "";
                    try { bytesText = FormatBytes(new FileInfo(path).Length); } catch { }
                    win.MetaText.Text = $"{lines} 行文本{(string.IsNullOrEmpty(bytesText) ? "" : "　·　" + bytesText)}";

                    if (!win.IsVisible) win.Show();
                    win.SizeToFit(600, 440);
                    win.Opacity = 1;
                    win.Activate();
                    return true;
                }
                catch { return false; }
            }

            BitmapImage bmp;
            try
            {
                bmp = new BitmapImage();
                bmp.BeginInit();
                // ⚠️ OnLoad：立刻把整个文件读进内存并**松开文件句柄**。
                // 默认的延迟加载会锁住文件 —— 用户随后重命名 / 删除就会失败。
                bmp.CacheOption = BitmapCacheOption.OnLoad;
                bmp.UriSource = new Uri(path, UriKind.Absolute);
                bmp.EndInit();
                bmp.Freeze();   // 允许跨线程使用，也让 WPF 少维护一份可变状态
            }
            catch
            {
                // 格式解不开（HEIF / AVIF 没装系统解码器）或刚好被删 —— 交给外部程序
                return false;
            }

            int w = bmp.PixelWidth;
            int h = bmp.PixelHeight;

            var winImg = _currentInstance ?? new PreviewWindow { Opacity = 0 };   // 先藏：定位前别让用户看到窗口跳一次
            _currentInstance = winImg;
            winImg._hostPath = path;
            winImg.PreviewImage.Visibility = Visibility.Visible;
            winImg.PreviewTextBox.Visibility = Visibility.Collapsed;
            winImg.PreviewImage.Source = bmp;
            winImg.NameText.Text = Path.GetFileName(path);

            string bytesText;
            try { bytesText = FormatBytes(new FileInfo(path).Length); }
            catch { bytesText = ""; }
            winImg.MetaText.Text = $"{w} × {h}{(string.IsNullOrEmpty(bytesText) ? "" : "　·　" + bytesText)}";

            // 为什么先 Show 后定位：`WorkingAreaDIP` 要拿 DPI 换算矩阵，而矩阵来自
            // `PresentationSource` —— 窗口没 Show 之前它为 null，算出来的位置/尺寸
            // 在 125% / 150% 缩放的屏上会明显偏大。
            if (!winImg.IsVisible) winImg.Show();
            winImg.SizeToFit(w, h);
            winImg.Opacity = 1;
            winImg.Activate();
            return true;
        }

        /// <summary>窗口大小：按**光标所在屏的工作区**等比缩放；小图不放大超过 1:1。</summary>
        private void SizeToFit(int pixelW, int pixelH)
        {
            Rect area;
            try { area = MonitorService.WorkingAreaDIP(MonitorService.ScreenUnderCursor(), this); }
            catch { area = SystemParameters.WorkArea; }

            if (pixelW <= 0 || pixelH <= 0)
            {
                Width = Math.Min(520, area.Width);
                Height = Math.Min(420, area.Height);
                CenterIn(area);
                return;
            }

            const double chromeW = 40;   // 左右边距
            const double chromeH = 100;  // 标题条 + 信息条 + 上下边距
            double availW = Math.Max(360, area.Width - chromeW);
            double availH = Math.Max(280, area.Height - chromeH);
            double scale = Math.Min(Math.Min(availW / pixelW, availH / pixelH), 1.0);

            // 小图给个体面的下限，别缩成一个火柴盒
            Width = Math.Max(360, Math.Min(availW, pixelW * scale + chromeW));
            Height = Math.Max(280, Math.Min(availH, pixelH * scale + chromeH));
            CenterIn(area);
        }

        private void CenterIn(Rect area)
        {
            Left = area.Left + (area.Width - Width) / 2;
            Top = area.Top + (area.Height - Height) / 2;
        }

        private static string FormatBytes(long bytes)
        {
            string[] units = { "B", "KB", "MB", "GB" };
            double n = bytes;
            int i = 0;
            while (n >= 1024 && i < units.Length - 1) { n /= 1024; i++; }
            return $"{(n >= 10 || i == 0 ? Math.Round(n) : Math.Round(n, 1))} {units[i]}";
        }

        // MARK: - 关闭

        private void Window_KeyDown(object sender, KeyEventArgs e)
        {
            if (e.Key == Key.Escape || e.Key == Key.Space) Close();
        }

        private void CloseButton_Click(object sender, RoutedEventArgs e) => Close();

        /// <summary>
        /// 点图片以外的区域 = 关闭。图片自己会把 Handled 置 true，所以点图不会误关。
        /// </summary>
        private void Window_MouseDown(object sender, MouseButtonEventArgs e)
        {
            if (!e.Handled) Close();
        }

        private void Image_MouseDown(object sender, MouseButtonEventArgs e)
        {
            e.Handled = true;   // 点图片本身不关闭
        }
    }
}
