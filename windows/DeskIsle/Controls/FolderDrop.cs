using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using DeskIsle.Services;
using DeskIsle.Views;

namespace DeskIsle.Controls
{
    /// <summary>
    /// 把「拖文件进分区」这件事从 PortalView 里抽出来共用。
    ///
    /// ⚠️ 两个视图的落点语义完全一样（拖到空白处 = 进当前目录；拖到某个文件夹条目上 = 进那个文件夹），
    /// 分开写必然会在某一端漏掉「不覆盖同名」或「拒绝拖进自己」这两条。
    /// </summary>
    internal static class FolderDrop
    {
        /// <summary>拖拽悬停：显式声明接受「移动」，否则系统默认给的是「不允许」光标。</summary>
        public static void OnDragOver(DragEventArgs e)
        {
            if (e.Data.GetDataPresent(DataFormats.FileDrop))
            {
                e.Effects = DragDropEffects.Move;
                e.Handled = true;
            }
            else
            {
                e.Effects = DragDropEffects.None;
                e.Handled = true;
            }
        }

        /// <summary>
        /// 落点处理：把拖进来的文件<b>移动</b>进 <paramref name="directory"/>。
        /// </summary>
        /// <returns>成功移动的个数；失败项会通过 <c>ToastWindow</c> 提示。</returns>
        public static int OnDrop(DragEventArgs e, string directory, Action? onChanged = null)
        {
            e.Handled = true;
            if (string.IsNullOrWhiteSpace(directory)) return 0;
            if (!e.Data.GetDataPresent(DataFormats.FileDrop)) return 0;

            var paths = (e.Data.GetData(DataFormats.FileDrop) as string[] ?? Array.Empty<string>())
                        .Where(p => !string.IsNullOrWhiteSpace(p))
                        .ToArray();
            if (paths.Length == 0) return 0;

            // ⚠️ 告诉 FileDragSource「这次拖放是本应用自己接的」：
            // 它结束后就不能再删一次原件 —— 文件已经被这里搬进目标分区了。
            // （用户选「停止」时不搬，也正因此不删，语义一致。）
            FileDragSource.InAppDropHandled = true;

            // 同名冲突先问用户（保留两者 / 停止 / 替换），与粘贴、mac / Electron 同规则。
            var conflicts = FileMover.Conflicts(paths, directory, p => File.Exists(p) || Directory.Exists(p));
            var decision = conflicts.Count == 0
                ? MoveConflictDecision.KeepBoth
                : ConflictDialog.Show(conflicts.Select(Path.GetFileName).OfType<string>().ToArray());
            if (decision == MoveConflictDecision.Stop) return 0;

            int moved = 0;
            var failed = new List<string>();

            foreach (var path in paths)
            {
                var target = FileMover.Move(path, directory, out bool skipped,
                                           replace: decision == MoveConflictDecision.Replace);
                if (target != null) moved++;
                else if (!skipped) failed.Add(Path.GetFileName(path));
            }

            if (moved > 0)
            {
                onChanged?.Invoke();
                ToastWindow.ShowToast(
                    $"已移入 {moved} 个文件",
                    DropDetail(directory),
                    warn: false);
            }
            if (failed.Count > 0)
            {
                ToastWindow.ShowToast(
                    $"{failed.Count} 个文件没能移入",
                    string.Join("、", failed.Take(2)),
                    warn: true);
            }
            return moved;
        }

        /// <summary>
        /// 落点提示文字：过长只留末几段（与 mac 端 <c>dropDetail</c> 同口径）。
        ///
        /// 为什么不能像以前那样只给 <c>Path.GetFileName</c>（只显示 "ioc"）：
        /// 同名子目录到处都是，只看末段判断不出文件进了哪一层 ——
        /// 这正是「文件夹拖不见了」的加重因素。写清楚落点，放错了也知道去哪儿找回来。
        /// </summary>
        public static string DropDetail(string directory)
        {
            var d = FileMover.Normalize(directory ?? string.Empty);
            var parts = d.Split(new[] { Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar },
                                StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length > 3)
                return "…" + Path.DirectorySeparatorChar
                       + string.Join(Path.DirectorySeparatorChar.ToString(),
                                     parts.Skip(parts.Length - 3));
            return d;
        }

        /// <summary>拖到某个条目上时：只有目录才接受（文件上落下没有意义）。</summary>
        public static bool AcceptsOnItem(DragEventArgs e, bool isDirectory)
        {
            if (!isDirectory) return false;
            OnDragOver(e);
            return true;
        }
    }
}
