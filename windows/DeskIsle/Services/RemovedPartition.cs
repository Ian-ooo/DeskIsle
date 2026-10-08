using System;
using System.Collections.Generic;

namespace DeskIsle.Services
{
    /// <summary>
    /// 配置里**已下线分区类型**的处理 —— 纯逻辑，两端同源。
    ///
    /// ## 为什么要有它
    /// 某个分区类型的实现被整体移除之后，配置文件里仍然可能躺着同类型的分区
    /// （用户之前建过、或者从另一端的备份里导进来的）。这些"孤儿分区"在代码里
    /// **已经没有任何视图能渲染它**，于是：
    /// - 视图层落到 default 分支 —— 渲染出一个只有类型名的空壳；
    /// - 设置面板拿不到它的元信息（类型表里已经没有这一项），用户**连删都删不掉**。
    ///
    /// 所以读盘时必须就地剔除，而不是等用户去删。
    ///
    /// ## ⚠️ 入榜即「永久丢弃」
    /// 这里是**丢弃**而不是隐藏：判断失误等于把用户的分区删了。
    /// 因此在把某个类型加进 <see cref="RemovedTypes"/> 之前，必须先确认该类型的实现
    /// **已经在两端全部移除**。
    ///
    /// 已下线记录：2026-10-01 移除「文件收集箱 / collection」。
    ///
    /// 对应实现：mac <c>DeskIsleCore/RemovedPartition.swift</c>、Windows 本文件。
    /// </summary>
    public static class RemovedPartition
    {
        /// <summary>已下线的分区类型。改这里必须两端同步，并用各自的测试钉住。</summary>
        public static readonly HashSet<string> RemovedTypes = new(StringComparer.Ordinal) { "collection" };

        /// <summary>这个类型是否已被下线。</summary>
        public static bool IsRemoved(string? type) =>
            type != null && RemovedTypes.Contains(type);

        /// <summary>
        /// 从一串分区类型里剔除已下线的。
        /// </summary>
        /// <returns>保留下来的类型，**顺序不变**。</returns>
        public static List<string> KeepingSupported(IEnumerable<string> types)
        {
            var kept = new List<string>();
            foreach (var t in types)
            {
                if (!IsRemoved(t)) kept.Add(t);
            }
            return kept;
        }

        /// <summary>
        /// 从分区模型里剔除已下线类型的分区。
        /// </summary>
        /// <param name="partitions">配置里的分区集合（会被**就地读取**，不修改入参）。</param>
        /// <returns><c>kept</c> = 保留项（顺序不变）；<c>dropped</c> = 被剔除的个数。</returns>
        /// <remarks>
        /// **幂等**：没有可剔除项时 <c>dropped == 0</c>，
        /// 调用方据此决定要不要落盘 —— 误报会让每次读盘都重写一次配置。
        /// </remarks>
        public static (List<Models.PartitionModel> kept, int dropped) DroppingRemovedTypes(
            IEnumerable<Models.PartitionModel> partitions)
        {
            var kept = new List<Models.PartitionModel>();
            int total = 0;
            foreach (var p in partitions)
            {
                total++;
                if (!IsRemoved(p.Type)) kept.Add(p);
            }
            return (kept, total - kept.Count);
        }
    }
}
