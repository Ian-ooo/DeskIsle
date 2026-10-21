using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using DeskIsle.Controls;
using DeskIsle.Models;
using DeskIsle.Native;
using DeskIsle.Services;

namespace DeskIsle.Views
{
    /// <summary>
    /// 一条搜索结果。刻意只做**数据载体**，不带任何界面引用 ——
    /// 否则「按得分排序」这件事会被控件的生命周期绑住，排序逻辑就没法单独验证了。
    /// </summary>
    public sealed class SearchHit
    {
        public string Kind { get; set; } = "file";       // file / todo / note
        public string PartitionId { get; set; } = string.Empty;
        public string PartitionTitle { get; set; } = string.Empty;
        public string Title { get; set; } = string.Empty;
        public string Subtitle { get; set; } = string.Empty;
        public string Path { get; set; } = string.Empty;
        public bool IsDirectory { get; set; }
        public int Score { get; set; }
    }

    /// <summary>
    /// 全局搜索（对齐 mac 端 <c>GlobalSearch</c> / <c>GlobalSearchView</c>）。
    ///
    /// 三处刻意的取舍：
    /// 1. **按分区所在屏弹出**：把面板弹在光标所在显示器，而不是主屏 ——
    ///    多屏用户在副屏按快捷键，结果却出现在另一块屏上，是最容易让人以为「没反应」的错法。
    /// 2. **目录列举带 5 秒缓存**：搜索必须**每次按键就重算**，若不缓存，
    ///    每敲一个字符就把所有映射目录重新列一遍，在机械盘或网络盘上直接卡死输入。
    ///    缓存只在「映射目录的顶层」生效，且删/建分区时由调用方清掉。
    /// 3. **只搜「已经在内存里的东西」+ 目录顶层**：不做全盘递归。
    ///    全局搜索的语义是「我记得它在哪个岛」，不是「帮我翻遍整个硬盘」。
    ///
    /// 用纯代码构建、不走 XAML：面板只有输入框 + 结果列表 + 提示条三层，
    /// 而 XAML 的 x:Name 与代码后置是一对一耦合，对新增文件来说是纯粹的出错面。
    /// </summary>
    public sealed class GlobalSearchWindow : Window
    {
        private const double PanelWidth = 580.0;
        private const int MaxResults = 60;
        private const int DirCacheTtlMs = 5000;
        private const int MaxDirEntries = 500;

        private static GlobalSearchWindow? _current;

        /// <summary>映射目录的顶层列举缓存（键 = 目录绝对路径）。</summary>
        private static readonly Dictionary<string, (DateTime At, List<string> Paths)> DirCache = new();

        private readonly Config _config;
        private readonly Action<string> _onActivatePartition;

        private readonly TextBox _input;
        private readonly StackPanel _resultsPanel;
        private readonly TextBlock _hintText;
        private readonly ScrollViewer _scroll;
        private readonly List<SearchHit> _hits = new();
        private readonly List<Border> _rows = new();
        private int _selected = -1;

