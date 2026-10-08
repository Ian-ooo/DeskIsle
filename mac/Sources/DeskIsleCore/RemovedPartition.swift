import Foundation

/// 配置里**已下线分区类型**的处理 —— 纯逻辑，两端同源。
///
/// ## 为什么要有它
/// 某个分区类型的实现被整体移除之后，配置文件里仍然可能躺着同类型的分区
/// （用户之前建过、或者从另一端的备份里导进来的）。这些"孤儿分区"在代码里
/// **已经没有任何视图能渲染它**，于是：
/// - 视图层落到 `default` 分支 —— 渲染出一个只有类型名的空壳；
/// - 设置面板拿不到它的元信息（`typeMeta` 里已经没有这一项），
///   用户**连删都删不掉** —— 表现为桌面上多了一个去不掉的方块。
///
/// 所以读盘时必须就地剔除，而不是等用户去删。
///
/// ## ⚠️ 入榜即「永久丢弃」
/// 这里是**丢弃**而不是隐藏：判断失误等于把用户的分区删了（虽然分区数据本身
/// 还能从配置历史快照里捞回来，但用户视角就是没了）。
/// 因此在把某个类型加进 `removedTypes` 之前，必须先确认该类型的实现
/// **已经在两端全部移除**。
///
/// 已下线记录：2026-10-01 移除「文件收集箱 / collection」。
///
/// 对应实现：mac `Config.dropRemovedPartitionTypes()`、Windows `Services/RemovedPartition.cs`。
public enum RemovedPartition {

    /// 已下线的分区类型。改这里必须两端同步，并用各自的测试钉住。
    public static let removedTypes: Set<String> = ["collection"]

    /// 这个类型是否已被下线。
    public static func isRemoved(_ type: String) -> Bool {
        removedTypes.contains(type)
    }

    /// 从分区字典数组里剔除已下线类型的分区。
    ///
    /// - Returns: `kept` = 保留下来的分区（**顺序不变**）；`dropped` = 被剔除的个数。
    ///
    /// **幂等**：没有可剔除项时返回与原值相同的数组、`dropped == 0`，
    /// 调用方据此决定要不要落盘（避免每次读盘都重写一次文件）。
    public static func droppingRemovedTypes(_ partitions: [[String: Any]])
        -> (kept: [[String: Any]], dropped: Int) {
        let kept = partitions.filter { !isRemoved(($0["type"] as? String) ?? "") }
        return (kept, partitions.count - kept.count)
    }

    /// 只过滤一串分区类型（不需要整份字典时用这个）。
    public static func keepingSupported(_ types: [String]) -> [String] {
        types.filter { !isRemoved($0) }
    }
}
