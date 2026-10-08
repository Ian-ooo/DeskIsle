using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using DeskIsle.Native;
using DeskIsle.Services;
using DeskIsle.Views;

namespace DeskIsle.Controls
{
    /// <summary>
    /// 文件夹类分区（portal）里「与资源管理器一致」的那批文件操作 ——
    /// 批量删除、复制 / 剪切 / 粘贴、多选感知的右键菜单、键盘意图的执行。
    /// <para>
    /// 抽成一个静态类的原因：PortalView 要的是<strong>同一套</strong>动作，
    /// 各写一份必然会在某一端漏掉某一条（历史上 Electron / Windows 就是这么丢的）。
    /// 两者唯一的差别是「能不能分区内进子目录」，用可选回调区分。
    /// </para>
    /// </summary>
    public static class FileListActions
    {
        // MARK: - 选中

        /// <summary>
        /// 右键菜单的<strong>操作目标</strong> —— 对齐资源管理器：多选之后菜单作用于整个选区，
        /// 而不是右键戳到的那一个。
        /// <para>
        /// ⚠️ 点在「没选中」的条目上时只操作它自己：否则「右键别的文件顺手删一下」
        /// 会连坐一堆不相干的东西。
        /// </para>
        /// </summary>
        public static List<string> MenuTargets(FileSelection selection,
                                               IReadOnlyList<FileDisplayItem> visible,
                                               FileDisplayItem clicked)
            => selection.MenuTargets(clicked.Path, visible.Select(x => x.Path).ToList());

        /// <summary>选区按<strong>当前显示顺序</strong>排好（判据在 <see cref="FileSelection"/>，三端同源）。</summary>
        public static List<string> OrderedSelected(FileSelection selection,
                                                   IReadOnlyList<FileDisplayItem> visible)
            => selection.OrderedSelection(visible.Select(x => x.Path).ToList());

        public static void SelectAll(FileSelection selection, IReadOnlyList<FileDisplayItem> visible)
        {
            var all = visible.Select(x => x.Path).ToList();
            if (all.Count == 0) return;
            selection.Click(all[0], all);
            for (int i = 1; i < all.Count; i++) selection.Click(all[i], all, ctrl: true);
        }

        // MARK: - 菜单构建

