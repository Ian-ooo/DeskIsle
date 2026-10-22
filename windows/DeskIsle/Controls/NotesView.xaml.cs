using System;
using System.Diagnostics;
using System.IO;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using DeskIsle.Models;
using DeskIsle.Views;

namespace DeskIsle.Controls
{
    public partial class NotesView : UserControl
    {
        private PartitionModel? _partition;
        private Action? _onDataChanged;
        private DispatcherTimer? _debounceTimer;
        /// <summary>这次点击已经要求收起占位，焦点来回抖一下时不要把它画回来。</summary>
        private bool _clickHidesPlaceholder;
        /// <summary>刚点下去的时刻。窗口激活被回滚时，紧接着的失焦不能把提示又画出来。</summary>
        private DateTime _clickedAt;
        private Window? _host;

        private static readonly Regex UrlRegex = new Regex(@"https?://[^\s<>""']+", RegexOptions.Compiled | RegexOptions.IgnoreCase);
        private static readonly Regex IpRegex = new Regex(@"\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?::[0-9]{1,5})?(?:/[^\s<>""']*)?\b", RegexOptions.Compiled);

        public NotesView()
        {
            InitializeComponent();
            Loaded += OnLoaded;
            Unloaded += OnUnloaded;
        }

        private void OnLoaded(object sender, RoutedEventArgs e)
        {
            DetachHost();
            _host = Window.GetWindow(this);
            if (_host == null) return;
            _host.Activated += Host_Activated;
            _host.Deactivated += Host_Deactivated;
        }

        private void OnUnloaded(object sender, RoutedEventArgs e) => DetachHost();

        private void DetachHost()
        {
            if (_host == null) return;
            _host.Activated -= Host_Activated;
            _host.Deactivated -= Host_Deactivated;
            _host = null;
        }

        private void Host_Activated(object? sender, EventArgs e)
        {
            if (!_clickHidesPlaceholder) return;
            if (!NotesTextBox.IsKeyboardFocused && !NotesTextBox.IsMouseOver) return;
            ApplyPlaceholder(cursorInside: true);
            NotesTextBox.Focus();
            Keyboard.Focus(NotesTextBox);
        }

        private void Host_Deactivated(object? sender, EventArgs e)
        {
            if (JustClicked()) return;
            _clickHidesPlaceholder = false;
            ApplyPlaceholder(cursorInside: false);
        }

        public void BindData(PartitionModel partition, Action onDataChanged)
        {
            _partition = partition;
            _onDataChanged = onDataChanged;
            NotesTextBox.Text = _partition.NoteContent ?? string.Empty;
            UpdateStats();
        }

        private void NotesTextBox_TextChanged(object sender, TextChangedEventArgs e)
        {
            UpdateStats();
            if (_partition == null) return;

            _partition.NoteContent = NotesTextBox.Text;

            _debounceTimer?.Stop();
            _debounceTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(400) };
            _debounceTimer.Tick += (_, _) =>
            {
                _debounceTimer.Stop();
                _onDataChanged?.Invoke();
            };
            _debounceTimer.Start();
        }

        private void UpdateStats()
        {
            ApplyPlaceholder(NotesTextBox.IsKeyboardFocused || _clickHidesPlaceholder);
            int lines = string.IsNullOrEmpty(NotesTextBox.Text) ? 0 : NotesTextBox.Text.Split('\n').Length;
            StatsText.Text = $"{NotesTextBox.Text.Length} 字符 · {lines} 行";
        }

        /// <summary>空白、且没有点在便签里时才提示。鼠标一点下去就收起。</summary>
        private void ApplyPlaceholder(bool cursorInside)
        {
            PlaceholderText.Visibility = string.IsNullOrEmpty(NotesTextBox.Text) && !cursorInside
                ? Visibility.Visible
                : Visibility.Collapsed;
        }

        private void NotesTextBox_GotKeyboardFocus(object sender, KeyboardFocusChangedEventArgs e)
        {
            ApplyPlaceholder(cursorInside: true);
        }

        private void NotesTextBox_LostKeyboardFocus(object sender, KeyboardFocusChangedEventArgs e)
        {
            if (JustClicked() || (_clickHidesPlaceholder && NotesTextBox.IsMouseOver))
            {
                ApplyPlaceholder(cursorInside: true);
                return;
            }
            _clickHidesPlaceholder = false;
            ApplyPlaceholder(cursorInside: false);
        }

        private void NotesTextBox_PreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
        {
            // 先收起提示，再要焦点。窗口还没激活时 GotKeyboardFocus 不一定来得及。
            _clickHidesPlaceholder = true;
            _clickedAt = DateTime.UtcNow;
            ApplyPlaceholder(cursorInside: true);
            if (Window.GetWindow(this) is PartitionWindow partition)
                partition.ActivateAsNormalWindow();
            NotesTextBox.Focus();
            Keyboard.Focus(NotesTextBox);
        }

        private bool JustClicked() =>
            _clickHidesPlaceholder && (DateTime.UtcNow - _clickedAt).TotalSeconds < 0.5;

        private void NotesTextBox_PreviewMouseLeftButtonUp(object sender, MouseButtonEventArgs e)
        {
            if ((Keyboard.Modifiers & ModifierKeys.Control) == ModifierKeys.Control)
            {
                var pt = e.GetPosition(NotesTextBox);
                int idx = NotesTextBox.GetCharacterIndexFromPoint(pt, true);
                var link = FindLinkAt(idx);
                if (!string.IsNullOrEmpty(link))
                {
                    OpenUrl(link);
                    e.Handled = true;
                }
            }
        }

