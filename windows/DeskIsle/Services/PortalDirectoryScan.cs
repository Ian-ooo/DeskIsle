using System;
using System.Collections.Generic;
using System.IO;

namespace DeskIsle.Services
{
    /// <summary>
    /// 映射文件夹一次目录扫描的结果。不含图标、不含 WPF，可以在后台线程构造。
    ///
    /// 字段就是界面要比较的那几样：名字、路径、是不是目录、是不是包、字节大小、修改时间。
    /// 大小为 -1 表示读不出来（包、或者 Length 抛错），界面显示「—」。
    /// 修改时间用 UTC ticks，按时间排序时同大小覆盖也要能看出变化。
    /// </summary>
    public readonly record struct PortalDirEntry(
        string Name,
        string FullPath,
        bool IsDirectory,
        bool IsPackage,
        long Size,
        string Extension,
        long ModifiedUtcTicks);

    /// <summary>
    /// 映射文件夹的目录扫描。口径与原来的列表循环一致：
    /// 跳过带 Hidden 属性的条目，物理目录里的 macOS 包不算文件夹。
    ///
    /// 结果按完整路径排序，这样两次扫描能不能判成「同一份列表」不取决于文件系统的返回顺序。
    /// 全进程共用一把锁：界面线程的手动刷新和后台扫描不会同时把一个大目录读两遍。
    /// </summary>
    public static class PortalDirectoryScan
    {
        private static readonly object Gate = new();

        /// <summary>
        /// 读 <paramref name="path"/>。目录不存在、没有权限、或中途某条读失败时，
        /// 返回已经读到的条目（开头就失败则是空列表），不把异常抛给界面。
        /// </summary>
        public static IReadOnlyList<PortalDirEntry> Read(string? path)
        {
            lock (Gate)
            {
                return ReadUnlocked(path);
            }
        }

        private static IReadOnlyList<PortalDirEntry> ReadUnlocked(string? path)
        {
            var list = new List<PortalDirEntry>();
            if (string.IsNullOrEmpty(path) || !Directory.Exists(path))
                return list;

            IEnumerator<FileSystemInfo>? iter = null;
            try
            {
                iter = new DirectoryInfo(path).EnumerateFileSystemInfos().GetEnumerator();
                while (true)
                {
                    FileSystemInfo info;
                    try
                    {
                        if (!iter.MoveNext()) break;
                        info = iter.Current;
                    }
                    catch
                    {
                        break;
                    }

                    FileAttributes attrs;
                    bool physicalDir;
                    long size = -1;
                    long modified = 0;
                    try
                    {
                        attrs = info.Attributes;
                        physicalDir = (attrs & FileAttributes.Directory) != 0;
                        modified = info.LastWriteTimeUtc.Ticks;
                        if (!physicalDir && info is FileInfo file)
                            size = file.Length;
                    }
                    catch
                    {
                        continue;
                    }

                    if (TryMake(info.FullName, info.Name, attrs, physicalDir, size, modified, out var entry))
                        list.Add(entry);
                }
            }
            catch
            {
                return list;
            }
            finally
            {
                iter?.Dispose();
            }

            list.Sort(static (a, b) => string.Compare(a.FullPath, b.FullPath, StringComparison.OrdinalIgnoreCase));
            return list;
        }

        /// <summary>
        /// 纯分类，不访问磁盘。Hidden 返回 false。包的 <paramref name="isPhysicalDirectory"/> 为 true，
        /// 但 <see cref="PortalDirEntry.IsDirectory"/> 为 false。
        /// </summary>
        public static bool TryMake(
            string fullPath,
            string name,
            FileAttributes attributes,
            bool isPhysicalDirectory,
            long size,
            long modifiedUtcTicks,
            out PortalDirEntry entry)
        {
            entry = default;
            if (string.IsNullOrEmpty(name)) return false;
            if ((attributes & FileAttributes.Hidden) != 0) return false;

            bool isPackage = isPhysicalDirectory && FileKinds.IsPackageName(name);
            bool isDir = FileKinds.IsOpaqueDirectory(name, isPhysicalDirectory);
            entry = new PortalDirEntry(
                name,
                fullPath,
                isDir,
                isPackage,
                isDir ? -1 : size,
                Path.GetExtension(name),
                modifiedUtcTicks);
            return true;
        }

        /// <summary>两条已经按路径排好序的扫描是否逐项相同。</summary>
        public static bool Same(IReadOnlyList<PortalDirEntry> a, IReadOnlyList<PortalDirEntry> b)
        {
            if (a.Count != b.Count) return false;
            for (int i = 0; i < a.Count; i++)
            {
                if (a[i] != b[i]) return false;
            }
            return true;
        }
    }
}
