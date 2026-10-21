using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using DeskIsle.Services;
using Xunit;

namespace DeskIsle.Tests
{
    public class FileClipboardTests
    {
        public FileClipboardTests()
        {
            FileClipboard.SyncToSystem = null;
            FileClipboard.Shared.Clear();
        }

        [Fact]
        public void CopyHintNamesTheItemAndCutSaysPartitionOnly()
        {
            var clip = FileClipboard.Shared;
            clip.Copy(new[] { "C:/docs/a.txt" });
            Assert.False(clip.IsCut);
            Assert.Equal("a.txt", clip.Hint);

            clip.Cut(new[] { "C:/docs/a.txt", "C:/docs/b.txt" });
            Assert.True(clip.IsCut);
            Assert.Equal("2 个项目 · 仅分区内可粘贴", clip.Hint);
        }

        [Fact]
        public void CopySyncsSystemClipboardAndCutDoesNot()
        {
            int copies = 0;
            FileClipboard.SyncToSystem = _ => copies++;
            try
            {
                FileClipboard.Shared.Copy(new[] { "C:/docs/a.txt" });
                FileClipboard.Shared.Cut(new[] { "C:/docs/a.txt" });
                FileClipboard.Shared.Copy(Array.Empty<string>());
                Assert.Equal(1, copies);
            }
            finally
            {
                FileClipboard.SyncToSystem = null;
                FileClipboard.Shared.Clear();
            }
        }
    }

    public class FileUndoTests
    {
        [Fact]
        public void EmptyPushIsIgnoredAndStackKeepsTheNewestThirty()
        {
            var stack = new FileUndoStack();
            stack.PushRemoveCreated(Array.Empty<string>(), "新建文本文件");
            Assert.True(stack.IsEmpty);

            for (int i = 0; i < 40; i++)
                stack.PushRemoveCreated(new[] { $"f{i}" }, "新建文本文件");

            Assert.Equal(FileUndoStack.Limit, stack.Count);
            var newest = stack.Pop();
            Assert.Equal("f39", newest!.Paths[0]);
            // 丢掉的是最早的 10 条，栈底现在是 f10。
            FileUndoRecord? oldest = null;
            while (!stack.IsEmpty) oldest = stack.Pop();
            Assert.Equal("f10", oldest!.Paths[0]);
        }

        [Fact]
        public void MoveBackRestoresAndRefusesAnOccupiedOriginal()
        {
            string dir = NewDir();
            try
            {
                string origin = Path.Combine(dir, "a.txt");
                string moved = Path.Combine(dir, "b.txt");
                File.WriteAllText(moved, "x");

                var stack = new FileUndoStack();
                stack.PushMoveBack(new[] { new PathPair(origin, moved) }, "粘贴（移动）");
                var (done, failed) = FileUndoApply.Apply(stack.Pop()!);
                Assert.Equal(1, done);
                Assert.Equal(0, failed);
                Assert.Equal("x", File.ReadAllText(origin));
                Assert.False(File.Exists(moved));

                string blocked = Path.Combine(dir, "c.txt");
                File.WriteAllText(origin, "kept");
                File.WriteAllText(blocked, "new");
                var (done2, failed2) = FileUndoApply.Apply(new FileUndoRecord(
                    FileUndoKind.MoveBack, "粘贴（移动）", 1,
                    new[] { new PathPair(origin, blocked) },
                    Array.Empty<string>(), null, null));
                Assert.Equal(0, done2);
                Assert.Equal(1, failed2);
                Assert.Equal("kept", File.ReadAllText(origin));
                Assert.Equal("new", File.ReadAllText(blocked));
            }
            finally { Directory.Delete(dir, recursive: true); }
        }