        private void NotesTextBox_ContextMenuOpening(object sender, ContextMenuEventArgs e)
        {
            Point mousePos = Mouse.GetPosition(NotesTextBox);
            int idx = NotesTextBox.GetCharacterIndexFromPoint(mousePos, true);
            if (idx < 0) idx = NotesTextBox.CaretIndex;

            string? link = FindLinkAt(idx);

            var contextMenu = new ContextMenu();
            if (!string.IsNullOrEmpty(link))
            {
                var openItem = new MenuItem { Header = "在浏览器中打开链接" };
                openItem.Click += (_, _) => OpenUrl(link);
                contextMenu.Items.Add(openItem);

                var copyLinkItem = new MenuItem { Header = "拷贝链接地址" };
                copyLinkItem.Click += (_, _) => Clipboard.SetText(link);
                contextMenu.Items.Add(copyLinkItem);

                contextMenu.Items.Add(new Separator());
            }

            var cutItem = new MenuItem { Header = "剪切", Command = ApplicationCommands.Cut };
            var copyItem = new MenuItem { Header = "复制", Command = ApplicationCommands.Copy };
            var pasteItem = new MenuItem { Header = "粘贴", Command = ApplicationCommands.Paste };
            var selectAllItem = new MenuItem { Header = "全选", Command = ApplicationCommands.SelectAll };

            contextMenu.Items.Add(cutItem);
            contextMenu.Items.Add(copyItem);
            contextMenu.Items.Add(pasteItem);
            contextMenu.Items.Add(new Separator());
            contextMenu.Items.Add(selectAllItem);

            if (!string.IsNullOrWhiteSpace(NotesTextBox.Text))
            {
                contextMenu.Items.Add(new Separator());
                var copyAllItem = new MenuItem { Header = "拷贝全文" };
                copyAllItem.Click += (_, _) =>
                {
                    Clipboard.SetText(NotesTextBox.Text);
                    ToastWindow.ShowToast("已拷贝便签全文", "");
                };
                contextMenu.Items.Add(copyAllItem);

                var exportItem = new MenuItem { Header = "导出为文本文档 (.txt)..." };
                exportItem.Click += (_, _) => ExportToTxt();
                contextMenu.Items.Add(exportItem);

                contextMenu.Items.Add(new Separator());
                var clearItem = new MenuItem { Header = "清空便签" };
                clearItem.Click += (_, _) =>
                {
                    NotesTextBox.Text = string.Empty;
                    ToastWindow.ShowToast("已清空便签", "");
                };
                contextMenu.Items.Add(clearItem);
            }

            NotesTextBox.ContextMenu = contextMenu;
        }

        private void ExportBtn_Click(object sender, RoutedEventArgs e) => ExportToTxt();

        private void ExportToTxt()
        {
            string content = NotesTextBox.Text;
            if (string.IsNullOrEmpty(content)) return;

            var sfd = new Microsoft.Win32.SaveFileDialog
            {
                Title = "导出便签",
                FileName = "便签.txt",
                Filter = "文本文档 (*.txt)|*.txt|所有文件 (*.*)|*.*",
                DefaultExt = ".txt"
            };

            if (sfd.ShowDialog() == true)
            {
                try
                {
                    File.WriteAllText(sfd.FileName, content);
                    ToastWindow.ShowToast("便签已成功导出", Path.GetFileName(sfd.FileName), warn: false);
                }
                catch (Exception ex)
                {
                    ToastWindow.ShowToast("导出失败", ex.Message, warn: true);
                }
            }
        }

        private string? FindLinkAt(int charIndex)
        {
            string text = NotesTextBox.Text;
            if (string.IsNullOrEmpty(text) || charIndex < 0 || charIndex > text.Length) return null;

            // Check standard URL matches first
            foreach (Match match in UrlRegex.Matches(text))
            {
                if (charIndex >= match.Index && charIndex <= match.Index + match.Length)
                {
                    return match.Value;
                }
            }

            // Check bare IP matches
            foreach (Match match in IpRegex.Matches(text))
            {
                if (charIndex >= match.Index && charIndex <= match.Index + match.Length)
                {
                    string val = match.Value;
                    if (!val.StartsWith("http://", StringComparison.OrdinalIgnoreCase) &&
                        !val.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
                    {
                        return "http://" + val;
                    }
                    return val;
                }
            }

            return null;
        }

        private void OpenUrl(string url)
        {
            try
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = url,
                    UseShellExecute = true
                });
            }
            catch
            {
                // Ignore failure if URL cannot be launched
            }
        }

        private void UserControl_DragOver(object sender, DragEventArgs e)
        {
            if (e.Data.GetDataPresent(DataFormats.FileDrop))
            {
                e.Effects = DragDropEffects.Copy;
                e.Handled = true;
            }
        }

        private void UserControl_Drop(object sender, DragEventArgs e)
        {
            if (e.Data.GetDataPresent(DataFormats.FileDrop))
            {
                string[] files = (string[])e.Data.GetData(DataFormats.FileDrop);
                string textToAppend = string.Join(Environment.NewLine, files);

                if (!string.IsNullOrEmpty(NotesTextBox.Text) && !NotesTextBox.Text.EndsWith(Environment.NewLine))
                {
                    NotesTextBox.AppendText(Environment.NewLine);
                }
                NotesTextBox.AppendText(textToAppend);
            }
        }
    }
}