        private GlobalSearchWindow(Config config, Action<string> onActivatePartition)
        {
            _config = config;
            _onActivatePartition = onActivatePartition;

            WindowStyle = WindowStyle.None;
            AllowsTransparency = true;
            Background = Brushes.Transparent;
            ResizeMode = ResizeMode.NoResize;
            ShowInTaskbar = false;
            Topmost = true;
            SizeToContent = SizeToContent.Height;
            Width = PanelWidth;
            FontFamily = (FontFamily)Application.Current.Resources["FluentFontFamily"];

            // ── 输入行 ─────────────────────────────────────────────
            var searchGlyph = new TextBlock
            {
                Text = "\uE721",                                  // Fluent Search
                FontFamily = (FontFamily)Application.Current.Resources["FluentIconFont"],
                FontSize = 15,
                Foreground = new SolidColorBrush(Color.FromArgb(0xB3, 0xFF, 0xFF, 0xFF)),
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(0, 0, 10, 0)
            };

            _input = new TextBox
            {
                Background = Brushes.Transparent,
                BorderThickness = new Thickness(0),
                Foreground = new SolidColorBrush(Color.FromRgb(0xF5, 0xF5, 0xF5)),
                CaretBrush = new SolidColorBrush(Color.FromRgb(0xFF, 0xFF, 0xFF)),
                FontSize = 14,
                VerticalContentAlignment = VerticalAlignment.Center,
                HorizontalAlignment = HorizontalAlignment.Stretch
            };
            _input.TextChanged += (_, _) => RebuildResults();
            _input.PreviewKeyDown += Input_PreviewKeyDown;

            var inputRow = new Grid { Margin = new Thickness(16, 14, 16, 12) };
            inputRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            inputRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            Grid.SetColumn(searchGlyph, 0);
            Grid.SetColumn(_input, 1);
            inputRow.Children.Add(searchGlyph);
            inputRow.Children.Add(_input);

            // ── 结果区 ─────────────────────────────────────────────
            _resultsPanel = new StackPanel();
            _scroll = new ScrollViewer
            {
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
                MaxHeight = 380,
                Padding = new Thickness(0, 0, 0, 6),
                Content = _resultsPanel
            };

            // ── 底部提示条 ─────────────────────────────────────────
            _hintText = new TextBlock
            {
                Text = "输入关键词开始搜索",
                FontSize = 10.5,
                Foreground = new SolidColorBrush(Color.FromArgb(0x80, 0xFF, 0xFF, 0xFF)),
                VerticalAlignment = VerticalAlignment.Center
            };

            var hintRow = new Border
            {
                BorderBrush = new SolidColorBrush(Color.FromArgb(0x1A, 0xFF, 0xFF, 0xFF)),
                BorderThickness = new Thickness(0, 1, 0, 0),
                Padding = new Thickness(16, 8, 16, 8),
                Background = new SolidColorBrush(Color.FromArgb(0x0D, 0xFF, 0xFF, 0xFF)),
                Child = _hintText
            };

            // ── 组装 ───────────────────────────────────────────────
            var stack = new StackPanel();
            stack.Children.Add(inputRow);
            stack.Children.Add(_scroll);
            stack.Children.Add(hintRow);

            Content = new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(0xF2, 0x1C, 0x1C, 0x22)),
                BorderBrush = new SolidColorBrush(Color.FromArgb(0x38, 0xFF, 0xFF, 0xFF)),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(12),
                Child = stack,
                Effect = new System.Windows.Media.Effects.DropShadowEffect
                {
                    BlurRadius = 22,
                    ShadowDepth = 5,
                    Direction = 270,
                    Color = Colors.Black,
                    Opacity = 0.45
                }
            };

