import Foundation

/// 文件系统条目在 **访达（Finder）语义**下的分类。
///
/// ## 为什么需要它
///
/// macOS 的**包（package）** —— `.app` / `.appex` / `.bundle` / `.framework` /
/// `.plugin` / `.pages` / `.numbers` / `.key` / `.rtfd` / `.xcodeproj` … ——
/// 在文件系统层面**就是目录**：
/// `FileManager.fileExists(atPath:isDirectory:)` 与 `URLResourceValues.isDirectory`
/// 对 `.app` 一律返回 `true`。
///
/// 但访达把包当作**单个不可展开的项**：双击 `Safari.app` 是**启动 Safari**，
/// 而不是钻进 `Safari.app/Contents/MacOS/`。所以「只看 `isDirectory`」的代码
/// 会把应用渲染成蓝色文件夹、双击后停在 `Contents/Resources/…` 里 ——
/// 用户看到的现象就是「映射文件夹识别不了应用，把应用当目录展开」。
///
/// ## 判据
///
/// 以系统的 `isPackageKey` 为准（它按扩展名与 UTI 判定，会随系统数据库更新），
/// 而不是自己维护一张后缀表；`packageExtensions` 只在取不到资源值、或路径是个
/// 目录但资源值缺失时兜底。
///
/// **全项目统一**：凡是「显示文件夹图标 / 双击进去浏览 / 右键展开」的分支，
/// 一律用 `Meta.isDirectory`，不要用 `isPhysicalDirectory`。
public enum FileKinds {

    /// 一个条目的分类结果与常用元数据。
    public struct Meta: Equatable {
        /// `stat` 意义上的目录（**包在这里也是 `true`**）
        public let isPhysicalDirectory: Bool
        /// 是否是个「包」（`.app` 等）
        public let isPackage: Bool
        public let size: Int64
        public let modDate: Date

        /// **本项目统一使用**的判断：是否当文件夹对待。
        ///
        /// = 是目录 **且** 不是包。
        public var isDirectory: Bool { isPhysicalDirectory && !isPackage }

        public init(isPhysicalDirectory: Bool,
                    isPackage: Bool,
                    size: Int64 = 0,
                    modDate: Date = .distantPast) {
            self.isPhysicalDirectory = isPhysicalDirectory
            self.isPackage = isPackage
            self.size = size
            self.modDate = modDate
        }
    }

    /// 兜底用的包后缀（小写、不带点）。
    ///
    /// 正常路径以 `isPackageKey` 为准；这张表只覆盖「资源值取不到，但路径确实是个目录」
    /// 的场景（例如某些网络卷 / 受限权限目录）。**不要**把它当主判据 ——
    /// 自己维护后缀表必然会漏掉第三方注册的包类型。
    public static let packageExtensions: Set<String> = [
        // 可执行 / 插件类
        "app", "appex", "bundle", "framework", "plugin", "kext", "prefpane",
        "qlgenerator", "mdimporter", "saver", "wdgt", "xpc", "scptd", "dmgpart",
        // 工程 / 文档包
        "xcodeproj", "xcworkspace", "playground", "rtfd",
        "pages", "numbers", "key", "sketch", "sparsebundle", "logicx", "band",
    ]

    /// 双击一个条目时的**默认动作**。
    ///
    /// 之所以要把「判据」单独抽成一个枚举，是因为三个端（mac / Windows / Electron）
    /// 都要用同一份口径决定「双击到底是干什么」，而真正执行动作的那部分代码
    /// （打开外部程序 / 弹预览）各有各的 API、没法共用。判据统一、实现各端自理。
    public enum DoubleClickAction: String, Equatable, Sendable {
        /// 目录 / 包：进入该目录（`.app` 这类包走的是打开，因为它们不是 `isDirectory`）
        case enterDirectory
        /// 图片：** partitions 内预览**，不拉起外部程序
        case previewImage
        /// 其余：交给系统默认程序打开
        case openExternally
    }