        /// <summary>条目的右键菜单（多选 / 单选两套内容）。</summary>
        /// <param name="enterDirectory">「在分区内展开浏览」的实现；传 null（不支持）。</param>
        /// <param name="openExternally">「打开」的实现。</param>
        /// <param name="afterChange">文件增删之后刷新视图。</param>
        /// <remarks>
        /// 返回菜单项列表而不是菜单本身：ContextMenu 挂在 XAML 元素上，
        /// 每次 <c>Opened</c> 只能往同一个实例里填 —— 造一个新的替换会丢掉 PlacementTarget。
        /// </remarks>
        public static List<Control> BuildItemMenu(
            FileSelection selection,
            IReadOnlyList<FileDisplayItem> visible,
            FileDisplayItem clicked,
            Action<FileDisplayItem>? enterDirectory,
            Action<IReadOnlyList<string>> openExternally,
            Action<string> rename,
            Action afterChange)
        {
            var targets = MenuTargets(selection, visible, clicked);
            var menu = new List<Control>();
            var byPath = visible.ToDictionary(x => x.Path);

            FileDisplayItem? Lookup(string p) => byPath.TryGetValue(p, out var it) ? it : null;

            if (targets.Count <= 1)
            {
                var one = targets.Count == 1 ? Lookup(targets[0]) : clicked;
                if (one != null)
                {
                    // 【第 1 组】：打开
                    if (one.IsDirectory && enterDirectory != null)
                        menu.Add(Item(MenuIcons.EnterBrowse, "在分区内展开浏览", () => enterDirectory(one)));
                    menu.Add(Item(MenuIcons.OpenExternally, "打开",
                        () => openExternally(new[] { one.Path })));
                    menu.Add(Item(MenuIcons.Reveal, "在文件资源管理器中定位",
                        () => FileUI.RevealInExplorer(one.Path)));
                    if (one.IsDirectory)
                    {
                        menu.Add(Item(MenuIcons.Terminal, "在终端中打开", () => OpenInTerminal(one.Path)));
                        if (IsVSCodeAvailable())
                            menu.Add(Item(MenuIcons.Code, "在 VS Code 中打开", () => OpenInVSCode(one.Path)));
                    }
                    else if (IsVSCodeAvailable())
                    {
                        menu.Add(Item(MenuIcons.Code, "在 VS Code 中打开", () => OpenInVSCode(one.Path)));
                    }

                    menu.Add(new Separator());

                    // 【第 2 组】：回收站
                    menu.Add(Item(MenuIcons.Delete, "移到回收站",
                        () => { SendToRecycleBin(targets); afterChange(); }, destructive: true));

                    menu.Add(new Separator());

                    // 【第 3 组】：文件管理（对齐图示）
                    menu.Add(Item(MenuIcons.Info, "显示简介", () => ShowProperties(one.Path)));
                    menu.Add(Item(MenuIcons.Rename, "重新命名", () => rename(one.Path)));
                    menu.Add(Item(MenuIcons.Zip, $"压缩“{one.Name}”", () => CompressToZip(targets, afterChange)));
                    menu.Add(Item(MenuIcons.Duplicate, "复制", () => Duplicate(targets, afterChange)));
                    menu.Add(Item(MenuIcons.Preview, "快速查看", () => openExternally(new[] { one.Path })));

                    menu.Add(new Separator());

                    // 【第 4 组】：剪贴板
                    menu.Add(Item(MenuIcons.Copy, "拷贝", () => CopyToClipboard(targets)));
                    menu.Add(Item(MenuIcons.Cut, "剪切", () => CutToClipboard(targets)));
                }
            }
            else
            {
                // 多选菜单
                int n = targets.Count;
                var dirs = targets.Select(Lookup).Where(x => x != null && x.IsDirectory).ToList();
                if (dirs.Count == 1 && enterDirectory != null)
                    menu.Add(Item(MenuIcons.EnterBrowse, "在分区内展开浏览",
                        () => enterDirectory(dirs[0]!)));
                menu.Add(Item(MenuIcons.OpenExternally, $"打开（{n} 项）",
                    () => openExternally(targets)));
                menu.Add(Item(MenuIcons.Reveal, $"在文件资源管理器中定位（{n} 项）",
                    () => RevealMany(targets)));

                menu.Add(new Separator());

                // 【第 2 组】：回收站
                menu.Add(Item(MenuIcons.Delete, $"移到回收站（{n} 项）",
                    () => { SendToRecycleBin(targets); afterChange(); }, destructive: true));

                menu.Add(new Separator());

                // 【第 3 组】：文件管理
                menu.Add(Item(MenuIcons.Info, $"显示简介（{n} 项）", () => { foreach (var t in targets) ShowProperties(t); }));
                menu.Add(Item(MenuIcons.Zip, $"压缩 {n} 项", () => CompressToZip(targets, afterChange)));
                menu.Add(Item(MenuIcons.Duplicate, $"复制（{n} 项）", () => Duplicate(targets, afterChange)));

                menu.Add(new Separator());

                // 【第 4 组】：剪贴板
                menu.Add(Item(MenuIcons.Copy, $"拷贝（{n} 项）", () => CopyToClipboard(targets)));
                menu.Add(Item(MenuIcons.Cut, $"剪切（{n} 项）", () => CutToClipboard(targets)));
            }
            return menu;
        }

