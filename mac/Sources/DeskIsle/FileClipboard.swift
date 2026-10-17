import AppKit

/// 分区内的**文件剪贴板**（⌘C / ⌘X / ⌘V）。
///
/// ## 为什么应用内与系统剪贴板**并存**
///
/// 这里有两个剪贴板，缺一不可：
///
/// |剪贴板 | 读者 | 用途 |
/// |---|---|---|
/// | 本类（应用内） | 桌岛自己的 ⌘V | 记住「剪切还是复制」，粘贴目标恒为当前浏览目录 |
/// | `NSPasteboard.general` | 访达 / 备忘录 / 任何其他应用 | 跨应用互通 |
///
/// ⚠️ **只写应用内剪贴板会导致「桌岛里 ⌘C 复制文件，分区外粘贴不出来」** ——
/// 访达读的是系统剪贴板，它完全不知道桌岛复制过什么。症状是「按了 ⌘C 有提示（Toast
/// 说「已复制 N 项」），但去访达里 ⌘V 是空的」，看起来像快捷键坏了。
///
/// ⚠️ 早期注释曾断言「不用系统剪贴板是为了避免两边互相污染」，这个顾虑**不成立**：
/// 「剪切 vs 复制」这个状态由本类独存，系统剪贴板只写**文件 URL**，
/// 不含剪切标记 —— 所以不会污染，系统也不会误解。两边各管各的，读取时按优先级取。
///
/// ⚠️ **只写系统剪贴板同样不够**：那会丢掉剪切语义，
/// 且桌岛粘贴时无法保证「同名加后缀、文件夹不贴进自己子孙目录」这三条规矩。
///
/// 剪贴板是**进程级单例**：两个分区之间互拷文件是很常见的用法。
final class FileClipboard {
    static let shared = FileClipboard()

    private init() {}

    /// 待粘贴的路径快照。
    private(set) var paths: [String] = []
    /// true = 剪切（粘贴时移动源文件）；false = 复制。
    private(set) var isCut = false

    var isEmpty: Bool { paths.isEmpty }

    func copy(_ newPaths: [String]) {
        paths = newPaths
        isCut = false
        syncToSystemPasteboard(newPaths)
    }

    func cut(_ newPaths: [String]) {
        paths = newPaths
        isCut = true
        // ⚠️ 剪切**刻意不同步到系统剪贴板**。系统剪贴板没有「剪切文件」的概念，
        // 写过去用户在分区外 ⌘V 拿到的必然是**副本**，于是出现：
        // 「桌岛剪切 → 访达粘贴得到副本 → 回桌岛粘贴又把源文件移走」→ 原件与副本并存。
        // 这比「粘贴不出来」更难收拾。所以剪切只在桌岛内可用（详见 `hint` 的提示）。
    }

    /// 把文件 URL 同步到**系统**剪贴板，让分区外（访达等）也能粘贴。
    ///
    /// 只写 `NSFilenamesPboardType` / `public.file-url`，**不带剪切标记**：
    /// 系统剪贴板没有「剪切文件」这个概念（访达的剪切靠私有标记实现），
    /// 所以分区外粘贴一律按**复制**处理 —— 这也正是预期行为，
    /// 用户在分区外粘贴不该让源文件凭空消失。
    ///
    /// ⚠️ `clearContents()` 会清掉整个系统剪贴板。这是 API 语义决定的，没法只覆盖
    /// 某一种 type。后果是「在桌岛里 ⌘C 覆盖了之前从别处复制的文字」——
    /// 这与访达的行为一致（访达复制文件同样会覆盖文字剪贴板），属于可接受的取舍。
    /// 但**只在真的复制了非空路径时才写**，避免空剪贴板操作把用户别处的文本清掉。
    private func syncToSystemPasteboard(_ newPaths: [String]) {
        guard !newPaths.isEmpty else { return }
        let urls = newPaths
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
    }

    /// 剪切粘贴完成后必须清空：源文件已经不存在了，再贴一次只会报错。
    func clear() {
        paths = []
        isCut = false
    }

    /// 展示用的一句话（Toast 用）。
    var hint: String {
        guard !paths.isEmpty else { return "" }
        let what = paths.count == 1
            ? ((paths[0] as NSString).lastPathComponent)
            : "\(paths.count) 个项目"
        // 剪切要额外提醒一句「只能在分区内贴」—— 不说的话，用户在访达里 ⌘V 拿到
        // 上一份残留内容，会以为剪切的路径丢了。措辞只说事实，不解释实现。
        return isCut ? "\(what) · 仅分区内可粘贴" : what
    }
}
