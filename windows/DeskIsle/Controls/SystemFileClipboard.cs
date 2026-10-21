using System;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.IO;
using System.Windows;

namespace DeskIsle.Controls
{
    /// <summary>
    /// 系统剪贴板里的文件列表（资源管理器能读、也能写的那一份）。
    /// <para>
    /// 只写文件路径，不写剪切标记：系统剪贴板没有「剪切文件」，
    /// 分区外粘贴一律是复制。空列表不写，避免把用户别处复制的文字清掉。
    /// </para>
    /// </summary>
    internal static class SystemFileClipboard
    {
        public static void WriteFiles(IReadOnlyList<string> paths)
        {
            var existing = new StringCollection();
            foreach (string? path in paths)
            {
                if (string.IsNullOrEmpty(path)) continue;
                if (File.Exists(path) || Directory.Exists(path)) existing.Add(path);
            }
            if (existing.Count == 0) return;
            try
            {
                Clipboard.SetFileDropList(existing);
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"[DeskIsle] 同步系统剪贴板失败: {ex.Message}");
            }
        }

        public static bool HasFiles()
        {
            try { return Clipboard.ContainsFileDropList(); }
            catch { return false; }
        }

        /// <summary>只认本地还在的文件。网页链接和纯文本不当成能贴的文件。</summary>
        public static List<string> ReadFiles()
        {
            var result = new List<string>();
            try
            {
                if (!Clipboard.ContainsFileDropList()) return result;
                StringCollection? list = Clipboard.GetFileDropList();
                if (list == null) return result;
                foreach (string? path in list)
                {
                    if (string.IsNullOrEmpty(path)) continue;
                    if (File.Exists(path) || Directory.Exists(path)) result.Add(path);
                }
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"[DeskIsle] 读取系统剪贴板失败: {ex.Message}");
            }
            return result;
        }
    }
}
