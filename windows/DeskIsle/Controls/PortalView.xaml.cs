using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using DeskIsle.Models;
using DeskIsle.Native;
using DeskIsle.Services;
using DeskIsle.Views;

namespace DeskIsle.Controls
{
    public partial class PortalView : UserControl
    {
        private PartitionModel? _partition;
        private Action? _onDataChanged;
        private string _currentPath = string.Empty;
        private FileSystemWatcher? _watcher;
        private readonly List<FileDisplayItem> _allItems = new();
        /// <summary>条目选中集（纯逻辑，判据与 mac / Electron 同源）。</summary>
        private readonly FileSelection _selection = new();
        /// <summary>当前**可见且有序**的条目（过滤 + 排序之后），⇧ 区间按这个顺序取。</summary>
        private List<FileDisplayItem> _visible = new();

        /// <summary>
        /// 当前浏览目录里的条目数（**未过滤**）。
        /// 供「自适应宽高」计算内容高度：必须取**当前目录**而不是配置里的根目录，
        /// 否则进入子文件夹后点自适应会用最外层的条目数来定高度（mac 同名坑，见 <c>autoFitHeight</c>）。
        /// </summary>
        public int EntryCount => _allItems.Count;

        public PortalView()
        {
            InitializeComponent();
            // ⚠️ 挂 **Loaded** 而不是构造函数：那时 `Window.GetWindow(this)` 还没值。
            // 也不能直接用 IsVisible 之类：分区窗口会被反复重建，这里必须幂等。
            Loaded += AttachKeyHandling;
            Loaded += AttachSelectionScope;
        }

        /// <summary>
        /// 选区的作用域 —— 宿主窗口失焦（切到另一个分区 / 点到别的应用 / 桌面）时，
        /// 本分区的选中<b>一律失效</b>。
        ///
        /// <para>
        /// 为什么要这条：选区是每个分区各自存的一份状态，天然互不可见。
        /// 用户在这儿选中一批、转头干别的，回来随手一拖 ——
        /// 拖走的是那批他早忘了的选中项，而他自己以为只拖了鼠标底下那一个。
        /// （2026-10-01 事故：想拖一张 png，结果连另一个分区的图一起被搬去了桌面。）
        /// </para>
        ///
        /// <para>
        /// 判据是纯函数 <see cref="FileSelectionScope.ShouldClear"/>（与 mac 同源），
        /// 不在事件里手写比较。
        /// </para>
        /// </summary>
        private void AttachSelectionScope(object sender, RoutedEventArgs e)
        {
            var w = Window.GetWindow(this);
            if (w == null) return;
            // 幂等：分区窗口会被反复重建，重复挂只会导致清空两次（无害），但先 -= 更干净
            w.Deactivated -= OnHostWindowDeactivated;
            w.Deactivated += OnHostWindowDeactivated;
        }

        private void OnHostWindowDeactivated(object? sender, EventArgs e)
        {
            if (_selection.Count == 0) return;
            // activeID = null：活跃的不在任何一个分区里 → 所有分区的选区失效
            if (!FileSelectionScope.ShouldClear(_partition?.Id ?? string.Empty, null)) return;
            _selection.Clear();
            ApplySelectionToItems();
        }

        public void BindData(PartitionModel partition, Action onDataChanged)
        {
            _partition = partition;
            _onDataChanged = onDataChanged;

            string? sub = partition.CurrentSubPath;
            if (!string.IsNullOrEmpty(sub) && Directory.Exists(sub) &&
                !string.IsNullOrEmpty(partition.FolderPath) && sub.StartsWith(partition.FolderPath, StringComparison.OrdinalIgnoreCase))
            {
                _currentPath = sub;
            }
            else
            {
                _currentPath = !string.IsNullOrEmpty(partition.FolderPath) && Directory.Exists(partition.FolderPath)
                    ? partition.FolderPath
                    : Environment.GetFolderPath(Environment.SpecialFolder.Desktop);
            }

            InitWatcher();
            ReloadItems();
        }

        private void InitWatcher()
        {
            _watcher?.Dispose();
            if (string.IsNullOrEmpty(_currentPath) || !Directory.Exists(_currentPath)) return;

            try
            {
                _watcher = new FileSystemWatcher(_currentPath)
                {
                    NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName | NotifyFilters.LastWrite,
                    EnableRaisingEvents = true
                };

                _watcher.Created += (_, _) => Dispatcher.Invoke(ReloadItems);
                _watcher.Deleted += (_, _) => Dispatcher.Invoke(ReloadItems);
                _watcher.Renamed += (_, _) => Dispatcher.Invoke(ReloadItems);
                _watcher.Changed += (_, _) => Dispatcher.Invoke(ReloadItems);
            }
            catch { }
        }

