using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace DeskIsle.Services
{
    /// <summary>
    /// 一次文件操作的逆操作。只记「怎么退回去」，不记操作本身：
    /// 用户可能已经自己改过那些文件，旧快照没有意义。
    /// 口径与 mac <c>FileUndoKind</c> 一致。
    /// </summary>
    public enum FileUndoKind
    {
        /// <summary>移回原位（剪切粘贴 / 拖入移动）。<see cref="PathPair.From"/> 是原路径，<see cref="PathPair.To"/> 是现在的位置。</summary>
        MoveBack,
        /// <summary>删掉刚复制出来的目标（永久删除，不进回收站）。</summary>
        RemoveCopies,
        /// <summary>从回收站捡回来。<see cref="PathPair.From"/> 是原路径，<see cref="PathPair.To"/> 是回收站里的实际路径。</summary>
        RestoreFromTrash,
        /// <summary>改回旧名字。</summary>
        Rename,
        /// <summary>删掉新建出来的东西（新建文件 / 文件夹、制作副本）。</summary>
        RemoveCreated
    }

    /// <summary>一对路径。移动类：From = 原位，To = 现在的位置。</summary>
    public readonly record struct PathPair(string From, string To);

    public sealed class FileUndoRecord
    {
        public FileUndoRecord(
            FileUndoKind kind,
            string verb,
            int count,
            IReadOnlyList<PathPair> pairs,
            IReadOnlyList<string> paths,
            string? renamePath,
            string? oldName)
        {
            Kind = kind;
            Verb = verb;
            Count = count;
            Pairs = pairs;
            Paths = paths;
            RenamePath = renamePath;
            OldName = oldName;
        }

        public FileUndoKind Kind { get; }
        /// <summary>展示用的一句话 —— 撤销提示要说清撤销了什么。</summary>
        public string Verb { get; }
        public int Count { get; }
        public IReadOnlyList<PathPair> Pairs { get; }
        public IReadOnlyList<string> Paths { get; }
        public string? RenamePath { get; }
        public string? OldName { get; }
    }

    /// <summary>
    /// 进程级撤销栈，跨分区共用（在 A 分区删、切到 B 分区撤销，用户眼里是同一个「上一步」）。
    /// 上限 30：再久的路径也多半已经被别的程序动过。
    /// </summary>
    public sealed class FileUndoStack
    {
        public const int Limit = 30;

        public static FileUndoStack Shared { get; } = new();

        private readonly List<FileUndoRecord> _records = new();

        public int Count => _records.Count;
        public bool IsEmpty => _records.Count == 0;

        public void PushMoveBack(IEnumerable<PathPair> pairs, string verb)
        {
            var list = pairs.ToArray();
            Add(FileUndoKind.MoveBack, verb, list.Length, list, Array.Empty<string>(), null, null);
        }

        public void PushRemoveCopies(IEnumerable<string> paths, string verb) =>
            PushPaths(FileUndoKind.RemoveCopies, paths, verb);

        public void PushRestoreFromTrash(IEnumerable<PathPair> pairs, string verb)
        {
            var list = pairs.ToArray();
            Add(FileUndoKind.RestoreFromTrash, verb, list.Length, list, Array.Empty<string>(), null, null);
        }

        public void PushRename(string path, string oldName, string verb) =>
            Add(FileUndoKind.Rename, verb, 1, Array.Empty<PathPair>(), Array.Empty<string>(), path, oldName);

        public void PushRemoveCreated(IEnumerable<string> paths, string verb) =>
            PushPaths(FileUndoKind.RemoveCreated, paths, verb);

        /// <summary>弹出最近一条。撤销本身不再入栈，否则 Ctrl+Z 会来回抖。</summary>
        public FileUndoRecord? Pop()
        {
            if (_records.Count == 0) return null;
            int last = _records.Count - 1;
            var rec = _records[last];
            _records.RemoveAt(last);
            return rec;
        }

        private void PushPaths(FileUndoKind kind, IEnumerable<string> paths, string verb)
        {
            var list = paths.Where(p => !string.IsNullOrEmpty(p)).ToArray();
            Add(kind, verb, list.Length, Array.Empty<PathPair>(), list, null, null);
        }

        private void Add(
            FileUndoKind kind, string verb, int count,
            IReadOnlyList<PathPair> pairs, IReadOnlyList<string> paths,
            string? renamePath, string? oldName)
        {
            // 没实际改动就别占一格，否则 Ctrl+Z 会空转。
            if (count <= 0) return;
            _records.Add(new FileUndoRecord(kind, verb, count, pairs, paths, renamePath, oldName));
            if (_records.Count > Limit)
                _records.RemoveRange(0, _records.Count - Limit);
        }
    }

    /// <summary>
    /// 执行一条逆操作。三条规矩与 mac 相同：
    /// 目标不见了就跳过；目标位已被占用也不动；半途失败也算数，有一项成功就算撤销成功。
    /// </summary>
    public static class FileUndoApply
    {
        public static (int Done, int Failed) Apply(FileUndoRecord rec)
        {
            int done = 0;
            int failed = 0;
            switch (rec.Kind)
            {
                case FileUndoKind.MoveBack:
                case FileUndoKind.RestoreFromTrash:
                    foreach (var pair in rec.Pairs)
                    {
                        try
                        {
                            if (TryMoveBack(pair.To, pair.From)) done++;
                            else failed++;
                        }
                        catch
                        {
                            failed++;
                        }
                    }
                    break;

                case FileUndoKind.RemoveCopies:
                case FileUndoKind.RemoveCreated:
                    foreach (var path in rec.Paths)
                    {
                        if (!Exists(path)) continue;
                        try
                        {
                            Remove(path);
                            done++;
                        }
                        catch
                        {
                            failed++;
                        }
                    }
                    break;

                case FileUndoKind.Rename:
                    try
                    {
                        if (TryRenameBack(rec.RenamePath, rec.OldName)) done++;
                        else failed++;
                    }
                    catch
                    {
                        failed++;
                    }
                    break;
            }
            return (done, failed);
        }

        /// <summary>把 <paramref name="current"/> 移回 <paramref name="original"/>。两边状态不对就不动。</summary>
        private static bool TryMoveBack(string current, string original)
        {
            if (string.IsNullOrEmpty(current) || string.IsNullOrEmpty(original)) return false;
            bool currentIsDir = Directory.Exists(current);
            bool currentIsFile = File.Exists(current);
            if (!currentIsDir && !currentIsFile) return false;
            if (Exists(original)) return false;
            if (currentIsDir) Directory.Move(current, original);
            else File.Move(current, original);
            return true;
        }

        private static bool TryRenameBack(string? path, string? oldName)
        {
            if (string.IsNullOrEmpty(path) || string.IsNullOrEmpty(oldName)) return false;
            string? dir = Path.GetDirectoryName(path);
            if (string.IsNullOrEmpty(dir)) return false;
            string target = Path.Combine(dir, oldName);
            if (!Exists(path) || Exists(target)) return false;
            if (Directory.Exists(path)) Directory.Move(path, target);
            else File.Move(path, target);
            return true;
        }

        private static bool Exists(string path) => File.Exists(path) || Directory.Exists(path);

        private static void Remove(string path)
        {
            if (Directory.Exists(path)) Directory.Delete(path, recursive: true);
            else File.Delete(path);
        }
    }
}