        /// <summary>
        /// <strong>空白处</strong>的右键菜单 —— 资源管理器里点空白就是这一组动作，
        /// 缺了它用户会以为「这个分区不支持右键」。
        /// </summary>
        /// <returns>菜单项列表（理由见 <see cref="BuildItemMenu"/>）。</returns>
        public static List<Control> BuildBlankMenu(
            FileSelection selection,
            IReadOnlyList<FileDisplayItem> visible,
            string currentDir,
            Action newFolder,
            Action newTextFile,
            Action openInExplorer,
            Action refresh,
            Action afterChange)
        {
            void Paste() => PasteInto(currentDir, afterChange);

            var menu = new List<Control>();
            menu.Add(Item(MenuIcons.NewFolder, "新建文件夹", newFolder));
            menu.Add(Item(MenuIcons.NewFile, "新建文本文档", newTextFile));
            var paste = Item(MenuIcons.Paste, "粘贴", Paste);
            paste.IsEnabled = !FileClipboard.Shared.IsEmpty;
            menu.Add(paste);
            menu.Add(new Separator());
            menu.Add(Item(MenuIcons.SelectAll, "全选", () =>
            {
                SelectAll(selection, visible);
                afterChange();
            }));
            var clear = Item(MenuIcons.Clear, "取消选中", () =>
            {
                selection.Clear();
                afterChange();
            });
            clear.IsEnabled = selection.Count > 0;
            menu.Add(clear);
            menu.Add(new Separator());
            menu.Add(Item(MenuIcons.OpenExternally, "在文件资源管理器中打开", openInExplorer));
            menu.Add(Item(MenuIcons.Terminal, "在终端中打开当前目录", () => OpenInTerminal(currentDir)));
            if (IsVSCodeAvailable())
            {
                menu.Add(Item(MenuIcons.Code, "在 VS Code 中打开当前目录", () => OpenInVSCode(currentDir)));
            }
            menu.Add(Item(MenuIcons.Refresh, "立即刷新", refresh));
            return menu;
        }

        private static MenuItem Item(string icon, string header, Action onClick, bool destructive = false)
        {
            var mi = new MenuItem
            {
                Header = header,
                Icon = new TextBlock { Text = icon, FontFamily = new System.Windows.Media.FontFamily("Segoe MDL2 Assets"), FontSize = 14 },
                Foreground = destructive ? System.Windows.Media.Brushes.IndianRed : System.Windows.Media.Brushes.WhiteSmoke
            };
            mi.Click += (_, _) => onClick();
            return mi;
        }

        // MARK: - 剪贴板

        public static void CopyToClipboard(IReadOnlyList<string> paths)
        {
            FileClipboard.Shared.Copy(paths);
            ReportClipboard("已复制", paths.Count);
        }

        public static void CutToClipboard(IReadOnlyList<string> paths)
        {
            FileClipboard.Shared.Cut(paths);
            ReportClipboard("已剪切", paths.Count);
        }

        private static void ReportClipboard(string verb, int count)
        {
            ToastWindow.ShowToast(count == 1 ? $"{verb} 1 项" : $"{verb} {count} 项",
                FileClipboard.Shared.Hint, warn: false);
        }

