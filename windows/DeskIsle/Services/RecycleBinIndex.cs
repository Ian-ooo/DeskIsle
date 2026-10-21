using System;
using System.IO;
using System.Text;

namespace DeskIsle.Services
{
    /// <summary>
    /// 从回收站的 <c>$I</c> 索引找回「刚删掉的那个文件现在叫什么」。
    /// <para>
    /// mac 的 <c>trashItem</c> 会直接交回废纸篓里的新路径；Windows 的
    /// <c>SHFileOperation</c> 不保证交回。没有这条路径，Ctrl+Z 就捡不回来。
    /// 格式：Vista 起的 version 1（路径固定 260 个 UTF-16 字符）和 Windows 10 的
    /// version 2（路径长度 + 变长 UTF-16，长度含结尾 NUL）。
    /// </para>
    /// </summary>
    public static class RecycleBinIndex
    {
        /// <summary>解析一份 <c>$I</c> 文件。失败返回 false，不抛。</summary>
        public static bool TryParse(byte[] data, out string originalPath, out long deletedFileTime)
        {
            originalPath = string.Empty;
            deletedFileTime = 0;
            if (data == null || data.Length < 24) return false;

            long version = ReadInt64(data, 0);
            deletedFileTime = ReadInt64(data, 16);

            if (version == 1)
            {
                const int nameBytes = 520;
                if (data.Length < 24 + nameBytes) return false;
                originalPath = DecodeUtf16(data, 24, nameBytes);
                return originalPath.Length > 0;
            }

            if (version == 2)
            {
                if (data.Length < 28) return false;
                uint chars = ReadUInt32(data, 24);
                if (chars == 0 || chars > 32_768) return false;
                int byteLen = (int)chars * 2;
                if (data.Length < 28 + byteLen) return false;
                originalPath = DecodeUtf16(data, 28, byteLen);
                return originalPath.Length > 0;
            }

            return false;
        }

        /// <summary>
        /// 在 <paramref name="recycleRoot"/>（通常是 <c>X:\$Recycle.Bin</c>）下找
        /// 与 <paramref name="originalPath"/> 匹配、删除时间最新的那份 <c>$R</c>。
        /// </summary>
        public static string? LocateIn(string? recycleRoot, string? originalPath)
        {
            if (string.IsNullOrEmpty(recycleRoot) || string.IsNullOrEmpty(originalPath)) return null;
            if (!Directory.Exists(recycleRoot)) return null;

            string want = originalPath.TrimEnd('\\', '/');
            string? best = null;
            long bestTime = long.MinValue;

            System.Collections.Generic.IEnumerable<string> sids;
            try { sids = Directory.EnumerateDirectories(recycleRoot); }
            catch { return null; }

            foreach (string sid in sids)
            {
                System.Collections.Generic.IEnumerable<string> infos;
                try { infos = Directory.EnumerateFiles(sid, "$I*"); }
                catch { continue; }

                foreach (string info in infos)
                {
                    try
                    {
                        if (!TryParse(File.ReadAllBytes(info), out string path, out long time)) continue;
                        if (!string.Equals(path.TrimEnd('\\', '/'), want, StringComparison.OrdinalIgnoreCase)) continue;
                        if (time < bestTime) continue;

                        string name = Path.GetFileName(info);
                        if (name.Length < 3) continue;
                        string recycled = Path.Combine(sid, "$R" + name.Substring(2));
                        if (!File.Exists(recycled) && !Directory.Exists(recycled)) continue;
                        bestTime = time;
                        best = recycled;
                    }
                    catch
                    {
                        // 别人的 SID 目录、半截索引，跳过即可。
                    }
                }
            }
            return best;
        }

        /// <summary>按源文件所在盘找回收站。UNC 或不完整路径返回 null。</summary>
        public static string? LocateFor(string? originalPath)
        {
            if (string.IsNullOrEmpty(originalPath)) return null;
            string? root = Path.GetPathRoot(originalPath);
            if (string.IsNullOrEmpty(root) || root.StartsWith(@"\\", StringComparison.Ordinal)) return null;
            return LocateIn(Path.Combine(root, "$Recycle.Bin"), originalPath);
        }

        private static long ReadInt64(byte[] data, int offset)
        {
            return data[offset]
                | ((long)data[offset + 1] << 8)
                | ((long)data[offset + 2] << 16)
                | ((long)data[offset + 3] << 24)
                | ((long)data[offset + 4] << 32)
                | ((long)data[offset + 5] << 40)
                | ((long)data[offset + 6] << 48)
                | ((long)data[offset + 7] << 56);
        }

        private static uint ReadUInt32(byte[] data, int offset)
        {
            return (uint)(data[offset]
                | (data[offset + 1] << 8)
                | (data[offset + 2] << 16)
                | (data[offset + 3] << 24));
        }

        private static string DecodeUtf16(byte[] data, int offset, int byteCount)
        {
            string text = Encoding.Unicode.GetString(data, offset, byteCount);
            int nul = text.IndexOf('\0');
            return nul >= 0 ? text.Substring(0, nul) : text;
        }
    }
}
