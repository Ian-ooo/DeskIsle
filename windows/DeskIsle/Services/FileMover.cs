using System;
using System.Collections.Generic;
using System.IO;

namespace DeskIsle.Services
{
    /// <summary>
    /// ⭐ 文件「拖入分区」的落点计算 —— 纯逻辑（不碰磁盘），<b>三端同源</b>
    /// （定义方：mac 的 <c>DeskIsleCore/FileMove.swift</c>；Electron：<c>utils/fileMove.ts</c>）。
    ///
    /// 三条硬规矩（都是踩过或必然会踩的）：
    /// 1. <b>同名不覆盖</b> —— 覆盖不可撤销，多一个「 2」副本用户一眼能看见、随手能删。
    /// 2. <b>不能把文件夹拖进它自己的子孙</b> —— <c>Directory.Move</c> 在部分场景会产出半截结果。
    /// 3. <b>同目录视为 no-op</b> —— 否则「拖出来又拖回去」会弹「已移入 1 个文件」这种假成功。
    /// </summary>
    public static class FileMover
    {
        /// <summary>
        /// 路径归一：<b>本端是反斜杠</b>，所以第一步就是统一成 <c>/</c>，
        /// 后面所有比较都以它为基准。末尾斜杠去掉（盘根 <c>C:\</c> 除外）。
        /// </summary>
        public static string Normalize(string path)
        {
            if (string.IsNullOrWhiteSpace(path)) return string.Empty;
            var p = path.Trim().Replace('\\', '/');
            while (p.Length > 1 && p.EndsWith("/")) p = p.Substring(0, p.Length - 1);
            return p;
        }

        /// <summary>源与目标是否同一目录（同目录 = 不用动）。</summary>
        public static bool IsSameDirectory(string path, string directory)
        {
            var srcDir = Path.GetDirectoryName(Normalize(path)) ?? string.Empty;
            return Normalize(srcDir) == Normalize(directory);
        }

        /// <summary>
        /// <paramref name="directory"/> 是否就是 <paramref name="path"/> 本身或位于其内部。
        /// ⚠️ 末尾补 <c>/</c> 再比前缀：否则 <c>FooBar</c> 会被误判成 <c>Foo</c> 的子目录。
        /// </summary>
        public static bool IsSelfOrDescendant(string directory, string path)
        {
            var dir = Normalize(directory);
            var src = Normalize(path);
            if (dir.Length == 0 || src.Length == 0) return false;
            // Windows 路径不区分大小写
            if (string.Equals(dir, src, StringComparison.OrdinalIgnoreCase)) return true;
            return dir.StartsWith(src + "/", StringComparison.OrdinalIgnoreCase);
        }

        /// <summary>这次移动该不该做（false = 静默跳过，不算失败）。</summary>
        public static bool ShouldMove(string path, string directory)
        {
            if (IsSelfOrDescendant(directory, path)) return false;
            return !IsSameDirectory(path, directory);
        }

        /// <summary>
        /// 落点：目标目录 + 原文件名；同名则追加「 2」「 3」…… （与访达 / 资源管理器一致）。
        /// </summary>
        /// <param name="exists">判断某个完整路径是否已存在（由调用方注入，方便测试）。</param>
        public static string Destination(string path, string directory, Func<string, bool> exists)
        {
            var dir = Normalize(directory);
            var name = Path.GetFileName(Normalize(path));
            var target = dir + "/" + name;
            if (!exists(target)) return target;

            // ⚠️ `.gitignore` 这类**点文件**：首个点就在 0 位，整串都算名字、没有扩展名
            //（与 mac / Electron 的判据一致）。否则会算成「空名字 + 扩展名 .gitignore」，
            // 产出 ` 2.gitignore` 这种三端不一致的怪名字。
            int dot = name.LastIndexOf('.');
            var baseName = dot > 0 ? name.Substring(0, dot) : name;
            var ext = dot > 0 ? name.Substring(dot) : string.Empty;
            int i = 2;
            while (true)
            {
                var candidate = ext.Length == 0 ? $"{baseName} {i}" : $"{baseName} {i}{ext}";
                var full = dir + "/" + candidate;
                if (!exists(full)) return full;
                i++;
            }
        }

        /// <summary>
        /// 找出「会撞名」的源：须满足 <see cref="ShouldMove"/> 为真（同目录 / 拖进自己子孙不算冲突），
        /// 且目标目录里已存在同名的项。同名冲突弹窗靠它触发。返回**源路径**列表。
        /// </summary>
        public static List<string> Conflicts(string[] paths, string directory, Func<string, bool> exists)
        {
            var dir = Normalize(directory);
            var result = new List<string>();
            foreach (var p in paths ?? Array.Empty<string>())
            {
                if (!ShouldMove(p, directory)) continue;
                var name = Path.GetFileName(Normalize(p));
                if (exists(dir + "/" + name)) result.Add(p);
            }
            return result;
        }

        /// <summary>
        /// 真正执行移动。成功返回落点，失败返回 null —— 失败原因由调用方汇总成提示，
        /// 这里<b>不抛异常</b>：一次拖 20 个文件时，不该因为第 3 个失败就丢掉其余 17 个。
        /// </summary>
        /// <param name="replace">为 true 时若目标已存在则先删除再移动（对应「替换」）；默认 false（自动加「 2」）。</param>
        public static string? Move(string path, string directory, out bool skipped, bool replace = false)
        {
            skipped = false;
            if (!ShouldMove(path, directory))
            {
                // 「拖进自己的子孙」算失败（要提示），「同目录」算跳过（不用提示）
                skipped = !IsSelfOrDescendant(directory, path);
                return null;
            }

            var dir = Normalize(directory);
            var name = Path.GetFileName(Normalize(path));
            string target;
            if (replace)
            {
                target = dir + "/" + name;
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
                        return null;
                    }
                }
            }
            else
            {
                target = Destination(path, directory, p => File.Exists(p) || Directory.Exists(p));
            }
            try
            {
                if (Directory.Exists(path)) Directory.Move(path, target);
                else File.Move(path, target);
                return target;
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"[DeskIsle] 移入分区失败 {path} → {target}: {ex.Message}");
                return null;
            }
        }
    }
}
