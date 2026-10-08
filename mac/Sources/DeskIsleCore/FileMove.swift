import Foundation

/// ⭐ 文件「拖入分区」的落点计算 —— 纯逻辑（不碰磁盘），三端同源。
///
/// 为什么单独抽出来：拖放里有三件**极易写错又必须一致**的事，而它们全是字符串运算，
/// 完全可以脱离 UI 与文件系统测试：
///
/// 1. **同名不能覆盖** —— 覆盖不可撤销，多一个「 2」副本用户一眼能看见、随手能删。
/// 2. **不能把文件夹拖进它自己的子孙目录** —— `moveItem` 在部分系统上会静默产出半截结果。
/// 3. **同目录视为 no-op** —— 否则「拖出来又拖回去」会弹「已移入 1 个文件」这种假成功。
///
/// 对应实现：mac `AppDelegate.moveFilesIntoPortal`、
/// Windows `Services/FileMover.cs`、Electron `utils/fileMove.ts`。
public enum FileMove {

    /// 标准化路径：去掉 `.` / `..` / 尾斜杠，私有前缀（`/private/var` ↔ `/var`）还原。
    /// ⚠️ 必须前后都做一次再比较 —— 用户拖进来的路径与配置里的目录**写法可能完全不同**
    /// （一个带尾斜杠、一个走 `/private` 软链），不做归一就会误判成「不同目录」。
    public static func normalize(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        if p.hasSuffix("/") && p != "/" { p = String(p.dropLast()) }
        return p
    }

    /// 源与目标是否同一目录（同目录 = 不用动）。
    public static func isSameDirectory(_ path: String, _ directory: String) -> Bool {
        let src = (normalize(path) as NSString).deletingLastPathComponent
        return src == normalize(directory)
    }

    /// `directory` 是否就是 `path` 本身、或者位于 `path` 内部（拖文件夹进自己的子孙）。
    ///
    /// 末尾补 `/` 再比前缀是必须的：否则 `/a/bc` 会被 `hasPrefix("/a/b")` 误判成子孙。
    public static func isSelfOrDescendant(_ directory: String, of path: String) -> Bool {
        let dir = normalize(directory)
        let src = normalize(path)
        if dir == src { return true }
        return dir.hasPrefix(src + "/")
    }

    /// 这次移动该不该做（false = 静默跳过，不算失败）。
    public static func shouldMove(_ path: String, into directory: String) -> Bool {
        if isSelfOrDescendant(directory, of: path) { return false }
        return !isSameDirectory(path, directory)
    }

    /// 落点：目标目录 + 原文件名；同名则按访达习惯追加「 2」「 3」……
    ///
    /// - Parameters:
    ///   - path: 源文件路径
    ///   - directory: 目标目录
    ///   - exists: 判断某个完整路径是否已存在（由调用方注入，方便测试与跨平台）
    public static func destination(for path: String,
                                   directory: String,
                                   exists: (String) -> Bool) -> String {
        let dir = normalize(directory)
        let name = (path as NSString).lastPathComponent
        let target = (dir as NSString).appendingPathComponent(name)
        if !exists(target) { return target }

        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var i = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            let full = (dir as NSString).appendingPathComponent(candidate)
            if !exists(full) { return full }
            i += 1
        }
    }

    /// 找出「会撞名」的源：须满足 `shouldMove` 为真（同目录 / 拖进自己子孙不算冲突），
    /// 且目标目录里已存在同名的项。
    ///
    /// 同名冲突弹窗靠它触发 —— 命中后由 `moveFilesIntoPortal` / `pasteClipboard` 询问用户
    /// 「保留两者 / 停止 / 替换」。返回的是**源路径**列表，调用方再取 basename 展示。
    public static func conflicts(_ paths: [String], directory: String, exists: (String) -> Bool) -> [String] {
        let dir = normalize(directory)
        return paths.filter { p in
            guard shouldMove(p, into: directory) else { return false }
            let name = (p as NSString).lastPathComponent
            return exists((dir as NSString).appendingPathComponent(name))
        }
    }

    /// 判定目标目录是否不能作为拖拽落点：
    /// 任何一个被拖拽的路径如果就是目标目录本身、或是目标目录的祖先目录，则禁止落入（返回 true）。
    public static func isDropTargetForbidden(targetDirectory: String, draggedPaths: [String]) -> Bool {
        guard !draggedPaths.isEmpty else { return false }
        let normTarget = normalize(targetDirectory)
        for dragged in draggedPaths {
            if isSelfOrDescendant(normTarget, of: dragged) {
                return true
            }
        }
        return false
    }
}
