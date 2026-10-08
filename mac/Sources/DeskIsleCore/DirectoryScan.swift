import Foundation

/// 目录条目的**可见性**与计数口径 —— 纯逻辑，全项目唯一一份。
///
/// ## 为什么必须只有一份
/// 同一个目录的条目数在三个地方被用到：
/// 1. **网格列表本身**（`PortalView.scanDirectory`）—— 用户实际看到的那几行；
/// 2. **标题栏徽标**（`Config.countDirectoryEntries`）—— 压在列表上方的那枚数字；
/// 3. **「自适应宽高」的内容高度**（`AppDelegate.portalEntryCount`）。
///
/// 三处各写一份过滤规则时，只要有一处漏掉隐藏文件过滤，画面上就会出现
/// 「列表里 10 个、标题栏写 11」这种**自相矛盾**的画面 —— 实测真的发生过
/// （`work` 分区：网格 10 项、徽标 11）。
/// 所以判据只留一处，另外三处都从这里取。
///
/// 对应实现：**mac 独占**。Windows 没有标题栏徽标，且它的自适应高度直接取网格
/// 的 `EntryCount`（同一个来源），天生不会出现这种不一致。
public enum DirectoryScan {

    /// 单个条目名是否会被显示出来。
    ///
    /// 判据 = **名字以 `.` 开头就算隐藏**（macOS 约定），与访达在「不显示隐藏文件」
    /// 时的行为一致，也是本应用列表的既有口径。
    ///
    /// ⚠️ 不额外认 `UF_HIDDEN` 标志位：那会让「访达不显示、本应用显示」出现反向不一致，
    /// 而 `.DS_Store` 这类真正想藏起来的东西本来也不带该标志。
    public static func isVisible(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".")
    }

    /// 目录下**会被显示出来**的条目名。
    ///
    /// 目录不存在、没有读权限、或路径为空 → 返回空数组（不抛错：
    /// 调用方全都在视图 / 高度计算的路径上，这里绝不能让异常冒出去）。
    public static func visibleNames(in path: String) -> [String] {
        guard !path.isEmpty else { return [] }
        let all = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return all.filter(isVisible)
    }

    /// 与 `visibleNames` **严格同口径**的计数。
    ///
    /// 之所以单独提供一个，是为了让调用点读起来就是「数一下这个目录有几个可见条目」，
    /// 而不是各自写一遍 `.filter { … }.count` —— 那样又会分叉出第二份判据。
    public static func visibleCount(in path: String) -> Int {
        visibleNames(in: path).count
    }
}
