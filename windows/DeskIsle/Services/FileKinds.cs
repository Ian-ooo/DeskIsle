using System;
using System.Collections.Generic;
using System.IO;

namespace DeskIsle.Services
{
    /// <summary>
    /// 「包（package）」判定 —— 与 mac 端 <c>DeskIsleCore/FileKinds.swift</c>、
    /// Electron 端 <c>src/utils/fileKinds.ts</c> 保持**同一份口径**。
    ///
    /// macOS 的 <c>.app</c> / <c>.bundle</c> / <c>.pages</c> … 在文件系统层面就是目录
    /// （<c>FileAttributes.Directory</c> 为真、<c>Directory.Exists</c> 为真），
    /// 但访达把它们当作**单个不可展开的项**：双击 <c>.app</c> 是**启动应用**，
    /// 而不是钻进 <c>Foo.app/Contents/MacOS</c>。
    ///
    /// Windows 本身没有「包」这个概念（<c>.lnk</c> 是普通文件），这个类只为
    /// **跨端一致**而存在：共享盘、同步目录里照样会出现 <c>.app</c>，
    /// 若按普通目录处理，就会显示成文件夹、双击展开成一串 <c>Contents/…</c>。
    ///
    /// ⚠️ 三个平台的清单必须**同步修改** —— 否则同一份目录在三端会长得不一样。
    /// </summary>
    public static class FileKinds
    {
        /// <summary>
        /// 与 mac 端 <c>FileKinds.packageExtensions</c>、Electron 端
        /// <c>MAC_PACKAGE_EXTENSIONS</c> 完全相同的清单。
        /// </summary>
        public static readonly string[] PackageExtensions =
        {
            // 可执行 / 插件类
            "app", "appex", "bundle", "framework", "plugin", "kext", "prefpane",
            "qlgenerator", "mdimporter", "saver", "wdgt", "xpc", "scptd", "dmgpart",
            // 工程 / 文档包
            "xcodeproj", "xcworkspace", "playground", "rtfd",
            "pages", "numbers", "key", "sketch", "sparsebundle", "logicx", "band",
        };

        private static readonly HashSet<string> Lookup =
            new HashSet<string>(PackageExtensions, StringComparer.OrdinalIgnoreCase);

        /// <summary>名字本身是否像 macOS 的包（只看扩展名，不访问文件系统）。</summary>
        public static bool IsPackageName(string name)
        {
            if (string.IsNullOrEmpty(name)) return false;
            int dot = name.LastIndexOf('.');
            // dot &lt;= 0：无扩展名，或以点开头（隐藏文件，如 .DS_Store）
            if (dot <= 0 || dot == name.Length - 1) return false;
            return Lookup.Contains(name.Substring(dot + 1));
        }

        /// <summary>
        /// 该条目是否应按**文件夹**对待：是目录 **且** 不是包。
        ///
        /// 这是全项目统一入口 —— 凡是「显示文件夹图标 / 双击进入 / 右键展开」的分支
        /// 都必须用它，而不是直接看 <c>FileAttributes.Directory</c>。
        /// </summary>
        public static bool IsOpaqueDirectory(string name, bool isPhysicalDirectory)
            => isPhysicalDirectory && !IsPackageName(name);

        // MARK: - 双击动作（与 mac FileKinds.DoubleClickAction 同源）

        /// <summary>
        /// 双击一个条目时的默认动作。<c>mac FileKinds.DoubleClickAction</c> 的镜像。
        /// </summary>
        public enum OpenAction
        {
            /// <summary>目录：进入该目录。</summary>
            EnterDirectory,
            /// <summary>图片：弹**内置预览**，不拉起外部程序。</summary>
            PreviewImage,
            /// <summary>其余（含包）：交给系统默认程序。</summary>
            OpenExternally,
        }

        /// <summary>
        /// 走「预览」而非「外部打开」的图片后缀 —— 与 mac <c>imageExtensions</c>、
        /// Electron <c>IMAGE_EXTENSIONS</c> 同一份清单。
        ///
        /// 只收 WPF <c>BitmapImage</c> 能解的格式：<c>svg</c> 不在内（WPF 原生不支持），
        /// 进来会得到一个空白预览框，还不如交给系统默认程序。
        /// <c>heic / avif / webp</c> 依赖系统解码器，解不开时预览窗口应回退到外部打开。
        /// </summary>
        public static readonly string[] ImageExtensions =
        {
            "png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "webp", "heic", "heif", "avif",
        };

        private static readonly HashSet<string> ImageLookup =
            new HashSet<string>(ImageExtensions, StringComparer.OrdinalIgnoreCase);

        /// <summary>压缩归档文件后缀。</summary>
        public static readonly string[] ArchiveExtensions =
        {
            "zip", "tar", "gz", "tgz", "bz2", "tbz2", "xz", "txz", "7z", "rar", "z"
        };

        private static readonly HashSet<string> ArchiveLookup =
            new HashSet<string>(ArchiveExtensions, StringComparer.OrdinalIgnoreCase);

        /// <summary>是否按图片对待 —— 只看后缀，不访问文件系统。</summary>
        public static bool IsImage(string path)
        {
            if (string.IsNullOrEmpty(path)) return false;
            string name = Path.GetFileName(path.TrimEnd('/', '\\'));
            // ⚠️ 点开头的文件没有扩展名（macOS 口径）。必须显式挡掉：
            // `Path.GetExtension(".png")` 会返回 ".png"，而 mac 端返回空 ——
            // 不统一的话同一份目录在三端双击会走向不同分支。
            if (string.IsNullOrEmpty(name) || name[0] == '.') return false;
            return ImageLookup.Contains(Path.GetExtension(name).TrimStart('.'));
        }

        /// <summary>是否按压缩归档文件对待 —— 只看后缀，不访问文件系统。</summary>
        public static bool IsArchive(string path)
        {
            if (string.IsNullOrEmpty(path)) return false;
            string name = Path.GetFileName(path.TrimEnd('/', '\\'));
            if (string.IsNullOrEmpty(name) || name[0] == '.') return false;
            return ArchiveLookup.Contains(Path.GetExtension(name).TrimStart('.'));
        }

        /// <summary>
        /// 双击某条目的默认动作。**全项目唯一入口**。
        /// <paramref name="isDirectory"/> 必须是本项目口径（目录且不是包），
        /// 不是 <c>Directory.Exists</c> 的原生结果 —— 否则 <c>.app</c> 会被当目录钻进去。
        /// </summary>
        public static OpenAction DefaultAction(bool isDirectory, string path)
        {
            if (isDirectory) return OpenAction.EnterDirectory;
            if (IsImage(path)) return OpenAction.PreviewImage;
            return OpenAction.OpenExternally;
        }
    }
}