        public void ReloadItems()
        {
            _allItems.Clear();
            UpdateBreadcrumbs();

            if (string.IsNullOrEmpty(_currentPath) || !Directory.Exists(_currentPath))
            {
                if (!string.IsNullOrEmpty(_partition?.FolderPath) && Directory.Exists(_partition.FolderPath))
                {
                    _currentPath = _partition.FolderPath;
                    UpdateBreadcrumbs();
                }
                else
                {
                    ApplyFilterAndSort();
                    return;
                }
            }

            try
            {
                var dirInfo = new DirectoryInfo(_currentPath);

                // 一次遍历，「目录 / 文件 / 包」一次分完。
                //
                // ⚠️ 关键点：`.app` 这类 **macOS 的包**在文件系统上是目录
                // （`FileAttributes.Directory` 为真），但它语义上是**单个不可展开的项** ——
                // 必须当文件处理，否则它会显示成文件夹、双击「展开」成一串 `Contents/…`。
                // 判定口径见 `FileKinds`，与 mac / Electron 三端同源。
                foreach (var info in dirInfo.EnumerateFileSystemInfos())
                {
                    if ((info.Attributes & FileAttributes.Hidden) != 0) continue;

                    bool physicalDir = (info.Attributes & FileAttributes.Directory) != 0;
                    bool isPackage = physicalDir && FileKinds.IsPackageName(info.Name);
                    bool isDir = FileKinds.IsOpaqueDirectory(info.Name, physicalDir);

                    // 目录恒置顶在排序里完成（见 ApplyFilterAndSort），这里不必分批添加
                    _allItems.Add(new FileDisplayItem
                    {
                        Path = info.FullName,
                        Name = info.Name,
                        Icon = isDir ? "📁" : (isPackage ? "📦" : FileUI.GetFileIcon(info.Extension)),
                        // 包一律走「文件」图标路径：Windows 取不到应用图标（它不认识包），
                        // 返回扩展名对应的通用图标 —— 这已是最诚实的答案，总好过文件夹图标。
                        IconImage = IconService.GetIcon(info.FullName, isDir),
                        SizeText = isDir
                            ? "文件夹"
                            : (info is FileInfo fi ? FileUI.FormatFileSize(fi.Length) : "—"),
                        IsDirectory = isDir
                    });
                }
            }
            catch { }

            ApplyFilterAndSort();
        }

        private void UpdateBreadcrumbs()
        {
            BreadcrumbPanel.Children.Clear();
            if (string.IsNullOrEmpty(_currentPath)) return;

            if (!string.IsNullOrEmpty(_partition?.FolderPath) && _currentPath != _partition.FolderPath)
            {
                var backBtn = new Button
                {
                    Content = "‹ 返回",
                    Background = new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromArgb(30, 255, 255, 255)),
                    Foreground = System.Windows.Media.Brushes.White,
                    BorderThickness = new Thickness(0),
                    FontSize = 10,
                    Cursor = Cursors.Hand,
                    Padding = new Thickness(4, 1, 4, 1),
                    Margin = new Thickness(0, 0, 4, 0),
                    ToolTip = "返回上一级 (Alt+↑ / Backspace)"
                };
                backBtn.Click += (_, _) => NavigateToParent();
                BreadcrumbPanel.Children.Add(backBtn);
            }

            var parts = _currentPath.Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries);
            string accPath = string.Empty;

            for (int i = 0; i < parts.Length; i++)
            {
                string seg = parts[i];
                if (i == 0 && !seg.EndsWith(":")) seg += "\\";
                else if (i == 0) seg += "\\";
                accPath = (i == 0) ? seg : Path.Combine(accPath, seg);

                string targetPath = accPath;
                var btn = new Button
                {
                    Content = parts[i],
                    Background = System.Windows.Media.Brushes.Transparent,
                    Foreground = (i == parts.Length - 1) ? System.Windows.Media.Brushes.White : new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromArgb(180, 255, 255, 255)),
                    BorderThickness = new Thickness(0),
                    FontSize = 10.5,
                    Cursor = Cursors.Hand,
                    Padding = new Thickness(2, 0, 2, 0)
                };
                btn.Click += (_, _) =>
                {
                    if (targetPath != _currentPath)
                    {
                        string? restore = null;
                        if (_currentPath.StartsWith(targetPath, StringComparison.OrdinalIgnoreCase))
                        {
                            string sub = _currentPath.Substring(targetPath.Length).TrimStart('\\', '/');
                            int sep = sub.IndexOfAny(new[] { '\\', '/' });
                            string firstSeg = sep > 0 ? sub.Substring(0, sep) : sub;
                            if (!string.IsNullOrEmpty(firstSeg))
                            {
                                restore = Path.Combine(targetPath, firstSeg);
                            }
                        }
                        NavigateTo(targetPath, restore);
                    }
                };
                BreadcrumbPanel.Children.Add(btn);

