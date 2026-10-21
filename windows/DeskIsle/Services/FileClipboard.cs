using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace DeskIsle.Services
{
    /// <summary>
    /// 分区内的<strong>文件剪贴板</strong>（Ctrl+C / Ctrl+X / Ctrl+V）。
    /// <para>
    /// 应用内与系统剪贴板并存，各管各的（与 mac <c>FileClipboard</c> 同一口径）：
    /// 本类记住「剪切还是复制」，粘贴目标恒为当前浏览目录；
    /// 系统剪贴板只在<b>复制</b>时写入文件路径，让资源管理器也能粘贴。
    /// 系统剪贴板没有「剪切文件」，所以剪切只留在本类里，分区外粘贴不会把源文件移走。
    /// </para><para>
    /// 系统剪贴板的读写在 WPF 层（<c>SystemFileClipboard</c>）。
    /// 本类不引用 <c>System.Windows</c>，测试才能在 macOS 上跑。
    /// 启动时把 <see cref="SyncToSystem"/> 接上即可。
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

        /// <summary>
        /// 复制落到系统剪贴板的钩子。只在路径非空时调用。
        /// 剪切不走这里：写过去分区外会变成复制，再回分区粘贴又把源文件移走，两份并存。
        /// </summary>
        public static Action<IReadOnlyList<string>>? SyncToSystem { get; set; }

        public void Copy(IEnumerable<string> paths)
        {
            Paths = paths.ToList();
            IsCut = false;
            if (Paths.Count > 0) SyncToSystem?.Invoke(Paths);
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

        /// <summary>
        /// 展示用的一句话（Toast 的副标题）。
        /// 剪切要写明「只能在分区内贴」：不说的话，用户在资源管理器里粘贴拿到的是上一份残留内容，
        /// 会以为剪切的路径丢了。
        /// </summary>
        public string Hint
        {
            get
            {
                if (Paths.Count == 0) return string.Empty;
                string what = Paths.Count == 1 ? Path.GetFileName(Paths[0]) : $"{Paths.Count} 个项目";
                return IsCut ? $"{what} · 仅分区内可粘贴" : what;
            }
        }
    }
}