        [Fact]
        public void RemoveCopiesDeletesTheCopyAndSkipsWhatIsAlreadyGone()
        {
            string dir = NewDir();
            try
            {
                string copy = Path.Combine(dir, "a.txt");
                string folder = Path.Combine(dir, "sub");
                File.WriteAllText(copy, "x");
                Directory.CreateDirectory(folder);
                File.WriteAllText(Path.Combine(folder, "inner.txt"), "y");

                var rec = new FileUndoRecord(
                    FileUndoKind.RemoveCopies, "粘贴（复制）", 3,
                    Array.Empty<PathPair>(),
                    new[] { copy, folder, Path.Combine(dir, "missing.txt") },
                    null, null);
                var (done, failed) = FileUndoApply.Apply(rec);
                Assert.Equal(2, done);
                Assert.Equal(0, failed);
                Assert.False(File.Exists(copy));
                Assert.False(Directory.Exists(folder));
            }
            finally { Directory.Delete(dir, recursive: true); }
        }

        [Fact]
        public void RenameGoesBackToTheOldName()
        {
            string dir = NewDir();
            try
            {
                string now = Path.Combine(dir, "new.txt");
                File.WriteAllText(now, "x");
                var (done, failed) = FileUndoApply.Apply(new FileUndoRecord(
                    FileUndoKind.Rename, "重命名", 1,
                    Array.Empty<PathPair>(), Array.Empty<string>(),
                    now, "old.txt"));
                Assert.Equal(1, done);
                Assert.Equal(0, failed);
                Assert.Equal("x", File.ReadAllText(Path.Combine(dir, "old.txt")));
            }
            finally { Directory.Delete(dir, recursive: true); }
        }

        private static string NewDir()
        {
            string dir = Path.Combine(Path.GetTempPath(), "deskisle-undo-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(dir);
            return dir;
        }
    }

    public class RecycleBinIndexTests
    {
        [Fact]
        public void ParsesVersion1AndVersion2Paths()
        {
            byte[] v1 = Index(version: 1, deleted: 10, path: @"C:\docs\a.txt", v2: false);
            Assert.True(RecycleBinIndex.TryParse(v1, out string p1, out long t1));
            Assert.Equal(@"C:\docs\a.txt", p1);
            Assert.Equal(10, t1);

            byte[] v2 = Index(version: 2, deleted: 20, path: @"D:\long\b.txt", v2: true);
            Assert.True(RecycleBinIndex.TryParse(v2, out string p2, out long t2));
            Assert.Equal(@"D:\long\b.txt", p2);
            Assert.Equal(20, t2);

            Assert.False(RecycleBinIndex.TryParse(new byte[8], out _, out _));
        }

        [Fact]
        public void LocatePicksTheNewestMatchingDollarR()
        {
            string root = Path.Combine(Path.GetTempPath(), "deskisle-recycle-" + Guid.NewGuid().ToString("N"));
            string sid = Path.Combine(root, "S-1-5-21-1");
            Directory.CreateDirectory(sid);
            try
            {
                string original = @"C:\docs\a.txt";
                WritePair(sid, "AAAAAA.txt", original, deleted: 10);
                WritePair(sid, "BBBBBB.txt", original, deleted: 50);
                WritePair(sid, "CCCCCC.txt", @"C:\docs\other.txt", deleted: 99);
                File.WriteAllText(Path.Combine(sid, "$RBBBBBB.txt"), "newer");

                string? found = RecycleBinIndex.LocateIn(root, original);
                Assert.Equal(Path.Combine(sid, "$RBBBBBB.txt"), found);
            }
            finally { Directory.Delete(root, recursive: true); }
        }

        private static void WritePair(string sid, string suffix, string original, long deleted)
        {
            File.WriteAllBytes(Path.Combine(sid, "$I" + suffix), Index(2, deleted, original, v2: true));
            File.WriteAllText(Path.Combine(sid, "$R" + suffix), "data");
        }

        private static byte[] Index(long version, long deleted, string path, bool v2)
        {
            byte[] chars = Encoding.Unicode.GetBytes(path + "\0");
            var data = new List<byte>();
            data.AddRange(BitConverter.GetBytes(version));
            data.AddRange(BitConverter.GetBytes(0L));
            data.AddRange(BitConverter.GetBytes(deleted));
            if (!v2)
            {
                var field = new byte[520];
                Buffer.BlockCopy(chars, 0, field, 0, chars.Length);
                data.AddRange(field);
            }
            else
            {
                data.AddRange(BitConverter.GetBytes((uint)(path.Length + 1)));
                data.AddRange(chars);
            }
            return data.ToArray();
        }
    }
}
