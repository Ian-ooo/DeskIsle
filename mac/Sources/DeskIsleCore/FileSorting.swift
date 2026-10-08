import Foundation

/// 文件夹类分区（portal）条目的排序判据 —— 纯逻辑，三端同源。
///
/// 核心规则：
/// 1. **目录恒置顶**：无论按什么字段/升降序排，目录永远在最前。
/// 2. **严格弱序保证（Strict Weak Ordering）**：
///    `areInIncreasingOrder(a, a)` 恒为 `false`；
///    当主排序列相等时（例如类型排序下所有文件夹的扩展名均为空串、大小排序下所有文件夹大小均为 0），
///    **自动平滑降级到名称次要排序**；
///    降序比较绝不能写成 `!result`（那会让相等元素返回 true，导致 Swift 排序产生未定义行为与反复颠倒）。
public enum FileSorting {

    public static func areInIncreasingOrder(
        aIsDir: Bool, aName: String, aSize: Int64, aModDate: Date, aFileType: String,
        bIsDir: Bool, bName: String, bSize: Int64, bModDate: Date, bFileType: String,
        sortBy: String,
        sortOrder: String
    ) -> Bool {
        // 1. 目录恒置顶
        if aIsDir != bIsDir {
            return aIsDir
        }

        // 2. 主排序列比较
        let primaryComp: ComparisonResult = {
            switch sortBy {
            case "time":
                if aModDate == bModDate { return .orderedSame }
                return aModDate < bModDate ? .orderedAscending : .orderedDescending
            case "size":
                if aSize == bSize { return .orderedSame }
                return aSize < bSize ? .orderedAscending : .orderedDescending
            case "type":
                return aFileType.localizedCaseInsensitiveCompare(bFileType)
            default:
                return aName.localizedCaseInsensitiveCompare(bName)
            }
        }()

        // 3. 次要排序列（主列相同时退回按名称排序，保证严格弱序和稳定性）
        let finalComp = (primaryComp != .orderedSame)
            ? primaryComp
            : aName.localizedCaseInsensitiveCompare(bName)

        // 严格弱序自反性：相等元素必须返回 false
        if finalComp == .orderedSame {
            return false
        }

        return sortOrder == "desc"
            ? (finalComp == .orderedDescending)
            : (finalComp == .orderedAscending)
    }
}