        /// <summary>
        /// 把内部剪贴板贴到 <paramref name="directory"/>。
        /// <para>
        /// 三条规矩与拖入完全一致（那里踩过的坑这里一样会踩）：
        /// 1. <b>绝不覆盖</b> —— 同名就自动加「 2」后缀（<see cref="FileMover.Destination"/>）；
        /// 2. <b>不能把文件夹贴进自己的子孙目录</b>；
        /// 3. 剪切时<b>同目录 = no-op</b>，否则会报告一次假失败。
        /// </para>
        /// </summary>
        public static void PasteInto(string directory, Action afterChange)
        {
            var clip = FileClipboard.Shared;
            if (clip.IsEmpty || string.IsNullOrEmpty(directory)) return;

            // 同名冲突先问用户（与拖入、mac / Electron 同规则）。
            // 「停止」= 整体取消，且**不清空**剪切板，让用户换个动作重试。
            var conflicts = FileMover.Conflicts(clip.Paths.ToArray(), directory,
                p => File.Exists(p) || Directory.Exists(p));
            var decision = conflicts.Count == 0
                ? MoveConflictDecision.KeepBoth
                : ConflictDialog.Show(conflicts.Select(Path.GetFileName).OfType<string>().ToArray());
            if (decision == MoveConflictDecision.Stop) return;

            int done = 0;
            var failed = new List<string>();

            foreach (var source in clip.Paths.ToList())
            {
                string name = Path.GetFileName(source);
                if (FileMover.IsSelfOrDescendant(directory, source))
                {
                    failed.Add(name);
                    continue;
                }
                if (!File.Exists(source) && !Directory.Exists(source))
                {
                    failed.Add(name);   // 剪切之后又在别处删掉了：给个提示总比静默好
                    continue;
                }

                if (clip.IsCut)
                {
                    // 剪切 = 移动；replace 时 FileMover.Move 会先删目标再移动。
                    var t = FileMover.Move(source, directory, out bool skipped,
                                          replace: decision == MoveConflictDecision.Replace);
                    if (t != null) done++;
                    else if (!skipped) failed.Add(name);
                    continue;
                }

                // 复制分支
                string target;
                if (decision == MoveConflictDecision.Replace)
                {
                    target = FileMover.Normalize(directory) + "/" + name;
                    if (File.Exists(target) || Directory.Exists(target))
                    {
                        try
                        {
                            if (Directory.Exists(target)) Directory.Delete(target, recursive: true);
                            else File.Delete(target);
                        }
                        catch (Exception ex)
                        {
                            System.Diagnostics.Debug.WriteLine($"[DeskIsle] 替换前删除失败 {target}: {ex.Message}");
                            failed.Add(name);
                            continue;
                        }
                    }
                }
                else
                {
                    target = FileMover.Destination(source, directory,
                        p => File.Exists(p) || Directory.Exists(p));
                }

                try
                {
                    if (Directory.Exists(source)) CopyDirectory(source, target);
                    else File.Copy(source, target, overwrite: true);
                    done++;
                }
                catch (Exception ex)
                {
                    System.Diagnostics.Debug.WriteLine($"[DeskIsle] 粘贴失败 {source} → {target}: {ex.Message}");
                    failed.Add(name);
                }
            }

            if (done > 0)
            {
                afterChange();
                ToastWindow.ShowToast(clip.IsCut ? $"已粘贴（移动 {done} 项）" : $"已粘贴（复制 {done} 项）",
                    Path.GetFileName(FileMover.Normalize(directory)), warn: false);
            }
            if (failed.Count > 0)
            {
                ToastWindow.ShowToast($"{failed.Count} 项没能粘贴",
                    string.Join("、", failed.Take(2)), warn: true);
            }
            // ⚠️ 剪切是一次性的：源已经不在原处了，留着再贴一次只会报错。
            // 但「停止」= 整体取消，保留剪切板让用户重试。
            if (clip.IsCut && decision != MoveConflictDecision.Stop) clip.Clear();
        }

        private static void CopyDirectory(string source, string target)
        {
            Directory.CreateDirectory(target);
            foreach (var dir in Directory.GetDirectories(source, "*", SearchOption.AllDirectories))
            {
                Directory.CreateDirectory(dir.Replace(source, target));
            }
            foreach (var file in Directory.GetFiles(source, "*.*", SearchOption.AllDirectories))
            {
                File.Copy(file, file.Replace(source, target), overwrite: true);
            }
        }

        // MARK: - 批量操作

        /// <summary>批量移到回收站。逐项进行：一个卡住不该丢掉其余的。</summary>
        public static void SendToRecycleBin(IReadOnlyList<string> paths)
        {
            if (paths.Count == 0) return;
            int done = 0;
            var failed = new List<string>();
            foreach (var p in paths)
            {
                if (Win32.SendToRecycleBin(p)) done++;
                else failed.Add(Path.GetFileName(p));
            }
            if (done > 0)
            {
                ToastWindow.ShowToast(done == 1 ? "已移到回收站" : $"已移到回收站（{done} 项）",
                    null, warn: false);
            }
            if (failed.Count > 0)
            {
                ToastWindow.ShowToast($"{failed.Count} 项没能移到回收站",
                    string.Join("、", failed.Take(2)), warn: true);
            }
        }

        /// <summary>多选「在资源管理器中定位」—— 一次 explorer 调用选中全部。</summary>
        public static void RevealMany(IReadOnlyList<string> paths)
        {
            // explorer /select 一次只能选中一个；多个就退化为逐个打开（N 个窗口不多，
            // 而且比「只显示第一个、其余静默丢失」要好得多）。
            foreach (var p in paths) FileUI.RevealInExplorer(p);
        }