    /// 走「预览」而不是「外部打开」的图片后缀（小写、不带点）。
    ///
    /// ⚠️ 三端必须同一份清单（`Services/FileKinds.cs`、`utils/fileKinds.ts`），
    /// 否则同一目录在 mac 双击弹出预览、在 Windows 却开起画图。
    ///
    /// 收这份表的两条原则：
    /// - **只收各端都能解码的**。`svg` / `ico` / `pdf` 被排除（WPF 的 `BitmapImage`
    ///   不支持 SVG，mac 的 `NSImage` 表现也不一致），宁可交给系统默认程序，
    ///   也不弹出一个空白预览框。
    /// - **解码失败要能回退**：格式进来靠后缀猜，实际能不能解（HEIF / AVIF / WebP
    ///   依赖系统解码器）只有运行时才知道 → 预览窗口加载失败时应退回外部打开。
    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "webp", "heic", "heif", "avif",
    ]

    /// 压缩归档格式后缀（小写、不带点）。
    public static let archiveExtensions: Set<String> = [
        "zip", "tar", "gz", "tgz", "bz2", "tbz2", "xz", "txz", "7z", "rar", "z"
    ]

    /// 是否「按图片对待」——只看后缀，**不碰文件系统**（列举时已逐条取过资源值，
    /// 这里再 stat 一遍会让每次渲染多一次系统调用）。
    public static func isImage(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        // ⚠️ 点开头的文件（`.png` / `.DS_Store`）**没有扩展名** —— 这是 macOS 的口径。
        // 必须显式挡掉：Windows 的 `Path.GetExtension` 与 Electron 的朴素切串
        // 都会认出 `.png`，三端不统一的话同一份目录会算出不同结果。
        guard !name.isEmpty, !name.hasPrefix(".") else { return false }
        return imageExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// 是否「按压缩归档文件对待」——只看后缀，不碰文件系统。
    public static func isArchive(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, !name.hasPrefix(".") else { return false }
        return archiveExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// 双击某条目的默认动作。**全项目唯一入口**（「按类型区分双击行为」这条需求的落点）。
    ///
    /// - `isDirectory` 必须是本项目口径（`Meta.isDirectory`：物理目录且不是包），
    ///   不是 `stat` 的原生结果 —— 否则 `.app` 会被当成目录钻进去。
    /// - 包（`.app`）在这里落到 `openExternally`，即双击启动应用，与访达一致。
    public static func doubleClickAction(isDirectory: Bool, path: String) -> DoubleClickAction {
        if isDirectory { return .enterDirectory }
        if isImage(path) { return .previewImage }
        return .openExternally
    }

    /// 读取一个路径的**分类与常用元数据**。
    ///
    /// 一次 `resourceValues` 同时取到「是否目录 / 是否包 / 大小 / 修改时间」，
    /// 比原先的「`fileExists` + `attributesOfItem`」两次 stat 还少一次系统调用，
    /// 因此把它当作 `PortalView.load()` 这类逐条循环里的统一取数入口是安全的。
    ///
    /// 路径不存在（或读不到资源值）时返回「不是目录、不是包、大小 0、时间 `distantPast`」，
    /// 与旧代码默认 `isDir = false` 的行为一致 —— 调用方不必再单独做存在性判断。
    public static func meta(ofPath path: String,
                            fileManager fm: FileManager = .default) -> Meta {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey,
                                         .fileSizeKey, .contentModificationDateKey]
        let vals = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys)
        let isDir = vals?.isDirectory ?? false
        // isPackage 取不到时按扩展名兜底；`isDir` 这个前提很关键 ——
        // 否则一个叫 `x.app` 的**普通文件**也会被误判成包（进而被当成可启动项）。
        let ext = (path as NSString).pathExtension.lowercased()
        let isPkg = (vals?.isPackage ?? false)
            || (isDir && packageExtensions.contains(ext))
        return Meta(isPhysicalDirectory: isDir,
                    isPackage: isPkg,
                    size: Int64(vals?.fileSize ?? 0),
                    modDate: vals?.contentModificationDate ?? .distantPast)
    }
}