                if (i < parts.Length - 1)
                {
                    BreadcrumbPanel.Children.Add(new TextBlock
                    {
                        Text = "›",
                        Foreground = new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromArgb(100, 255, 255, 255)),
                        FontSize = 10,
                        VerticalAlignment = VerticalAlignment.Center,
                        Margin = new Thickness(2, 0, 2, 0)
                    });
                }
            }
        }

        private void ApplyFilterAndSort()
        {
            string query = SearchBox.Text.Trim().ToLowerInvariant();
            var filtered = string.IsNullOrEmpty(query)
                ? _allItems
                : _allItems.Where(x => x.Name.ToLowerInvariant().Contains(query)).ToList();

            string sortBy = _partition?.SortBy ?? "name";
            bool desc = _partition?.SortOrder == "desc";

            IEnumerable<FileDisplayItem> sorted = sortBy switch
            {
                "time" => desc ? filtered.OrderByDescending(x => GetMTime(x.Path)) : filtered.OrderBy(x => GetMTime(x.Path)),
                "size" => desc ? filtered.OrderByDescending(x => GetSize(x.Path)) : filtered.OrderBy(x => GetSize(x.Path)),
                "type" => desc ? filtered.OrderByDescending(x => Path.GetExtension(x.Path)) : filtered.OrderBy(x => Path.GetExtension(x.Path)),
                _ => desc ? filtered.OrderByDescending(x => x.Name) : filtered.OrderBy(x => x.Name)
            };

            // 保持文件夹永久排在最前
            var finalList = sorted.OrderByDescending(x => x.IsDirectory).ToList();

            _visible = finalList;
            // 刷新后清掉已经不在磁盘上的选中项（文件可能在别处被删掉），
            // 留着幽灵路径会让之后任何「对选中项操作」打到不存在的路径上。
            // ⚠️ 传**未过滤**的全集：搜索框里打字不该把选区清空。
            _selection.Retain(_allItems.Select(x => x.Path));

            // 若有返回上级待恢复焦点的子目录，自动高亮选中并滚动居中
            if (!string.IsNullOrEmpty(_pendingRestoreFocusPath))
            {
                string target = _pendingRestoreFocusPath;
                _pendingRestoreFocusPath = null;
                var found = _visible.FirstOrDefault(x => string.Equals(x.Path.TrimEnd('\\', '/'), target.TrimEnd('\\', '/'), StringComparison.OrdinalIgnoreCase));
                if (found != null)
                {
                    _selection.Click(found.Path, _visible.Select(x => x.Path).ToList());
                    ScrollToItem(found);
                }
            }

            ApplySelectionToItems();

            FileItemsControl.ItemsSource = finalList;
            if (finalList.Count == 0)
            {
                EmptyPrompt.Visibility = Visibility.Visible;
                if (!string.IsNullOrEmpty(SearchBox.Text))
                {
                    EmptyPromptIcon.Text = "\uE721"; // 放大镜
                    EmptyPromptText.Text = $"未找到与“{SearchBox.Text}”匹配的项目";
                    EmptyPromptSub.Text = "按 Esc 或清空搜索框可恢复显示";
                }
                else
                {
                    EmptyPromptIcon.Text = "\uE8B7"; // 文件夹
                    EmptyPromptText.Text = "此文件夹为空";
                    EmptyPromptSub.Text = "可将文件拖拽至此处，或右键新建";
                }
            }
            else
            {
                EmptyPrompt.Visibility = Visibility.Collapsed;
            }
        }

        /// <summary>把选中集写回条目自身（`IsSelected` 带通知，XAML 的 DataTrigger 据此上色）。</summary>
        private void ApplySelectionToItems()
        {
            foreach (var it in _visible) it.IsSelected = _selection.Contains(it.Path);

            var selPaths = _selection.OrderedSelection(_visible.Select(x => x.Path).ToList());
            if (selPaths.Count >= 2)
            {
                long totalBytes = 0;
                foreach (var p in selPaths)
                {
                    if (File.Exists(p))
                    {
                        try { totalBytes += new FileInfo(p).Length; } catch { }
                    }
                }
                string sizeStr = totalBytes > 0 ? $" ({FormatBytes(totalBytes)})" : "";
                SelectionCountText.Text = $"已选 {selPaths.Count} 项{sizeStr}";
                FloatingSelectionCapsule.Visibility = Visibility.Visible;
            }
            else
            {
                FloatingSelectionCapsule.Visibility = Visibility.Collapsed;
            }

            // 实时预览连播：若空格快速预览浮层当前已开启，自动无缝切到新选中的文件
            if (PreviewWindow.IsShowing)
            {
                if (selPaths.Count == 1 && !Directory.Exists(selPaths[0]))
                {
                    PreviewWindow.Show(selPaths[0]);
                }
            }
        }

        private static string FormatBytes(long bytes)
        {
            string[] units = { "B", "KB", "MB", "GB", "TB" };
            double val = bytes;
            int order = 0;
            while (val >= 1024 && order < units.Length - 1)
            {
                order++;
                val /= 1024;
            }
            return $"{val:0.#} {units[order]}";
        }

        /// <summary>点内容区**空白处**取消选中（条目自己的处理器会拦下事件，不会走到这里）。</summary>
        private void Root_MouseDown(object sender, MouseButtonEventArgs e)
        {
            if (_selection.Count == 0) return;
            _selection.Clear();
            ApplySelectionToItems();
        }

        private static DateTime GetMTime(string p) => File.Exists(p) ? File.GetLastWriteTime(p) : (Directory.Exists(p) ? Directory.GetLastWriteTime(p) : DateTime.MinValue);
        private static long GetSize(string p) => File.Exists(p) ? new FileInfo(p).Length : 0;

        private void SearchBox_TextChanged(object sender, TextChangedEventArgs e) => ApplyFilterAndSort();

        private void SearchBox_KeyDown(object sender, KeyEventArgs e)
        {
            if (e.Key == Key.Enter)
            {
                if (_visible.Count > 0)
                {
                    OpenItem(_visible[0]);
                    e.Handled = true;
                }
            }
            else if (e.Key == Key.Escape)
            {
                SearchBox.Text = string.Empty;
                FileItemsControl.Focus();
                e.Handled = true;
            }
        }

        private void CapsuleCopy_Click(object sender, RoutedEventArgs e)
        {
            var targets = _selection.OrderedSelection(_visible.Select(x => x.Path).ToList());
            if (targets.Count > 0)
            {
                FileListActions.CopyToClipboard(targets);
            }
        }

        private void CapsuleCompress_Click(object sender, RoutedEventArgs e)
        {
            var targets = _selection.OrderedSelection(_visible.Select(x => x.Path).ToList());
            if (targets.Count > 0)
            {
                FileListActions.CompressToZip(targets, () => ReloadItems());
            }
        }

        private void CapsuleTrash_Click(object sender, RoutedEventArgs e)
        {
            var targets = _selection.OrderedSelection(_visible.Select(x => x.Path).ToList());
            if (targets.Count > 0)
            {
                FileListActions.SendToRecycleBin(targets);
                ReloadItems();
            }
        }

        private void CapsuleClear_Click(object sender, RoutedEventArgs e)
        {
            _selection.Clear();
            ApplySelectionToItems();
        }

        private void NewFolder_Click(object sender, RoutedEventArgs e)
        {
            if (string.IsNullOrEmpty(_currentPath) || !Directory.Exists(_currentPath)) return;
            string baseName = "新建文件夹";
            string target = Path.Combine(_currentPath, baseName);
            int idx = 2;
            while (Directory.Exists(target) || File.Exists(target))
            {
                target = Path.Combine(_currentPath, $"{baseName} {idx++}");
            }
            try
            {
                Directory.CreateDirectory(target);
                ReloadItems();
            }
            catch { }
        }

        private void NewTextFile_Click()
        {
            if (string.IsNullOrEmpty(_currentPath) || !Directory.Exists(_currentPath)) return;
            string baseName = "新建文档";
            string ext = ".txt";
            string target = Path.Combine(_currentPath, $"{baseName}{ext}");
            int idx = 2;
            while (Directory.Exists(target) || File.Exists(target))
            {
                target = Path.Combine(_currentPath, $"{baseName} {idx++}{ext}");
            }
            try
            {
                File.WriteAllText(target, string.Empty);
                ReloadItems();
                _selection.Clear();
                _selection.Add(target);
                ApplySelectionToItemsAndRefresh();
                var targetItem = _visible.FirstOrDefault(x => x.Path == target);
                if (targetItem != null) ScrollToItem(targetItem);
            }
            catch { }
        }

        private void Reveal_Click(object sender, RoutedEventArgs e)
        {
            if (!string.IsNullOrEmpty(_currentPath) && Directory.Exists(_currentPath))
            {
                FileUI.OpenFile(_currentPath);
            }
        }

        private void Sort_Click(object sender, RoutedEventArgs e)
        {
            if (_partition == null) return;
            string[] modes = { "name", "time", "size", "type" };
            int curIdx = Array.IndexOf(modes, _partition.SortBy);
            _partition.SortBy = modes[(curIdx + 1) % modes.Length];
            ApplyFilterAndSort();
            _onDataChanged?.Invoke();
        }

        private void ToggleView_Click(object sender, RoutedEventArgs e)
        {
            if (_partition == null) return;
            _partition.ViewMode = _partition.ViewMode == "grid" ? "list" : "grid";
            ToggleViewBtn.Content = _partition.ViewMode == "grid" ? "⊞" : "☰";
            _onDataChanged?.Invoke();
        }

        private void FileItem_MouseDown(object sender, MouseButtonEventArgs e)
        {
            if (sender is not FrameworkElement elem || elem.DataContext is not FileDisplayItem item) return;

            // ⚠️ 必须把事件标记为已处理：否则它会继续冒泡到 Root_MouseDown，
            // 而那里是「点空白 → 取消选中」—— 刚选中的一条会被自己清掉。
            e.Handled = true;

            if (e.ClickCount >= 2)
            {
                OpenItem(item);
                return;
            }

            // 单击 = 选中（Ctrl 切换 / Shift 区间），与 mac 的 PortalView 同源。
            // ⚠️ 目录不再「单击即进入」：那样点击连高亮都来不及看见就被换掉了。
            bool ctrl = Keyboard.Modifiers.HasFlag(ModifierKeys.Control);
            bool shift = Keyboard.Modifiers.HasFlag(ModifierKeys.Shift);
            _selection.Click(item.Path, _visible.Select(x => x.Path).ToList(), ctrl, shift);
            ApplySelectionToItems();
        }

        /// <summary>
        /// 双击条目：按类型分派 —— 进入目录 / 预览图片 / 交系统打开。
        ///
        /// 判据在 <c>FileKinds.DefaultAction</c>（三端同源，有单测钉着）。这里只做
        /// portal 特有的一步：目录要**在本分区内浏览**，而不是丢给资源管理器。
        /// </summary>
        private void OpenItem(FileDisplayItem item)
        {
            switch (FileKinds.DefaultAction(item.IsDirectory, item.Path))
            {
                case FileKinds.OpenAction.EnterDirectory:
                    NavigateTo(item.Path);
                    return;
                case FileKinds.OpenAction.PreviewImage:
                    // 解不开（HEIF / AVIF 没装解码器）时预览窗自己会返回 false → 退回外部打开
                    if (PreviewWindow.Show(item.Path)) return;
                    break;
            }
            FileUI.OpenFile(item.Path);
        }

        /// <summary>
        /// 按住左键拖动文件条目 → 把**真实文件**拖出到资源管理器 / 桌面 / 其它应用。
        /// 对齐 mac 基线的 `fileDragProvider`（目录同样可拖）。
        /// </summary>
        private void FileItem_PreviewMouseDown(object sender, MouseButtonEventArgs e)
        {
            // 记下「按在哪个条目、哪一点」：拖出判据（4pt 阈值 + 只认被按住的那个条目）全靠它。
            var elem = sender as FrameworkElement;
            FileDragSource.NoteMouseDown(elem, elem == null ? default : e.GetPosition(elem));
        }

        private void FileItem_PreviewMouseMove(object sender, MouseEventArgs e)
        {
            if (sender is FrameworkElement elem && elem.DataContext is FileDisplayItem item)
                // 映射文件夹 = 一个真实文件夹的视图，拖出去就是要搬走（同卷 Move / 跨卷 Copy），
                // 和访达里把文件拖到别处完全一致。
                FileDragSource.TryBegin(elem, item.Path, e.GetPosition(elem),
                                       onChanged: () => { InitWatcher(); ReloadItems(); });
        }

        // ── 拖入（对齐 mac 端 PortalView 的 onDrop） ──────────────────────
        // 语义是**移动**：拖进来的意图就是「把这个文件收进这个文件夹」，留在原地会变成两份。

        private void Root_DragOver(object sender, DragEventArgs e)
        {
            FolderDrop.OnDragOver(e);
            ClearDropTarget();
            DropHighlight.Visibility =
                e.Data.GetDataPresent(DataFormats.FileDrop) ? Visibility.Visible : Visibility.Collapsed;
        }

        private void Root_Drop(object sender, DragEventArgs e)
        {
            DropHighlight.Visibility = Visibility.Collapsed;
            ClearDropTarget();
            FolderDrop.OnDrop(e, _currentPath, () => { InitWatcher(); ReloadItems(); });
        }

        /// <summary>拖到**文件夹条目上** = 落进那个文件夹（内层优先于整个内容区）。</summary>
        private void FileItem_DragOver(object sender, DragEventArgs e)
        {
            if (sender is FrameworkElement elem && elem.DataContext is FileDisplayItem item
                && FolderDrop.AcceptsOnItem(e, item.IsDirectory))
            {
                // ⚠️ 内层一旦接管，面板级高亮必须收掉：两个一起亮等于没区分，
                // 又回到「看不出落在当前目录还是子目录」的老问题（mac 端同款）。
                DropHighlight.Visibility = Visibility.Collapsed;
                SetDropTarget(elem as Border, item);
                return;
            }
            ClearDropTarget();
        }

        private void FileItem_DragLeave(object sender, DragEventArgs e) => ClearDropTarget();

        private void FileItem_Drop(object sender, DragEventArgs e)
        {
            ClearDropTarget();
            if (sender is FrameworkElement elem && elem.DataContext is FileDisplayItem item && item.IsDirectory)
                FolderDrop.OnDrop(e, item.Path, () => { InitWatcher(); ReloadItems(); });
        }

        // ── 落点高亮与 Spring-loaded Folders 弹性展开 ────────────────────────
        // 仿达 / 资源管理器里，把文件拖到一个文件夹上悬停 0.65 秒，自动进入该子目录（弹性展开）。
        // 方便用户拖拽文件直接下钻到深层目录放下。

        /// <summary>当前正被拖入文件指着的文件夹条目。</summary>
        private Border? _dropTargetItem;
        private DispatcherTimer? _springLoadTimer;
        private string? _springLoadTargetPath;

        private void SetDropTarget(Border? border, FileDisplayItem? item)
        {
            if (_dropTargetItem == border) return;
            ClearDropTarget();
            if (border == null) return;
            border.BorderBrush = new SolidColorBrush(Color.FromRgb(0x00, 0x78, 0xD4));
            border.Background = new SolidColorBrush(Color.FromArgb(0x2E, 0x00, 0x78, 0xD4));
            _dropTargetItem = border;

            if (item != null && item.IsDirectory)
            {
                _springLoadTargetPath = item.Path;
                _springLoadTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(650) };
                _springLoadTimer.Tick += (_, _) =>
                {
                    _springLoadTimer?.Stop();
                    _springLoadTimer = null;
                    if (_springLoadTargetPath != null && Directory.Exists(_springLoadTargetPath))
                    {
                        string target = _springLoadTargetPath;
                        ClearDropTarget();
                        NavigateTo(target);
                    }
                };
                _springLoadTimer.Start();
            }
        }

        private void ClearDropTarget()
        {
            _springLoadTimer?.Stop();
            _springLoadTimer = null;
            _springLoadTargetPath = null;

            if (_dropTargetItem == null) return;
            // ⚠️ 必须是 ClearValue 而不是「写回原值」：条目的背景与描边是 DataTrigger
            // （选中态）给的，写死会把选中态冲掉；清掉本地值后触发器重新生效。
            _dropTargetItem.ClearValue(Border.BorderBrushProperty);
            _dropTargetItem.ClearValue(Border.BackgroundProperty);
            _dropTargetItem = null;
        }

        // MARK: - 右键菜单（动态的：菜单项数量与标题随选区变化）

        private void ItemContextMenu_Opened(object sender, RoutedEventArgs e)
        {
            if (sender is not ContextMenu menu) return;
            if (menu.PlacementTarget is not FrameworkElement fe) return;
            if (fe.DataContext is not FileDisplayItem item) return;

            menu.Items.Clear();
            foreach (var child in FileListActions.BuildItemMenu(
                         _selection, _visible, item, EnterDirectory, OpenExternally, RenamePath, ApplySelectionToItemsAndRefresh))
            {
                menu.Items.Add(child);
            }
        }

        private void Root_ContextMenuOpening(object sender, ContextMenuEventArgs e)
        {
            if (sender is not FrameworkElement fe) return;
            if (fe.ContextMenu == null) return;
            fe.ContextMenu.Items.Clear();
            foreach (var child in FileListActions.BuildBlankMenu(
                         _selection, _visible, _currentPath,
                         () => NewFolder_Click(this, new RoutedEventArgs()),
                         NewTextFile_Click,
                         () => FileUI.OpenFile(_currentPath),
                         ReloadItems,
                         ApplySelectionToItemsAndRefresh))
            {
                fe.ContextMenu.Items.Add(child);
            }
        }

        private string? _pendingRestoreFocusPath;

        private void NavigateTo(string path, string? restoreFocusPath = null)
        {
            _currentPath = path;
            _pendingRestoreFocusPath = restoreFocusPath;
            _selection.Clear();
            if (_partition != null)
            {
                _partition.CurrentSubPath = (!string.IsNullOrEmpty(_partition.FolderPath) && _currentPath != _partition.FolderPath)
                    ? _currentPath
                    : null;
                _onDataChanged?.Invoke();
            }
            InitWatcher();
            ReloadItems();
            UpdateBreadcrumbs();
        }

        private void NavigateToParent()
        {
            if (string.IsNullOrEmpty(_currentPath)) return;
            string root = _partition?.FolderPath ?? string.Empty;
            if (!string.IsNullOrEmpty(root) && _currentPath.TrimEnd('\\', '/') == root.TrimEnd('\\', '/')) return;
            var parent = Directory.GetParent(_currentPath)?.FullName;
            if (!string.IsNullOrEmpty(parent))
            {
                string exitingChild = _currentPath;
                NavigateTo(parent, restoreFocusPath: exitingChild);
            }
        }

        /// <summary>「在分区内展开浏览」—— portal 支持。</summary>
        private void EnterDirectory(FileDisplayItem item) => NavigateTo(item.Path);

        /// <summary>菜单 / 双击共用的「打开」：目录走系统资源管理器，文件走 <see cref="FileKinds"/> 判据。</summary>
        private void OpenExternally(IReadOnlyList<string> paths)
        {
            foreach (var p in paths)
            {
                bool isDir = Directory.Exists(p);
                if (!isDir && FileKinds.DefaultAction(false, p) == FileKinds.OpenAction.PreviewImage)
                {
                    if (PreviewWindow.Show(p)) continue;
                }
                FileUI.OpenFile(p);
            }
        }

        private void ApplySelectionToItemsAndRefresh() => ApplySelectionToItems();

        // MARK: - 键盘（与访达 / 资源管理器手感对齐）

        /// <summary>
        /// 键盘必须挂到**宿主窗口**上：UserControl 自己收不到没有焦点的按键，
        /// 而它是一个分区窗口里唯一的内容（这也是我们要挂窗口而不是链元素的理由）。
        /// ⚠️ 用 PreviewKeyDown 而不是 KeyDown：前者在 WPF 把它派发给具体控件**之前**就到，
        /// 否则搜索框会先吃掉 Ctrl+A / Delete 这类组合。
        /// </summary>
        private void AttachKeyHandling(object sender, RoutedEventArgs e)
        {
            if (Window.GetWindow(this) is Window win)
            {
                win.PreviewKeyDown -= Window_PreviewKeyDown;   // 幂等：Loaded 可能重入
                win.PreviewKeyDown += Window_PreviewKeyDown;
                win.PreviewMouseDown -= Window_PreviewMouseDown;
                win.PreviewMouseDown += Window_PreviewMouseDown;
            }
        }

        private void Window_PreviewMouseDown(object sender, MouseButtonEventArgs e)
        {
            if (e.ChangedButton == MouseButton.XButton1)
            {
                NavigateToParent();
                e.Handled = true;
            }
        }

        private string _quickSearchBuffer = string.Empty;
        private double _lastQuickSearchTime = 0;

        private void Window_PreviewKeyDown(object sender, KeyEventArgs e)
        {
            var win = Window.GetWindow(this);
            if (win != null && FocusManager.GetFocusedElement(win) is TextBox)
            {
                return;
            }

            if (FileListActions.HandleKey(e.Key, Keyboard.Modifiers, _selection, _visible, _currentPath,
                                          RenamePath, PreviewSelected, ApplySelectionToItemsAndRefresh))
            {
                e.Handled = true;
                return;
            }

            // 映射文件夹深度键盘流：
            // Alt+Up 或 Backspace：返回上一级目录
            if ((Keyboard.Modifiers == ModifierKeys.Alt && e.Key == Key.Up) ||
                (Keyboard.Modifiers == ModifierKeys.None && e.Key == Key.Back))
            {
                NavigateToParent();
                e.Handled = true;
                return;
            }

            // Enter 回车：进入选中的目录或打开选中的文件
            if (Keyboard.Modifiers == ModifierKeys.None && (e.Key == Key.Return || e.Key == Key.Enter))
            {
                var selectedPaths = _selection.OrderedSelection(_visible.Select(x => x.Path).ToList());
                if (selectedPaths.Count == 1)
                {
                    var target = _visible.FirstOrDefault(x => x.Path == selectedPaths[0]);
                    if (target != null && target.IsDirectory)
                    {
                        EnterDirectory(target);
                        e.Handled = true;
                        return;
                    }
                }
                if (selectedPaths.Count > 0)
                {
                    OpenExternally(selectedPaths);
                    e.Handled = true;
                    return;
                }
            }

            // 方向键导航（上下左右），支持 Shift 范围连选
            if (!Keyboard.Modifiers.HasFlag(ModifierKeys.Control) &&
                !Keyboard.Modifiers.HasFlag(ModifierKeys.Alt) &&
                (e.Key == Key.Up || e.Key == Key.Down || e.Key == Key.Left || e.Key == Key.Right))
            {
                var dir = e.Key switch
                {
                    Key.Up => TypeToSelectDirection.Up,
                    Key.Down => TypeToSelectDirection.Down,
                    Key.Left => TypeToSelectDirection.Left,
                    Key.Right => TypeToSelectDirection.Right,
                    _ => TypeToSelectDirection.Down
                };

                var allPaths = _visible.Select(x => x.Path).ToList();
                if (allPaths.Count > 0)
                {
                    var selected = _selection.OrderedSelection(allPaths);
                    int? curIdx = selected.Count > 0 ? allPaths.IndexOf(selected[0]) : null;
                    if (curIdx < 0) curIdx = null;

                    int cols = (_partition?.ViewMode == "grid") ? 4 : 1;
                    int nextIdx = TypeToSelect.NextIndex(curIdx, dir, allPaths.Count, cols);
                    if (nextIdx >= 0 && nextIdx < allPaths.Count)
                    {
                        string target = allPaths[nextIdx];
                        bool shift = Keyboard.Modifiers.HasFlag(ModifierKeys.Shift);
                        _selection.Click(target, allPaths, ctrl: false, shift: shift);
                        ApplySelectionToItemsAndRefresh();
                        var targetItem = _visible.FirstOrDefault(x => x.Path == target);
                        if (targetItem != null) ScrollToItem(targetItem);
                        e.Handled = true;
                        return;
                    }
                }
            }

            // 键盘首字母/即时累积跳转（Type-to-Select）
            if (!Keyboard.Modifiers.HasFlag(ModifierKeys.Control) &&
                !Keyboard.Modifiers.HasFlag(ModifierKeys.Alt) &&
                !Keyboard.Modifiers.HasFlag(ModifierKeys.Windows))
            {
                string? ch = KeyToChar(e.Key);
                if (!string.IsNullOrEmpty(ch))
                {
                    double now = DateTime.UtcNow.Subtract(DateTime.UnixEpoch).TotalSeconds;
                    var candidates = _visible.Select(x => (x.Name, x.Path)).ToList();
                    var allPaths = _visible.Select(x => x.Path).ToList();
                    string? currentSelected = _selection.OrderedSelection(allPaths).FirstOrDefault();

                    var (newBuf, matched) = TypeToSelect.Resolve(
                        ch,
                        _quickSearchBuffer,
                        _lastQuickSearchTime,
                        now,
                        candidates,
                        currentSelected
                    );
                    _quickSearchBuffer = newBuf;
                    _lastQuickSearchTime = now;

                    if (!string.IsNullOrEmpty(matched))
                    {
                        _selection.Click(matched, allPaths);
                        ApplySelectionToItemsAndRefresh();
                        var targetItem = _visible.FirstOrDefault(x => x.Path == matched);
                        if (targetItem != null) ScrollToItem(targetItem);
                    }
                    e.Handled = true;
                }
            }
        }

        private void ScrollToItem(FileDisplayItem item)
        {
            Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Background, new Action(() =>
            {
                if (FileItemsControl.ItemContainerGenerator.ContainerFromItem(item) is FrameworkElement fe)
                {
                    fe.BringIntoView();
                }
            }));
        }

        private static string? KeyToChar(Key key)
        {
            if (key >= Key.A && key <= Key.Z)
            {
                return ((char)('a' + (key - Key.A))).ToString();
            }
            if (key >= Key.D0 && key <= Key.D9)
            {
                return ((char)('0' + (key - Key.D0))).ToString();
            }
            if (key >= Key.NumPad0 && key <= Key.NumPad9)
            {
                return ((char)('0' + (key - Key.NumPad0))).ToString();
            }
            return null;
        }

        private void PreviewSelected()
        {
            var one = FileListActions.OrderedSelected(_selection, _visible);
            if (one.Count != 1) return;
            var path = one[0];
            bool isDir = Directory.Exists(path);
            if (!isDir && FileKinds.DefaultAction(false, path) == FileKinds.OpenAction.PreviewImage)
            {
                if (PreviewWindow.Show(path)) return;
            }
            FileUI.OpenFile(path);
        }

        /// <summary>
        /// 重命名某个路径（菜单项与 F2 / Enter 共用）。
        ///
        /// ⚠️ 与「新建文件夹」不同，这里**不自动加后缀**：用户明确指定了名字，
        /// 悄悄改成 `xxx 2` 会让他以为改名失败了。目标已存在时直接报错由他决定。
        /// </summary>
        private void RenamePath(string path)
        {
            string name = Path.GetFileName(path.TrimEnd('\\', '/'));
            string? newName = PromptInput("重命名", "请输入新名称:", name);
            if (string.IsNullOrWhiteSpace(newName) || newName == name) return;
            try
            {
                string dir = Path.GetDirectoryName(path)!;
                string newPath = Path.Combine(dir, newName);
                if (Directory.Exists(path)) Directory.Move(path, newPath);
                else File.Move(path, newPath);
                ReloadItems();
            }
            catch (Exception ex)
            {
                MessageBox.Show(ex.Message, "重命名失败", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }

        private static string? PromptInput(string title, string prompt, string defaultVal)
        {
            var win = new Window
            {
                Title = title,
                Width = 320,
                Height = 160,
                WindowStartupLocation = WindowStartupLocation.CenterScreen,
                WindowStyle = WindowStyle.ToolWindow,
                ResizeMode = ResizeMode.NoResize,
                Background = new SolidColorBrush(Color.FromRgb(30, 30, 30)),
                Foreground = Brushes.White
            };

            var panel = new StackPanel { Margin = new Thickness(16) };
            var lbl = new TextBlock { Text = prompt, Foreground = Brushes.White, Margin = new Thickness(0, 0, 0, 8), FontSize = 12 };
            var txt = new TextBox { Text = defaultVal, Margin = new Thickness(0, 0, 0, 12), Background = new SolidColorBrush(Color.FromRgb(45, 45, 45)), Foreground = Brushes.White, Padding = new Thickness(4, 2, 4, 2) };
            var btnPanel = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
            var okBtn = new Button { Content = "确定", Width = 64, Height = 26, Margin = new Thickness(0, 0, 8, 0), IsDefault = true };
            var cancelBtn = new Button { Content = "取消", Width = 64, Height = 26, IsCancel = true };

            string? result = null;
            okBtn.Click += (_, _) => { result = txt.Text; win.Close(); };
            cancelBtn.Click += (_, _) => win.Close();

            btnPanel.Children.Add(okBtn);
            btnPanel.Children.Add(cancelBtn);
            panel.Children.Add(lbl);
            panel.Children.Add(txt);
            panel.Children.Add(btnPanel);
            win.Content = panel;

            txt.Focus();
            txt.SelectAll();
            win.ShowDialog();
            return result;
        }

    }
}