        // MARK: - 键盘

        /// <summary>
        /// 处理文件列表语境下的按键。
        /// </summary>
        /// <returns>true = 这一下已被消费，不要再往下传。</returns>
        public static bool HandleKey(Key key, ModifierKeys mods,
                                     FileSelection selection,
                                     IReadOnlyList<FileDisplayItem> visible,
                                     string currentDir,
                                     Action<string> rename,
                                     Action preview,
                                     Action afterChange)
        {
            bool primary = mods.HasFlag(ModifierKeys.Control);
            bool shift = mods.HasFlag(ModifierKeys.Shift);
            var fk = FromKey(key);
            if (fk == FileKey.Other) return false;

            var action = FileKeyShortcuts.Action(fk, primary, selection.Count, FileKeyLayout.Pc, shift);
            if (fk == FileKey.Space && action == FileKeyAction.None && !primary && !shift && selection.Count == 0 && visible.Count > 0)
            {
                var first = visible[0].Path;
                selection.Click(first, visible.Select(x => x.Path).ToList());
                afterChange();
                preview();
                return true;
            }

            switch (action)
            {
                case FileKeyAction.None:
                    return false;

                case FileKeyAction.SelectAll:
                    SelectAll(selection, visible);
                    afterChange();
                    return true;

                case FileKeyAction.ClearSelection:
                    selection.Clear();
                    afterChange();
                    return true;

                case FileKeyAction.Trash:
                    var victims = OrderedSelected(selection, visible);
                    SendToRecycleBin(victims);
                    selection.Clear();
                    afterChange();
                    return true;

                case FileKeyAction.Rename:
                    var one = OrderedSelected(selection, visible);
                    if (one.Count == 1) rename(one[0]);
                    return true;

                case FileKeyAction.Preview:
                    if (selection.Count == 1) preview();
                    return true;

                case FileKeyAction.Copy:
                    CopyToClipboard(OrderedSelected(selection, visible));
                    return true;

                case FileKeyAction.Cut:
                    CutToClipboard(OrderedSelected(selection, visible));
                    return true;

                case FileKeyAction.Paste:
                    PasteInto(currentDir, afterChange);
                    return true;

                default:
                    return false;
            }
        }

        /// <summary>WPF 的 <see cref="Key"/> → 归一化键标识（与 mac / Electron 同一张表）。</summary>
        public static FileKey FromKey(Key key) => FileKeyShortcuts.FromName(key switch
        {
            Key.A => "a",
            Key.C => "c",
            Key.X => "x",
            Key.V => "v",
            Key.Escape => "escape",
            Key.Return => "enter",
            Key.F2 => "f2",
            Key.Space => "space",
            Key.Delete => "delete",
            Key.Back => "backspace",
            _ => ""
        });
        public static void ShowProperties(string path)
        {
            try
            {
                var psi = new System.Diagnostics.ProcessStartInfo
                {
                    FileName = path,
                    Verb = "properties",
                    UseShellExecute = true
                };
                System.Diagnostics.Process.Start(psi);
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"[DeskIsle] 查看属性失败: {ex.Message}");
            }
        }

        public static void CompressToZip(IReadOnlyList<string> paths, Action afterChange)
        {
            if (paths.Count == 0) return;
            string parentDir = Path.GetDirectoryName(paths[0]) ?? "";
            string baseName = paths.Count == 1 ? Path.GetFileNameWithoutExtension(paths[0]) : "归档";
            string zipPath = Path.Combine(parentDir, $"{baseName}.zip");
            int counter = 2;
            while (File.Exists(zipPath))
            {
                zipPath = Path.Combine(parentDir, $"{baseName} ({counter}).zip");
                counter++;
            }

            try
            {
                using var archive = System.IO.Compression.ZipFile.Open(zipPath, System.IO.Compression.ZipArchiveMode.Create);
                foreach (var path in paths)
                {
                    if (Directory.Exists(path))
                    {
                        var dirInfo = new DirectoryInfo(path);
                        foreach (var file in dirInfo.GetFiles("*", SearchOption.AllDirectories))
                        {
                            string rel = Path.GetRelativePath(parentDir, file.FullName);
                            archive.CreateEntryFromFile(file.FullName, rel);
                        }
                    }
                    else if (File.Exists(path))
                    {
                        string name = Path.GetFileName(path);
                        archive.CreateEntryFromFile(path, name);
                    }
                }
                afterChange();
                ToastWindow.ShowToast("已生成压缩文件", Path.GetFileName(zipPath), warn: false);
            }
            catch (Exception ex)
            {
                ToastWindow.ShowToast("压缩失败", ex.Message, warn: true);
            }
        }

