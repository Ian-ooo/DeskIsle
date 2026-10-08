import AppKit
import DeskIsleCore

/// 分区内的**文件剪贴板**（⌘C / ⌘X / ⌘V）。
///
/// ⚠️ 这是**应用内部**的剪贴板，不是系统 `NSPasteboard`。
/// 之所以不用系统剪贴板：那样一来访达里复制的文件、桌岛里复制的文件会互相污染，
/// 而两者的语义并不完全相同（桌岛的「粘贴」目标恒为当前浏览目录）。等到真的需要
/// 与系统互通时，应当显式同步 `NSPasteboard` 的文件 URL，而不是直接读它。
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
    }

    func cut(_ newPaths: [String]) {
        paths = newPaths
        isCut = true
    }

    /// 剪切粘贴完成后必须清空：源文件已经不存在了，再贴一次只会报错。
    func clear() {
        paths = []
        isCut = false
    }

    /// 展示用的一句话（Toast 用）。
    var hint: String {
        guard !paths.isEmpty else { return "" }
        return paths.count == 1
            ? ((paths[0] as NSString).lastPathComponent)
            : "\(paths.count) 个项目"
    }
}
