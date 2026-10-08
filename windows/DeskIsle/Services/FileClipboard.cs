using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace DeskIsle.Services
{
    /// <summary>
    /// 分区内的<strong>文件剪贴板</strong>（Ctrl+C / Ctrl+X / Ctrl+V）。
    /// <para>
    /// ⚠️ 这是<strong>应用内部</strong>的剪贴板，不是系统 <c>Clipboard</c>。
    /// 之所以不用系统剪贴板：那样一来资源管理器里复制的文件、桌岛里复制的文件会互相污染，
    /// 而两者语义并不完全相同（桌岛的「粘贴」目标恒为当前浏览目录）。
    /// </para><para>
    /// 剪贴板是<strong>进程级单例</strong>：两个分区之间互拷文件是很常见的用法。
    /// </para>
    /// </summary>
    public sealed class FileClipboard
    {
        private FileClipboard() { }

        public static FileClipboard Shared { get; } = new();

        /// <summary>待粘贴的路径快照。</summary>
        public IReadOnlyList<string> Paths { get; private set; } = new List<string>();

        /// <summary>true = 剪切（粘贴时移动源文件）；false = 复制。</summary>
        public bool IsCut { get; private set; }

        public bool IsEmpty => Paths.Count == 0;

        public void Copy(IEnumerable<string> paths)
        {
            Paths = paths.ToList();
            IsCut = false;
        }

        public void Cut(IEnumerable<string> paths)
        {
            Paths = paths.ToList();
            IsCut = true;
        }

        /// <summary>剪切粘贴完成后必须清空：源文件已经不在原处，再贴一次只会报错。</summary>
        public void Clear()
        {
            Paths = new List<string>();
            IsCut = false;
        }

        /// <summary>展示用的一句话（Toast 的副标题）。</summary>
        public string Hint => Paths.Count switch
        {
            0 => string.Empty,
            1 => Path.GetFileName(Paths[0]),
            _ => $"{Paths.Count} 个项目"
        };
    }
}