        public static void Duplicate(IReadOnlyList<string> paths, Action afterChange)
        {
            int done = 0;
            foreach (var path in paths)
            {
                string dir = Path.GetDirectoryName(path) ?? "";
                string name = Path.GetFileNameWithoutExtension(path);
                string ext = Path.GetExtension(path);

                string dest = Path.Combine(dir, $"{name} - 副本{ext}");
                int counter = 2;
                while (File.Exists(dest) || Directory.Exists(dest))
                {
                    dest = Path.Combine(dir, $"{name} - 副本 ({counter}){ext}");
                    counter++;
                }

                try
                {
                    if (Directory.Exists(path)) CopyDirectory(path, dest);
                    else File.Copy(path, dest);
                    done++;
                }
                catch { }
            }
            if (done > 0)
            {
                afterChange();
                ToastWindow.ShowToast(done == 1 ? "已创建副本" : $"已创建 {done} 项副本", "", warn: false);
            }
        }

        public static void OpenInTerminal(string path)
        {
            try
            {
                string dir = Directory.Exists(path) ? path : (Path.GetDirectoryName(path) ?? path);
                var psi = new System.Diagnostics.ProcessStartInfo
                {
                    FileName = "powershell.exe",
                    WorkingDirectory = dir,
                    UseShellExecute = true
                };
                System.Diagnostics.Process.Start(psi);
            }
            catch { }
        }

        public static bool IsVSCodeAvailable()
        {
            try
            {
                string localApp = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                string userCode = Path.Combine(localApp, @"Programs\Microsoft VS Code\Code.exe");
                if (File.Exists(userCode)) return true;

                string progFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
                string sysCode = Path.Combine(progFiles, @"Microsoft VS Code\Code.exe");
                if (File.Exists(sysCode)) return true;

                return false;
            }
            catch { return false; }
        }

        public static void OpenInVSCode(string path)
        {
            try
            {
                var psi = new System.Diagnostics.ProcessStartInfo
                {
                    FileName = "cmd.exe",
                    Arguments = $"/c code \"{path}\"",
                    CreateNoWindow = true,
                    UseShellExecute = false
                };
                System.Diagnostics.Process.Start(psi);
            }
            catch { }
        }
    }

    /// <summary>菜单项图标：Segoe MDL2 Assets 的字形串。</summary>
    internal static class MenuIcons
    {
        public const string EnterBrowse = "\uE8A4";    // FolderHorizontal / OpenLocal
        public const string OpenExternally = "\uE8A7"; // OpenFile
        public const string Reveal = "\uED25";         // OpenInNewWindow
        public const string Copy = "\uE8C8";           // Copy
        public const string Cut = "\uE8C6";            // Cut
        public const string Paste = "\uE77F";          // Paste
        public const string Rename = "\uE8AC";         // Rename
        public const string Delete = "\uE74D";         // Delete
        public const string NewFolder = "\uE8F4";      // NewFolder
        public const string NewFile = "\uE8A5";        // Document
        public const string Terminal = "\uE756";       // CommandPrompt
        public const string Code = "\uE943";           // Code
        public const string SelectAll = "\uE8B3";      // SelectAll
        public const string Clear = "\uE711";          // Cancel
        public const string Refresh = "\uE72C";        // Refresh
        public const string Info = "\uE946";           // Info
        public const string Zip = "\uE8F7";            // Zip
        public const string Duplicate = "\uE90B";      // CopyMore / Duplicate
        public const string Shortcut = "\uE71B";       // Link / Shortcut
        public const string Preview = "\uE890";        // View / Preview
    }
}
