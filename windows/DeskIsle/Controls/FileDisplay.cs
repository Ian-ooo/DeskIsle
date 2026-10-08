using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Windows.Media;

namespace DeskIsle.Controls
{
    /// <summary>
    /// 分区内一个文件 / 目录条目的展示模型。各分区视图共用。
    ///
    /// ⚠️ 实现了 <see cref="INotifyPropertyChanged"/>：选中态（`IsSelected`）改的是**数据**，
    /// 而 XAML 里靠 DataTrigger 把它翻成高亮底 —— 没有通知的话界面不会重画，
    /// 表现就是「点了有反应但不高亮」。
    /// </summary>
    public class FileDisplayItem : INotifyPropertyChanged
    {
        private bool _isSelected;

        public string Path { get; set; } = string.Empty;
        public string Name { get; set; } = string.Empty;
        public string Icon { get; set; } = "📄";
        public ImageSource? IconImage { get; set; }
        public string SizeText { get; set; } = string.Empty;
        public bool IsDirectory { get; set; }

        public bool IsSelected
        {
            get => _isSelected;
            set
            {
                if (_isSelected == value) return;
                _isSelected = value;
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsSelected)));
            }
        }

        public event PropertyChangedEventHandler? PropertyChanged;
    }

    /// <summary>
    /// 文件条目的展示辅助 —— 图标、大小文本、打开与定位。
    ///
    /// 原先挂在已移除的收集箱视图上，导致 portal 也得依赖那个视图；
    /// 抽到这里之后，删掉任何一类分区的视图都不会牵连到别的分区视图。
    /// </summary>
    public static class FileUI
    {
        public static string GetFileIcon(string ext)
        {
            ext = ext.ToLowerInvariant();
            return ext switch
            {
                ".png" or ".jpg" or ".jpeg" or ".gif" or ".webp" or ".svg" or ".ico" or ".bmp" => "🖼️",
                ".pdf" or ".doc" or ".docx" or ".txt" or ".md" or ".rtf" => "📄",
                ".xls" or ".xlsx" or ".csv" => "📊",
                ".ppt" or ".pptx" => "📑",
                ".zip" or ".rar" or ".7z" or ".tar" or ".gz" => "📦",
                ".mp3" or ".wav" or ".flac" or ".aac" or ".m4a" => "🎵",
                ".mp4" or ".mov" or ".avi" or ".mkv" or ".webm" => "🎬",
                ".cs" or ".js" or ".ts" or ".py" or ".cpp" or ".h" or ".json" or ".html" or ".css" => "💻",
                ".exe" or ".msi" or ".bat" or ".cmd" or ".ps1" => "⚙️",
                _ => "📄"
            };
        }

        public static string FormatFileSize(long bytes)
        {
            if (bytes < 1024) return $"{bytes} B";
            if (bytes < 1024 * 1024) return $"{(bytes / 1024.0):F1} KB";
            if (bytes < 1024 * 1024 * 1024) return $"{(bytes / (1024.0 * 1024)):F1} MB";
            return $"{(bytes / (1024.0 * 1024 * 1024)):F1} GB";
        }

        public static void OpenFile(string path)
        {
            try
            {
                Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
            }
            catch { }
        }

        public static void RevealInExplorer(string path)
        {
            try
            {
                Process.Start("explorer.exe", $"/select,\"{path}\"");
            }
            catch { }
        }
    }
}