            Deactivated += (_, _) => Close();
            PreviewKeyDown += Window_PreviewKeyDown;
        }

        protected override void OnSourceInitialized(EventArgs e)
        {
            base.OnSourceInitialized(e);
            var handle = new WindowInteropHelper(this).Handle;
            if (handle == IntPtr.Zero) return;
            var ex = Win32.GetWindowLongPtr(handle, Win32.GWL_EXSTYLE).ToInt64();
            ex |= Win32.WS_EX_TOOLWINDOW;   // 不进 Alt+Tab，搜索面板是「路过」的
            Win32.SetWindowLongPtr(handle, Win32.GWL_EXSTYLE, new IntPtr(ex));
        }

        /// <summary>打开（或前置）全局搜索面板。</summary>
        public static void Open(Config config, Action<string> onActivatePartition)
        {
            var app = Application.Current;
            if (app == null) return;

            app.Dispatcher.Invoke(() =>
            {
                if (_current != null)
                {
                    _current.Activate();
                    _current._input.SelectAll();
                    return;
                }

                var win = new GlobalSearchWindow(config, onActivatePartition);
                _current = win;
                win.Closed += (_, _) =>
                {
                    if (ReferenceEquals(_current, win)) _current = null;
                };

                win.Show();
                win.UpdateLayout();
                win.PositionPanel();
                win.RebuildResults();          // 空查询 → 显示「输入关键词」提示
                // 三端一致的预期是「按下快捷键就能直接打字」，
                // 所以既要把窗口激活，也要把键盘焦点明确交给输入框。
                win.Activate();
                win._input.Focus();
                Keyboard.Focus(win._input);
            });
        }

        /// <summary>
        /// 清掉目录列举缓存。删分区 / 新建分区 / 导入配置后必须调用 ——
        /// 否则最长 5 秒内，搜索结果里会残留已经不存在的映射目录内容。
        /// </summary>
        public static void InvalidateDirectoryCache() => DirCache.Clear();

        private void PositionPanel()
        {
            try
            {
                var screen = MonitorService.ScreenUnderCursor();
                var workArea = MonitorService.WorkingAreaDIP(screen, this);
                double w = ActualWidth > 0 ? ActualWidth : PanelWidth;
                Left = workArea.Left + (workArea.Width - w) / 2;
                Top = workArea.Top + Math.Max(60.0, workArea.Height * 0.16);
            }
            catch
            {
                // 定位失败退回系统默认位置，不影响可用性
            }
        }

        private void Window_PreviewKeyDown(object sender, KeyEventArgs e)
        {
            if (e.Key == Key.Escape)
            {
                Close();
                e.Handled = true;
            }
        }

        private void Input_PreviewKeyDown(object sender, KeyEventArgs e)
        {
            switch (e.Key)
            {
                case Key.Down:
                    MoveSelection(1);
                    e.Handled = true;
                    break;
                case Key.Up:
                    MoveSelection(-1);
                    e.Handled = true;
                    break;
                case Key.Enter:
                    InvokeSelected();
                    e.Handled = true;
                    break;
                case Key.Escape:
                    Close();
                    e.Handled = true;
                    break;
            }
        }

        private void MoveSelection(int delta)
        {
            if (_hits.Count == 0) return;
            int next = _selected + delta;
            if (next < 0) next = _hits.Count - 1;
            if (next >= _hits.Count) next = 0;
            SetSelection(next);
        }

        private void SetSelection(int index)
        {
            _selected = index;
            for (int i = 0; i < _rows.Count; i++)
            {
                bool on = i == index;
                _rows[i].Background = on
                    ? new SolidColorBrush(Color.FromArgb(0x33, 0x00, 0x78, 0xD4))
                    : Brushes.Transparent;
                _rows[i].BorderBrush = on
                    ? new SolidColorBrush(Color.FromArgb(0x66, 0x00, 0x78, 0xD4))
                    : Brushes.Transparent;
            }
            if (index >= 0 && index < _rows.Count)
            {
                try { _rows[index].BringIntoView(); } catch { }
            }
        }

        private void InvokeSelected()
        {
            if (_selected < 0 || _selected >= _hits.Count)
            {
                // 没选中任何一项时按 Enter：直接打开第一条，符合「打完字就回车」的直觉
                if (_hits.Count > 0) Invoke(_hits[0]);
                return;
            }
            Invoke(_hits[_selected]);
        }

        private void Invoke(SearchHit hit)
        {
            if (hit == null) return;

            if (hit.Kind == "file" && !string.IsNullOrEmpty(hit.Path))
            {
                FileUI.OpenFile(hit.Path);
                Close();
                return;
            }

            // 待办 / 便签：把对应分区窗口唤到最前，让用户直接在原位继续编辑
            _onActivatePartition?.Invoke(hit.PartitionId);
            Close();
        }

        // MARK: - 搜索

        private void RebuildResults()
        {
            string query = _input.Text;
            _hits.Clear();
            _resultsPanel.Children.Clear();
            _rows.Clear();
            _selected = -1;

            if (string.IsNullOrWhiteSpace(query))
            {
                _hintText.Text = "输入关键词开始搜索 · 文件 / 待办 / 便签";
                return;
            }

            foreach (var part in _config.Partitions)
            {
                CollectPartitionHits(part, query);
            }

            // 得分高的在前；同分时短的在前 —— 「完全命中一个短名字」
            // 几乎总是比「长时间命中一个长路径」更接近用户想要的那条。
            var ordered = _hits
                .OrderByDescending(h => h.Score)
                .ThenBy(h => h.Title.Length)
                .Take(MaxResults)
                .ToList();

            _hits.Clear();
            _hits.AddRange(ordered);

            if (_hits.Count == 0)
            {
                _hintText.Text = $"没有找到与「{query.Trim()}」匹配的内容";
                return;
            }

            string lastGroup = string.Empty;
            for (int i = 0; i < _hits.Count; i++)
            {
                string group = GroupLabelOf(_hits[i].Kind);
                if (group != lastGroup)
                {
                    lastGroup = group;
                    _resultsPanel.Children.Add(BuildGroupHeader(group));
                }
                var row = BuildRow(_hits[i], i);
                _rows.Add(row);
                _resultsPanel.Children.Add(row);
            }

            _hintText.Text = $"共 {_hits.Count} 条结果 · ↑↓ 选择 · Enter 打开 · Esc 关闭";
            SetSelection(0);
        }

        private void CollectPartitionHits(PartitionModel part, string query)
        {
            string partTitle = StripIcon(part.Title);

            // 2. 映射文件夹的**顶层**内容（带 5s 缓存，避免每次按键重列目录）
            if (part.Type == "portal" && !string.IsNullOrWhiteSpace(part.FolderPath))
            {
                foreach (var path in ListDirectoryCached(part.FolderPath!))
                {
                    string name = NameOf(path);
                    int? score = QueryMatcher.MatchScore(query, name);
                    if (score == null) continue;
                    if (_hits.Any(h => string.Equals(h.Path, path, StringComparison.OrdinalIgnoreCase))) continue;

                    bool isDir = FileKinds.IsOpaqueDirectory(Path.GetFileName(path), Directory.Exists(path));
                    _hits.Add(new SearchHit
                    {
                        Kind = "file",
                        PartitionId = part.Id,
                        PartitionTitle = partTitle,
                        Title = name,
                        Subtitle = partTitle,
                        Path = path,
                        IsDirectory = isDir,
                        // 目录内容比显式登记项低一档：同一名字时优先命中「用户亲手放进去的」
                        Score = Math.Max(0, score.Value - 40)
                    });
                }
            }

            // 3. 待办
            foreach (var todo in part.Todos)
            {
                int? score = QueryMatcher.MatchScore(query, todo.Text);
                if (score == null) continue;
                _hits.Add(new SearchHit
                {
                    Kind = "todo",
                    PartitionId = part.Id,
                    PartitionTitle = partTitle,
                    Title = todo.Text,
                    Subtitle = (todo.Completed ? "已完成 · " : "未完成 · ") + partTitle,
                    Score = score.Value
                });
            }

            // 4. 便签：整段内容里命中就产出**一条**结果（不按行拆，避免一条便签刷满列表）
            if (part.Type == "notes" && !string.IsNullOrWhiteSpace(part.NoteContent))
            {
                string content = part.NoteContent!;
                int? score = QueryMatcher.MatchScore(query, content);
                if (score == null) score = QueryMatcher.MatchScore(query, partTitle);
                if (score != null)
                {
                    _hits.Add(new SearchHit
                    {
                        Kind = "note",
                        PartitionId = part.Id,
                        PartitionTitle = partTitle,
                        Title = partTitle,
                        Subtitle = FirstLine(content),
                        Score = score.Value
                    });
                }
            }
        }

        private static string GroupLabelOf(string kind) => kind switch
        {
            "todo" => "待办",
            "note" => "便签",
            _ => "文件与目录"
        };

        private static string NameOf(string path)
        {
            try
            {
                string name = Path.GetFileName(path);
                return string.IsNullOrEmpty(name) ? path : name;
            }
            catch
            {
                return path;
            }
        }

        private static string StripIcon(string? raw)
        {
            string text = (raw ?? string.Empty).Trim();
            // 标题常常以 emoji 开头（"📁 映射文件夹"），搜索时它只是噪声
            var parts = text.Split(' ', 2, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length == 2 && parts[0].Length <= 3) return parts[1];
            return text;
        }

        private static string FirstLine(string text)
        {
            foreach (var line in text.Split('\n'))
            {
                string t = line.Trim();
                if (t.Length > 0) return t.Length > 60 ? t.Substring(0, 60) + "…" : t;
            }
            return string.Empty;
        }

        private static List<string> ListDirectoryCached(string dir)
        {
            DateTime now = DateTime.Now;
            if (DirCache.TryGetValue(dir, out var entry) &&
                (now - entry.At).TotalMilliseconds < DirCacheTtlMs)
            {
                return entry.Paths;
            }

            var list = new List<string>();
            try
            {
                if (Directory.Exists(dir))
                {
                    // 用 EnumerateFileSystemEntries 一次拿到文件 + 子目录，
                    // 搜索时两者都算「结果」；再截断到上限防大目录把面板撑爆。
                    foreach (var p in Directory.EnumerateFileSystemEntries(dir, "*", SearchOption.TopDirectoryOnly)
                                                .Take(MaxDirEntries))
                    {
                        list.Add(p);
                    }
                }
            }
            catch
            {
                // 无权限 / 目录被删：当作空目录，不弹错
            }

            DirCache[dir] = (now, list);
            return list;
        }

        // MARK: - 行构建

        private Border BuildGroupHeader(string label)
        {
            return new Border
            {
                Padding = new Thickness(16, 8, 16, 4),
                Child = new TextBlock
                {
                    Text = label,
                    FontSize = 10,
                    FontWeight = FontWeights.SemiBold,
                    Foreground = new SolidColorBrush(Color.FromArgb(0x80, 0xFF, 0xFF, 0xFF))
                }
            };
        }

        private Border BuildRow(SearchHit hit, int index)
        {
            var title = new TextBlock
            {
                Text = hit.Title,
                FontSize = 12.5,
                Foreground = new SolidColorBrush(Color.FromRgb(0xF5, 0xF5, 0xF5)),
                TextTrimming = TextTrimming.CharacterEllipsis
            };
            var subtitle = new TextBlock
            {
                Text = hit.Subtitle,
                FontSize = 10,
                Foreground = new SolidColorBrush(Color.FromArgb(0x73, 0xFF, 0xFF, 0xFF)),
                Margin = new Thickness(0, 2, 0, 0),
                TextTrimming = TextTrimming.CharacterEllipsis
            };

            var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            texts.Children.Add(title);
            if (!string.IsNullOrEmpty(hit.Subtitle)) texts.Children.Add(subtitle);

            var glyph = new TextBlock
            {
                Text = hit.Kind switch
                {
                    "todo" => "\uE73E",                    // Fluent CheckboxComposite
                    "note" => "\uE70B",                    // Fluent QuickNote
                    _ => hit.IsDirectory ? "\uE8B7" : "\uE8A5"   // Folder / Document
                },
                FontFamily = (FontFamily)Application.Current.Resources["FluentIconFont"],
                FontSize = 14,
                Width = 20,
                Foreground = new SolidColorBrush(Color.FromArgb(0xBF, 0xFF, 0xFF, 0xFF)),
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(0, 0, 10, 0)
            };

            var outer = new Grid();
            outer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            outer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            outer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            Grid.SetColumn(glyph, 0);
            Grid.SetColumn(texts, 1);
            outer.Children.Add(glyph);
            outer.Children.Add(texts);

            // 文件类结果额外给一个「定位」入口：搜索最常见的后续动作是
            // 「我找到它了，但我想去它所在的文件夹看看」，而不是打开它。
            if (hit.Kind == "file" && !string.IsNullOrEmpty(hit.Path))
            {
                var revealBtn = new Button
                {
                    Content = "定位",
                    FontSize = 10,
                    Height = 22,
                    Padding = new Thickness(8, 0, 8, 0),
                    Margin = new Thickness(8, 0, 0, 0),
                    Cursor = Cursors.Hand,
                    VerticalAlignment = VerticalAlignment.Center,
                    Foreground = new SolidColorBrush(Color.FromRgb(0xF5, 0xF5, 0xF5)),
                    Background = new SolidColorBrush(Color.FromArgb(0x1A, 0xFF, 0xFF, 0xFF)),
                    BorderThickness = new Thickness(0),
                    ToolTip = "在资源管理器中显示"
                };
                string capturedPath = hit.Path;
                revealBtn.Click += (_, e) =>
                {
                    e.Handled = true;   // 别让点击冒泡成「打开」
                    FileUI.RevealInExplorer(capturedPath);
                };
                outer.Children.Add(revealBtn);
                Grid.SetColumn(revealBtn, 2);
            }

            var row = new Border
            {
                Padding = new Thickness(16, 7, 16, 7),
                Margin = new Thickness(6, 1, 6, 1),
                CornerRadius = new CornerRadius(6),
                BorderThickness = new Thickness(1),
                Background = Brushes.Transparent,
                BorderBrush = Brushes.Transparent,
                Child = outer,
                Cursor = Cursors.Hand
            };

            int capturedIndex = index;
            row.MouseLeftButtonDown += (_, _) => SetSelection(capturedIndex);
            row.MouseLeftButtonUp += (_, _) =>
            {
                // 按下与抬起之间用户可能改了关键词（列表已重建），
                // 这时旧下标会越界 —— 直接忽略，不要拿错误的下标去打开文件。
                if (capturedIndex < 0 || capturedIndex >= _hits.Count) return;
                SetSelection(capturedIndex);
                Invoke(_hits[capturedIndex]);
            };

            return row;
        }
    }
}
