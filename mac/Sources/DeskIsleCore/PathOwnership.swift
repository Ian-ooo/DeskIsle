import Foundation

/// 把一条**绝对路径**归属到某个分区根目录 —— 纯逻辑。
///
/// ## 为什么需要它
/// `FSEvents` 的流是按目录注册的，但回调只给你一串变更过的绝对路径，
/// 不带「这条流是谁的」。宏观上「一个根目录一条流」，实际却会出现：
/// - 一个分区的根目录是另一个分区根目录的**子目录**（用户完全可能这么映射），
///   此时同一条路径同时落在两个分区里；
/// - 事件路径可能带尾部斜杠，也可能就是根目录本身（根被改名 / 删除）。
///
/// 前缀比较的**边界**是最容易写错的地方：`/a/b` 绝不能认领 `/a/bc/report.txt`
/// （多认领 = 另一个分区被凭空刷新；少认领 = 该刷新的没刷新）。
/// 所以规则写在这里并用测试钉死，而不是散在回调里就地 `hasPrefix`。
public enum PathOwnership {

    /// 归一化：去掉尾部斜杠（根目录 `/` 除外）。
    ///
    /// 不展开 `~`、不做大小写折叠 —— 调用方给的都是配置里的绝对路径，
    /// 而 FSEvents 回报的路径与订阅时给的字符串前缀一致，逐字符比较就是对的。
    public static func normalize(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// `path` 是否落在 `root` 之下（**含 root 自身**）。
    ///
    /// ⚠️ 判据里的 `root + "/"` 是关键：少了它，`/a/b` 会把 `/a/bc` 也算进来。
    public static func contains(root: String, path: String) -> Bool {
        let r = normalize(root)
        let p = normalize(path)
        guard !r.isEmpty, !p.isEmpty else { return false }
        if r == p { return true }
        return p.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }

    /// `path` 的直接父目录（`/a/b` → `/a`）；根目录 / 空串返回空串。
    ///
    /// 用途：判断一次文件事件是否会影响**当前正显示的那个列表** ——
    /// 只有「父目录恰好是正在浏览的目录」的条目增删改才会改变那份列表，
    /// 深层子目录里的动静（例如某个 `build/` 目录在狂写）不该拖着界面刷新。
    public static func parent(of path: String) -> String {
        let p = normalize(path)
        guard p.count > 1 else { return "" }
        let parent = (p as NSString).deletingLastPathComponent
        return parent == "/" ? "/" : normalize(parent)
    }

    /// 这次文件事件是否值得让**正在显示 `shownDirectory` 的那份列表**刷新。
    ///
    /// FSEvents 是按根目录**递归**订阅的：根目录下任何深度的改动都会被送上来。
    /// 不做过滤的话，一个在狂写的深层目录（`build/`、`node_modules/`、
    /// 正在下载的临时目录）会把界面拖着不停重扫 —— 列表本身一个字都不会变。
    ///
    /// 判据只有一条：**事件发生在 `shownDirectory` 自己、或它的某个祖先目录里**。
    /// 换个等价说法：事件所在的那一级目录是 `shownDirectory` 的祖先（或它本身）。
    ///
    /// 为什么是这条：一条事件只说明「某个目录的**条目清单**变了」，它改变的是
    /// **那个目录的父目录**所展示的内容。所以只有当那个父目录正是我们要显示的目录、
    /// 或者是它的祖先（说明要显示的目录本身可能刚被改名 / 删掉）时，才与我们有关。
    ///
    /// ⚠️ 别写成「父目录 == 正在显示的目录」。那样会漏掉**正在浏览的目录被改名**
    /// 这一类：`/root/sub` 被改成 `/root/sub2` 时，事件落在 `/root/sub2`，
    /// 它的父目录是 `/root` 而不是 `/root/sub` —— 漏掉之后视图会一直停在一个
    /// 已经不存在的路径上，而且没有任何人会通知它。
    public static func affectsListing(eventPath: String, shownDirectory: String) -> Bool {
        let shown = normalize(shownDirectory)
        guard !shown.isEmpty else { return false }
        return contains(root: parent(of: eventPath), path: shown)
    }

    /// 在 `roots`（分区 id → 根目录）里找出 `path` 属于哪个分区。
    ///
    /// 多个命中时取**路径最长**的那个（最具体的根赢了）：
    /// 分区 A 映射 `/x`、分区 B 映射 `/x/y`，那么 `/x/y/f.txt` 属于 B。
    /// 返回 nil = 不属于任何分区（配置刚改过、路径已不在映射范围内）。
    public static func owner(of path: String, roots: [String: String]) -> String? {
        var bestID: String?
        var bestLen = -1
        for (id, root) in roots {
            let r = normalize(root)
            guard contains(root: r, path: path) else { continue }
            if r.count > bestLen {
                bestID = id
                bestLen = r.count
            }
        }
        return bestID
    }
}
