import Foundation

/// ⭐ 文件夹类分区（portal）内条目「点击 → 选中」的判据 —— 纯逻辑，两端同源。
///
/// 为什么抽成纯函数：选中看着只是「画个高亮」，但四条边界**很容易写歪且必须三端一致** ——
/// 一旦写歪，用户会遇到「点了没反应」「多选了一堆却只高亮一个」这类极难复述的毛病：
///
/// 1. **⇧ 区间选中锚在「上一次点过的那条」上**，不是「上一次选中的那条」——
///    否则 ⇧ 连点两次会把自己也算进去，区间越缩越小。
/// 2. **锚点失效时 ⇧ 退化为单击**（不能什么都不做）：换目录、锚点被过滤掉都会发生。
/// 3. **⌘ 点是切换**（toggle），不是「加进来」—— 再点一次要能取消。
/// 4. **刷新后只保留还活着的条目**：文件在别处被删掉后，选中集里留着幽灵路径，
///    后续任何「对选中项批量操作」都会打到不存在的路径上。
///
/// 对应实现：mac `PartitionView.PortalView.selection`、Windows `Services/FileSelection.cs`。
public struct FileSelection {

    /// 当前选中的**路径**集合。
    ///
    /// ⚠️ 用路径而不是条目 id：portal 每次扫描都会重新生成 `Entry`（id 是 UUID），
    /// 用 id 的话刷新一下选中就全丢了；路径在同一目录视图里是稳定的。
    public private(set) var selected: Set<String> = []

    /// 区间选中的锚点（上一次点过的那条）。已失效（不在当前列表里）时为 nil。
    public private(set) var anchor: String? = nil

    public init() {}

    /// 是否选中。
    public func isSelected(_ path: String) -> Bool { selected.contains(path) }

    /// 清空选中（点内容区空白处 / 切换目录）。
    public mutating func clear() {
        selected.removeAll()
        anchor = nil
    }

    /// 只保留仍然存在的条目（扫描回来 / 目录刷新后调用）。
    ///
    /// ⚠️ 传**未过滤**的完整列表：搜索框里打字的瞬间，被过滤掉的文件不该被取消选中，
    /// 否则一退格选区就空了。
    public mutating func retain(alive paths: Set<String>) {
        selected = selected.intersection(paths)
        if let a = anchor, !paths.contains(a) { anchor = nil }
    }

    /// 点击某一条。
    ///
    /// - Parameters:
    ///   - path: 被点的条目。
    ///   - visible: 当前**可见且有序**的路径列表（过滤 + 排序之后）；
    ///     ⇧ 区间就是按这个顺序取的 —— 传错顺序（比如未排序的目录列举结果）会得到反的区间。
    ///   - command: 是否按住 ⌘/Ctrl（切换选中）。
    ///   - shift: 是否按住 ⇧（区间选中）。
    public mutating func click(
        _ path: String,
        visible: [String],
        command: Bool = false,
        shift: Bool = false
    ) {
        // ⇧ 区间：锚点必须**还在这个列表里且指向某一条**，否则退化为单击。
        if shift, let a = anchor,
           let ai = visible.firstIndex(of: a),
           let ci = visible.firstIndex(of: path) {
            let lo = min(ai, ci), hi = max(ai, ci)
            selected = Set(visible[lo...hi])
            // 锚点不动：连续 ⇧ 点可以从同一个起点反复调整区间
            return
        }

        if command {
            if selected.contains(path) { selected.remove(path) } else { selected.insert(path) }
            anchor = path
            return
        }

        selected = [path]
        anchor = path
    }

    // MARK: - 选区顺序与右键目标（三端同源）

    /// 把选区按**当前显示顺序**重排。
    ///
    /// `selected` 是 `Set`，遍历顺序随缘 —— 批量操作的先后、提示里列出的文件名
    /// 不能跟着集合的内部顺序乱跳，一律按显示顺序归一。
    public func orderedSelection(visible: [String]) -> [String] {
        visible.filter { selected.contains($0) }
    }

    /// **右键菜单的作用目标** —— 对齐访达：点在已选中的条目上时菜单作用于**整个选区**，
    /// 否则只作用于右键戳到的那一个。
    ///
    /// ⚠️ 后者不能省：「右键别的文件顺手删一下」不该连坐一堆不相干的东西。
    public func menuTargets(clicked: String, visible: [String]) -> [String] {
        guard selected.contains(clicked) else { return [clicked] }
        let ordered = orderedSelection(visible: visible)
        // 极端情况（选区里的东西全被过滤掉了）：退回只操作点到的那一个，不要返回空。
        return ordered.isEmpty ? [clicked] : ordered
    }
}

// MARK: - 选区的作用域

/// 「活跃分区变了」时，某个分区的选区该不该失效 —— 纯逻辑，两端同源。
///
/// 为什么需要它：选区是每个分区**各自**存的一份状态，天然不会互相看见。
/// 于是用户在一个分区里选中几个文件、转头去操作另一个分区（或点到桌面 / 别的应用）时，
/// 原来那个分区的高亮**还亮着** —— 等他再回来随手一拖，拖走的就是那几个早就忘了的选中项，
/// 而他自己以为只拖了鼠标底下那一个。（2026-10-01 事故：想拖一张 png，结果连另一个分区的
/// 图一起被搬去了桌面。）
///
/// ⚠️ 判据就是「活跃分区是不是自己」，两种失效来源：
/// 1. `activeID == nil` —— 点到**分区之外**（桌面 / 其它应用 / 应用退活）：**所有**分区的选区失效；
/// 2. `activeID != ownID` —— 操作了**另一个**分区：只有别人失效。
///
/// 反过来，`activeID == ownID` 时必须保留 —— 点自己的空白区、点自己的滚动条、
/// 点自己的工具栏都会重发一次「我活跃」，若这里也清，选中就没法用了。
public enum FileSelectionScope {

    /// - Parameters:
    ///   - ownID: 本分区 id。
    ///   - activeID: 当前活跃分区 id；`nil` = 活跃的不在任何一个分区里（点到分区外了）。
    public static func shouldClear(ownID: String, activeID: String?) -> Bool {
        guard let activeID else { return true }
        return activeID != ownID
    }
}
