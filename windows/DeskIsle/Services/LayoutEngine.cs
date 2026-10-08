using System;
using System.Collections.Generic;
using System.Linq;
using DeskIsle.Models;

namespace DeskIsle.Services
{
    /// <summary>
    /// 对齐排版的坐标解算（纯函数，不接触窗口 / 配置）。
    ///
    /// 四种模式：
    /// - <c>grid</c>  —— 网格平铺（**行优先**：先上排、同行左起）
    /// - <c>top</c>   —— 顶部横向排序（**列优先 + 尽量多列**，整体最紧凑）
    /// - <c>left</c>  —— 左侧纵向对齐（**列优先 + 最少列数**，贴左）
    /// - <c>right</c> —— 右侧纵向对齐（同 left 的**严格几何镜像**，贴右）
    ///
    /// ⚠️ **`top` / `left` / `right` 三种列式模式只在「列数怎么定」上分道扬镳**，
    /// 其余（读序、均衡分组、列 X 计算、逐列自上而下摆放）完全共用。
    /// 与 macOS `LayoutEngine` / Electron `layout.ts` 同源，改动务必三端同步。
    /// </summary>
    public static class LayoutEngine
    {
        public const double DefaultPartitionWidth = 280.0;
        public const double Margin = 16.0;
        public const double Gap = 16.0;

        /// <summary>折叠分区在纵向布局里的占位高度（= 标题栏）</summary>
        public const double CollapsedHeight = 44.0;
        /// <summary>高度未知时的兜底值</summary>
        public const double FallbackHeight = 200.0;
        /// <summary>列式布局的最小可用高度</summary>
        public const double MinAvailHeight = 200.0;

        /// <summary>
        /// 列高的**方向** —— 只在 DP 内部做**并列取舍**（极差并列时沿哪个方向摆更好看）。
        ///
        /// ⚠️ 它**不参与「哪一侧最高」的判定**：那件事由「各列按列高降序摆开」
        /// （<see cref="SortColumnsByHeight"/>）**恒等保证**，「顶部横向排序」的方向只决定
        /// 整块贴左还是贴右（<c>fromRight</c>）。历史教训：曾让方向参与分组（两方向各解一次 DP），
        /// 结果两个方向不再是镜像。
        ///
        /// ⚠️⚠️ <c>left</c> / <c>right</c> 必须都用默认的 <see cref="NonIncreasing"/>，
        /// **绝不能给 <c>right</c> 传 <see cref="NonDecreasing"/>**。
        /// 直觉上「right 的列高自左向右看着是递增的，似乎该用 <c>NonDecreasing</c>」—— 但这是错的：
        /// <c>left</c> 与 <c>right</c> 拿到的是**同一条序列**（见 <see cref="CalculateLayout"/> 的读序），
        /// order 一旦不同，同一个 DP 在「极差并列」时就会替两边挑出**不同的分组**，镜像当场失效。
        /// 也就是说：**「right 看起来是递增」是镜像的果，不是该传的方向**。
        /// 与 macOS `LayoutEngine.ColumnHeightOrder` / Electron `ColumnHeightOrder` 同源。
        /// </summary>
        public enum ColumnHeightOrder
        {
            /// <summary>自左向右**非递增**：左侧最高，向右依次递减或相等。对应「从左到右」。</summary>
            NonIncreasing,
            /// <summary>自左向右**非递减**：右侧最高，向左依次递减或相等。对应「从右到左」。</summary>
            NonDecreasing
        }

        /// <summary>
        /// 相邻两列中**逆着方向**的那一段高度差。
        /// 相等时恒为 0 —— 「递减**或相等**」里的「相等」是允许的。
        /// </summary>
        private static double HeightOrderViolation(ColumnHeightOrder order, double prev, double cur)
            => order == ColumnHeightOrder.NonIncreasing ? Math.Max(0, cur - prev) : Math.Max(0, prev - cur);

        /// <summary>
        /// 把 <paramref name="count"/> 个条目切成 <paramref name="columns"/> 个**连续**分组（保序）。
        /// 目标按字典序，三键固定为：
        /// ①「最高列 − 最矮列」最小 → ② 方向违例最小 → ③ 平方和最小。
        /// 即「各列尽量等高」第一位，方向只在**极差并列时**取舍。
        ///
        /// ⚠️ **没有「违例优先」这一档，是有意为之**：曾有一档把方向违例提到第一键，
        /// 但它需要**两个方向各解一次 DP**，于是同一批分区被切成两套不同的分组 ——
        /// 两个方向**不再互为镜像**，而镜像正是用户明确要求保住的。
        /// 「该侧最高、向另一侧递减或相等」现在由**落位时按列高降序摆开**恒等保证
        /// （见 <see cref="SortColumnsByHeight"/>），不需要方向参与分组。
        ///
        /// **为什么用 DP 而不是贪心**：贪心（「累计超过可用高度就换列」）在单条高度
        /// 远大于均值时会**过早换列**，把余量丢给后面的列。实测 10 条等高分区、可用高 950：
        /// 贪心给出 912 / 216（极差 696），DP 给出 564 / 564（极差 0）。
        ///
        /// **状态为什么带上「本组起点」**：违例与极差都要知道**上一列**的高度，
        /// 而上一列的高度由它的起止下标决定，塞不进 `(列数, 已用条数)` 这个二元状态。
        /// 于是状态取 `(列数, 本组起点, 本组终点)`，代价 O(k·n³) ——
        /// 分区数是几十的量级、只在点击对齐时跑一次，可忽略。
        ///
        /// ⚠️ 分组**保序**是有意为之：<c>left</c> / <c>right</c> 的调用方按「列优先读序」传入、
        /// 重排后按同样读序取回还是同一个序列，因此连续点击同一模式不会窜位；
        /// <c>top</c> 的列会按高矮排开，所以它改从**配置顺序**（与布局无关）取序列。
        /// 与 macOS `LayoutEngine.balancedColumnRanges` / Electron `balancedColumnRanges` 同源。
        /// </summary>
        /// <param name="maxGroupHeight">单列高度上限（<see cref="double.PositiveInfinity"/> = 不限）。
        /// 单条本身就超高时放行，否则会有分区永远排不进去。</param>
        /// <param name="order">列高沿读序应当满足的单调方向 —— 只在极差并列时取舍。</param>
        public static List<(int Start, int End)> BalancedColumnRanges(
            int count,
            int columns,
            double gap,
            Func<int, double> heightAt,
            double maxGroupHeight = double.PositiveInfinity,
            ColumnHeightOrder order = ColumnHeightOrder.NonIncreasing)
        {
            var ranges = new List<(int Start, int End)>();
            if (count <= 0) return ranges;

            int k = Math.Max(1, Math.Min(columns, count));
            if (k == 1) { ranges.Add((0, count)); return ranges; }
            if (k == count)
            {
                for (int i = 0; i < count; i++) ranges.Add((i, i + 1));
                return ranges;
            }

            // 前缀和：分组 [i, j) 的高度 = Σh + (条数 − 1) × gap
            var prefix = new double[count + 1];
            for (int i = 0; i < count; i++) prefix[i + 1] = prefix[i] + heightAt(i);

            double GroupHeight(int i, int j) => prefix[j] - prefix[i] + (j - i - 1) * gap;
            bool Feasible(int i, int j) => j - i == 1 || GroupHeight(i, j) <= maxGroupHeight + 1e-9;

            const double INF = double.PositiveInfinity;
            int side = count + 2;
            int Slot(int c, int s, int e) => (c * side + s) * side + e;
            int slots = (k + 2) * side * side;

            // 每个槽位保存：(最高列, 最矮列, 违例量, 平方和) + 上一组起点
            var bestMax = new double[slots];
            var bestMin = new double[slots];
            var bestViol = new double[slots];
            var bestSq = new double[slots];
            var prevStart = new int[slots];
            for (int i = 0; i < slots; i++)
            {
                bestMax[i] = INF;
                bestMin[i] = INF;
                bestViol[i] = INF;
                bestSq[i] = INF;
                prevStart[i] = -1;
            }

            // 三键固定为（极差, 方向违例, 平方和）；比较一律走 ValueTuple.CompareTo 的字典序
            // （与 macOS 的元组 `<` / Electron 的严格三键比较完全一致）。
            (double, double, double) Key(double maxH, double minH, double viol, double sq)
                => (maxH - minH, viol, sq);

            // 1 组：整段 [0, e)
            for (int e = 1; e <= count; e++)
            {
                if (!Feasible(0, e)) continue;
                double g = GroupHeight(0, e);
                int sl = Slot(1, 0, e);
                bestMax[sl] = g;
                bestMin[sl] = g;
                bestViol[sl] = 0;
                bestSq[sl] = g * g;
                prevStart[sl] = -1;
            }

            if (k > 1)
            {
                for (int c = 2; c <= k; c++)
                {
                    for (int s = c - 1; s < count; s++)
                    {
                        // 后面还要放 k − c 组，本组终点有上限
                        int lastEnd = count - (k - c);
                        if (s + 1 > lastEnd) continue;

                        for (int e = s + 1; e <= lastEnd; e++)
                        {
                            if (!Feasible(s, e)) continue;
                            double g = GroupHeight(s, e);

                            int chosen = -1;
                            (double, double, double) key = (INF, INF, INF);
                            for (int ps = c - 2; ps < s; ps++)
                            {
                                int prev = Slot(c - 1, ps, s);
                                if (double.IsPositiveInfinity(bestMax[prev])) continue;

                                double viol = bestViol[prev]
                                    + HeightOrderViolation(order, GroupHeight(ps, s), g);
                                var cand = Key(
                                    Math.Max(bestMax[prev], g),
                                    Math.Min(bestMin[prev], g),
                                    viol,
                                    bestSq[prev] + g * g);
                                if (cand.CompareTo(key) < 0) { key = cand; chosen = ps; }
                            }
                            if (chosen < 0) continue;

                            int prevSl = Slot(c - 1, chosen, s);
                            int sl = Slot(c, s, e);
                            bestMax[sl] = Math.Max(bestMax[prevSl], g);
                            bestMin[sl] = Math.Min(bestMin[prevSl], g);
                            bestViol[sl] = bestViol[prevSl]
                                + HeightOrderViolation(order, GroupHeight(chosen, s), g);
                            bestSq[sl] = bestSq[prevSl] + g * g;
                            prevStart[sl] = chosen;
                        }
                    }
                }
            }

            // 收尾：最后一组覆盖 [s, n)
            int bestStart = -1;
            (double, double, double) bestKey = (INF, INF, INF);
            for (int s = k - 1; s < count; s++)
            {
                int sl = Slot(k, s, count);
                if (double.IsPositiveInfinity(bestMax[sl])) continue;
                var cand = Key(bestMax[sl], bestMin[sl], bestViol[sl], bestSq[sl]);
                if (cand.CompareTo(bestKey) < 0) { bestKey = cand; bestStart = s; }
            }
            if (bestStart < 0) { ranges.Add((0, count)); return ranges; }

            // 回溯出各分组的下标区间
            int end = count;
            int start = bestStart;
            for (int c = k; c >= 1; c--)
            {
                ranges.Add((start, end));
                int ps = prevStart[Slot(c, start, end)];
                end = start;
                start = ps >= 0 ? ps : 0;
            }
            ranges.Reverse();
            return ranges;
        }

        /// <summary>
        /// 「每一列高度都不超过 <paramref name="maxGroupHeight"/>」所需的最少列数。
        ///
        /// 贪心即最优：尽量往当前列塞，塞不下才换列，得到的列数一定最少
        /// （往前面的列多塞只可能减少后续列数）。单条本身超高时它自己独占一列。
        /// </summary>
        /// <summary>
        /// 「逐列填满」的保序分组：与 <see cref="MinimumFeasibleColumnCount"/> 同源同口径，
        /// 但返回<b>每列的范围</b>。
        /// <para>
        /// 贪心即最优：尽量往当前列塞，塞不下才换列，所以<b>除最后一列外，每一列都是
        /// 「再塞一条就会超出 maxGroupHeight」的状态</b> —— 这正是「左侧优先填满」的形式化含义。
        /// 单条本身就超高时它自己独占一列（新一轮的第一条无条件加入，不会被判成超界）。
        /// </para>
        /// <para>
        /// ⚠️ 判断「当前列是否为空」用 <c>i == start</c> 而不是 <c>cur == 0</c>：
        /// 高度为 0 的分区会让 cur 停在 0，后者会把后续多条误判成「仍在第一列」而漏加 gap。
        /// </para>
        /// </summary>
        public static List<(int Start, int End)> GreedyFillColumnRanges(
            int count, double gap, Func<int, double> heightAt, double maxGroupHeight)
        {
            var ranges = new List<(int Start, int End)>();
            if (count <= 0) return ranges;

            int start = 0;
            double cur = 0;
            for (int i = 0; i < count; i++)
            {
                double h = heightAt(i);
                double add = i == start ? h : h + gap;
                if (i > start && cur + add > maxGroupHeight + 1e-9)
                {
                    ranges.Add((start, i));
                    start = i;
                    cur = h;
                }
                else
                {
                    cur += add;
                }
            }
            ranges.Add((start, count));
            return ranges;
        }

        public static int MinimumFeasibleColumnCount(
            int count, double gap, Func<int, double> heightAt, double maxGroupHeight)
        {
            if (count <= 0) return 0;
            int cols = 1;
            double cur = 0;
            for (int i = 0; i < count; i++)
            {
                double h = heightAt(i);
                double add = cur == 0 ? h : h + gap;
                if (cur > 0 && cur + add > maxGroupHeight + 1e-9)
                {
                    cols++;
                    cur = h;
                }
                else
                {
                    cur += add;
                }
            }
            return cols;
        }

        /// <summary>
        /// 将一组分区按高度均衡切分到指定列数（保序、连续分组），使各列累计总高度的极差最小。
        ///
        /// 与旧实现（LPT 降序贪心 + 2-Opt 跨列移动/交换）的区别：那种做法会把条目**跨列重排**，
        /// 结果里「先出现的条目」可能落在任意一列，读回顺序与原序不一致，重复点击会窜位。
        /// 这里改成保序连续分组，重复点击是幂等的。
        /// </summary>
        public static List<List<string>> BalanceColumns(
            List<string> items,
            int numCols,
            double gap,
            Func<string, double> heightProvider,
            double maxGroupHeight = double.PositiveInfinity,
            ColumnHeightOrder order = ColumnHeightOrder.NonIncreasing)
        {
            var ranges = BalancedColumnRanges(
                items.Count, numCols, gap, i => heightProvider(items[i]),
                maxGroupHeight, order);
            return ranges.Select(r => items.GetRange(r.Start, r.End - r.Start)).ToList();
        }

        /// <summary>
        /// 各列高度 = 列内条目高度之和 + 组内间隔（<c>(条数 − 1) × gap</c>）。
        /// 索引与 <paramref name="cols"/> 一一对应。
        /// </summary>
        public static List<double> ColumnHeightsOf(
            List<List<string>> cols,
            Func<string, double> heightProvider,
            double gap)
            => cols.Select(col => col.Sum(heightProvider) + Math.Max(0, col.Count - 1) * gap).ToList();

        /// <summary>
        /// 把各列**按列高降序**排开（并列保持原顺序 —— 显式带上原下标比较，不依赖排序是否稳定）。
        ///
        /// 「顶部横向排序」用它保证「该侧最高，向另一侧依次递减或相等」**恒成立**：
        /// 保序分组得到的列高沿读序并不单调（真实配置 7 分区 / 5 列实测
        /// 316 / 316 / 480 / 428 / 610，第 3、4 列**上凸**），按高矮排开后就是严格阶梯
        /// 610 / 480 / 428 / 316 / 316。
        ///
        /// ⚠️ 为什么不用「让方向参与分组」代替：试过 —— 两个方向各解一次 DP，结果同一批分区
        /// 被切成两套不同的分组，**两个方向不再互为镜像**，而镜像正是用户明确要求保住的。
        ///
        /// ⚠️⚠️ 排开之后**列序不再等于读序**，因此 <c>top</c> 的读序必须改取**配置顺序**。
        /// 否则「排完 → 按贴边读回 → 再分组」读到的已是另一条序列，分组随之漂移，连点会越排越歪。
        /// 与 macOS `LayoutEngine.columnHeights` / Electron `columnHeightsOf` 同源。
        /// </summary>
        public static List<List<string>> SortColumnsByHeight(
            List<List<string>> cols,
            Func<string, double> heightProvider,
            double gap)
        {
            var heights = ColumnHeightsOf(cols, heightProvider, gap);
            return cols
                .Select((col, i) => (col, h: heights[i], i))
                .OrderByDescending(x => x.h)
                .ThenBy(x => x.i)
                .Select(x => x.col)
                .ToList();
        }

        /// <summary>
        /// 列数策略 —— 三种「列式」对齐模式共用同一段排布，只在列数上分道扬镳。
        /// </summary>
        private enum ColumnCountMode
        {
            /// <summary>尽量多列：列数取上限，再用可用宽度夹一次。「顶部横向排序」用 —— 整体最紧凑、最矮。</summary>
            AtMost,
            /// <summary>最少列数：刚好做到「每一列高度都不超过可用高度」。「左侧 / 右侧对齐」用 —— 几条纵向长列。</summary>
            MinimumFeasible
        }

        /// <summary>
        /// 顶部对齐的**列式排布** —— <c>top</c> / <c>left</c> / <c>right</c> 三种模式共用这一段。
        ///
        /// ⚠️ <c>left</c> / <c>right</c> 必须按**列优先读序**传入 <paramref name="sortedIds"/>
        /// （先一列自上而下、再下一列），而且两者必须拿到**同一条序列** —— 这是「互为镜像」的前提：
        /// 分组只取决于序列；序列相同 ⇒ 分组相同 ⇒ <paramref name="fromRight"/> 的结果就是
        /// <c>false</c> 的**严格几何镜像**（列宽不相等时也成立，因为列坐标本身就是镜像算出来的）。
        ///
        /// 分组用**保序连续分组 DP**，目标键固定为「极差 → 方向违例 → 平方和」。
        ///
        /// ⚠️ **方向（<see cref="ColumnHeightOrder"/>）绝不在这里参与分组**：读序由「当前布局贴
        /// 哪一边」推出、而 <paramref name="fromRight"/> 同时决定「第一组放哪边」，一旦方向也参与
        /// 分组，两个方向就不再互为镜像、来回切还会互相污染。
        /// </summary>
        /// <param name="fromRight">true 时整块贴右边，且**第一组放在最右**。</param>
        /// <param name="sortColumnsByHeight"><c>top</c> 传 true：落位前把各列按列高降序摆开。
        /// 打开后**列序不再等于读序**，调用方必须传入与布局无关的稳定序列（配置顺序）。</param>
        private static Dictionary<string, (double X, double Y)> ColumnPlacements(
            List<string> sortedIds,
            Dictionary<string, PartitionModel> partMap,
            Func<PartitionModel, double> getEffH,
            Func<PartitionModel, double> getW,
            double screenWidth,
            double availH,
            double availW,
            double topMargin,
            bool fromRight,
            ColumnCountMode countMode,
            int maxColumns,
            bool sortColumnsByHeight = false)
        {
            var result = new Dictionary<string, (double X, double Y)>();
            if (sortedIds.Count == 0) return result;

            double HeightAt(int i) => getEffH(partMap[sortedIds[i]]);
            double WidthAt(int i) => getW(partMap[sortedIds[i]]);

            // 1. 定列数，并按该列数做一次保序均衡分组
            List<(int Start, int End)> ranges = new();
            if (countMode == ColumnCountMode.AtMost)
            {
                // ⚠️ **「尽量多列」与「每列不超出屏幕」的对策方向是相反的**：
                // 列越多每列越矮 —— 所以高度超了要**加**列，宽度超了才减列。
                // 于是先把目标列数用「每列都不超过 availH 所需的最少列数」顶上去，
                // 再按宽度逐级往下减，但**不减到该下界以下**（否则刚压下去的高度又会冒出来）；
                // 若减到下界仍超宽，就接受横向溢出 —— 宁可横向出界，也不让内容堆到屏幕底部外。
                // 单条分区本身就有 availH 那么高时 DP 会放行（`End - Start == 1` 恒可行），
                // 这是「无论如何都排得进去」的兜底。
                int targetCols = Math.Max(1, Math.Min(sortedIds.Count, Math.Max(1, maxColumns)));
                int minCols = MinimumFeasibleColumnCount(
                    sortedIds.Count, Gap, HeightAt, availH);
                int numCols = Math.Min(sortedIds.Count, Math.Max(targetCols, minCols));
                while (true)
                {
                    var candidate = BalancedColumnRanges(
                        sortedIds.Count, numCols, Gap, HeightAt, maxGroupHeight: availH);
                    // ⚠️ 必须用**实际分组结果**逐级验证总宽：均衡分组打乱了「哪些分区同列」，
                    // `idx % numCols` 那类估算不再成立。
                    double totalW = candidate.Sum(r =>
                    {
                        double m = 0;
                        for (int i = r.Start; i < r.End; i++) m = Math.Max(m, WidthAt(i));
                        return (m > 0 ? m : DefaultPartitionWidth) + Gap;
                    }) - Gap;
                    ranges = candidate;
                    if (totalW <= availW || numCols <= minCols) break;
                    numCols--;
                }
            }
            else
            {
                // 「左侧 / 右侧纵向对齐」= **逐列填满**：先把最靠边的那一列自上而下塞满，
                // 塞不下才往内开新列。方向由 PlaceColumns 的 fromRight 决定 ⇒ 两向严格镜像。
                //
                // ⚠️ 这里刻意**不用** BalancedColumnRanges：那套保序 DP 的目标是
                // 「各列尽量等高」，为了压极差会把本该留在第一列的分区挪到后面去 ——
                // 真实配置实测（3 个分区 428 / 316 / 314，可用高 1060）：
                // 第一列本可装 2 个（428+16+316 = 760），但均衡分组为了把极差从 446 压到 218，
                // 把第一列拆得只剩 1 个 ⇒ 用户看到「没有优先填充完最左侧的列」。
                //
                // ⚠️ 「填满优先」与「等高优先」不可兼得：代价是最后一列可能明显偏短。
                // 2026-09-30 用户明确选择前者（2026-09-28 曾一度反向选择过后者）。
                ranges = GreedyFillColumnRanges(
                    sortedIds.Count, Gap, HeightAt, maxGroupHeight: availH);
            }

            // 1.5 「顶部横向排序」：把各列**按列高降序**摆开
            //
            // 这是让「该侧最高，向另一侧依次递减或相等」**恒成立**的唯一办法：
            // 保序分组得到的列高沿读序并不单调 —— 真实配置实测（7 分区 / 5 列）
            // 各列是 316 / 316 / 480 / 428 / 610，第 3、4 列是**上凸**的（480 排在 428 左边）。
            // 按高矮排开后就是严格阶梯 610 / 480 / 428 / 316 / 316。
            if (sortColumnsByHeight)
            {
                var grouped = ranges
                    .Select(r => Enumerable.Range(r.Start, r.End - r.Start).Select(i => sortedIds[i]).ToList())
                    .ToList();
                var sortedCols = SortColumnsByHeight(grouped, id => getEffH(partMap[id]), Gap);
                // 重新编号回下标区间，后续列 X / 列内 Y 的解算只认 ranges
                var flat = sortedCols.SelectMany(c => c).ToList();
                var newRanges = new List<(int Start, int End)>();
                int cursor = 0;
                foreach (var c in sortedCols)
                {
                    newRanges.Add((cursor, cursor + c.Count));
                    cursor += c.Count;
                }
                // 按新列序重排 sortedIds 的副本，使下标区间继续指向正确的分区
                sortedIds = flat;
                ranges = newRanges;
            }

            // 2. 列 X：取该列最宽的分区，保证同列边缘严格对齐
            var colWidths = ranges.Select(r =>
            {
                double m = 0;
                for (int i = r.Start; i < r.End; i++) m = Math.Max(m, WidthAt(i));
                return m > 0 ? m : DefaultPartitionWidth;
            }).ToList();

            var colX = new double[ranges.Count];
            if (fromRight)
            {
                colX[0] = (screenWidth - Margin) - colWidths[0];
                for (int c = 1; c < ranges.Count; c++) colX[c] = colX[c - 1] - Gap - colWidths[c];
            }
            else
            {
                colX[0] = Margin;
                for (int c = 1; c < ranges.Count; c++) colX[c] = colX[c - 1] + colWidths[c - 1] + Gap;
            }

            // 3. 逐列自上而下摆放，每列都从 topMargin 起（顶部对齐）
            for (int c = 0; c < ranges.Count; c++)
            {
                double curY = topMargin;
                for (int i = ranges[c].Start; i < ranges[c].End; i++)
                {
                    string id = sortedIds[i];
                    double w = WidthAt(i);
                    double x = fromRight ? colX[c] + (colWidths[c] - w) : colX[c];
                    result[id] = (x, curY);
                    curY += HeightAt(i) + Gap;
                }
            }
            return result;
        }

        /// <summary>
        /// 计算指定排版模式下的所有分区坐标结果 (x, y)
        /// 不改变分区的宽度和高度！
        /// </summary>
        public static Dictionary<string, (double X, double Y)> CalculateLayout(
            string mode,
            List<PartitionModel> partitions,
            double screenWidth,
            double screenHeight,
            double topMargin = 76.0,
            double bottomMargin = 32.0,
            int maxColumns = 6,
            string topHeightOrder = "leftToRight")
        {
            var result = new Dictionary<string, (double X, double Y)>();
            if (partitions.Count == 0) return result;

            double availW = screenWidth - 2 * Margin;
            double availH = Math.Max(MinAvailHeight, screenHeight - topMargin - bottomMargin);

            double GetEffH(PartitionModel p) => p.IsCollapsed ? CollapsedHeight : (p.Height > 0 ? p.Height : FallbackHeight);
            double GetW(PartitionModel p) => p.Width > 0 ? p.Width : DefaultPartitionWidth;

            var partMap = partitions.ToDictionary(p => p.Id, p => p);
            string lowerMode = mode.ToLowerInvariant();

            // ── 读序 ────────────────────────────────────────────────────────────
            //
            // ⚠️ `left` / `right`：**读序由「当前布局贴哪一边」决定，与即将点击的模式无关。**
            // 两者必须拿到**同一条序列**，分组才会一致，`fromRight` 的结果才是 `false` 的
            // **严格几何镜像**；同时这也是幂等的前提（从「贴边那一侧」读回的序列正是上次排布
            // 用过的序列）。
            //
            // 旧实现：`right` 固定按「从右往左」读 → 等于把序列反过来重新分组 →
            // 切出的列不是同一组（实测 7 分区：left 各列高 814/758/610，right 却成了 316/926/940）。
            //
            // ⚠️⚠️ `top`：它的列是**按列高降序排开**的（见 <see cref="SortColumnsByHeight"/>），
            // 列的左右顺序不再承载读序信息，所以**固定取 partitions 数组顺序**（与布局无关的稳定来源）。
            // 若还从布局几何推读序，读回来的就是「按列高排过序」的另一条序列，再分组必然切出
            // 不同的列，连点会一路漂移。
            List<string> sortedIds;
            bool isColumnMode = lowerMode == "left" || lowerMode == "top" || lowerMode == "right";
            if (isColumnMode)
            {
                if (lowerMode == "top")
                {
                    sortedIds = partitions.Select(p => p.Id).ToList();
                }
                else
                {
                    double minX = partitions.Min(p => p.X);
                    double maxRight = partitions.Max(p => p.X + GetW(p));
                    bool readFromRight = (screenWidth - Margin - maxRight) < (minX - Margin);

                    var indexOf = new Dictionary<string, int>();
                    for (int i = 0; i < partitions.Count; i++) indexOf[partitions[i].Id] = i;

                    var sorted = new List<PartitionModel>(partitions);
                    sorted.Sort((p1, p2) =>
                    {
                        if (Math.Abs(p1.X - p2.X) > 60)
                            return readFromRight ? (p1.X > p2.X ? -1 : 1) : (p1.X < p2.X ? -1 : 1);
                        if (Math.Abs(p1.Y - p2.Y) > 1)
                            return p1.Y < p2.Y ? -1 : 1;
                        return indexOf[p1.Id].CompareTo(indexOf[p2.Id]);
                    });
                    sortedIds = sorted.Select(p => p.Id).ToList();
                }
            }
            else
            {
                // grid：行优先读序（上排在前，同排左侧在前）
                var indexOf = new Dictionary<string, int>();
                for (int i = 0; i < partitions.Count; i++) indexOf[partitions[i].Id] = i;
                var sorted = new List<PartitionModel>(partitions);
                sorted.Sort((p1, p2) =>
                {
                    if (Math.Abs(p1.Y - p2.Y) > 1)
                        return p1.Y < p2.Y ? -1 : 1;
                    if (Math.Abs(p1.X - p2.X) > 1)
                        return p1.X < p2.X ? -1 : 1;
                    return indexOf[p1.Id].CompareTo(indexOf[p2.Id]);
                });
                sortedIds = sorted.Select(p => p.Id).ToList();
            }

            if (!isColumnMode)
            {
                // ── grid：行优先网格 ──
                // 1. 确定实际横排能够容纳的列数 numCols (1 ~ maxColumns)
                // ⚠️ clamp 到 [4, 6] 必须与 mac `Config.maxColumns` / Electron inline clamp 一致
                int numCols = Math.Max(1, Math.Min(sortedIds.Count, Math.Clamp(maxColumns, 4, 6)));
                while (numCols > 1)
                {
                    double[] maxWInCols = new double[numCols];
                    for (int idx = 0; idx < sortedIds.Count; idx++)
                    {
                        int c = idx % numCols;
                        maxWInCols[c] = Math.Max(maxWInCols[c], GetW(partMap[sortedIds[idx]]));
                    }
                    double totalW = maxWInCols.Sum() + (numCols - 1) * Gap;
                    if (totalW <= availW)
                    {
                        break;
                    }
                    numCols--;
                }

                // 2. 按行（Row-First）进行精准网格分配
                List<List<string>> rows = new();
                List<string> currentRow = new();
                foreach (var id in sortedIds)
                {
                    currentRow.Add(id);
                    if (currentRow.Count == numCols)
                    {
                        rows.Add(currentRow);
                        currentRow = new();
                    }
                }
                if (currentRow.Count > 0)
                {
                    rows.Add(currentRow);
                }

                // 3. 计算各列统一的 X 坐标 (每一列中所有分区 X 坐标严格相同)
                double[] colWidths = new double[numCols];
                for (int c = 0; c < numCols; c++)
                {
                    var colItems = rows.Where(r => c < r.Count).Select(r => r[c]).ToList();
                    colWidths[c] = colItems.Select(id => GetW(partMap[id])).DefaultIfEmpty(DefaultPartitionWidth).Max();
                }
                double[] colX = new double[numCols];
                colX[0] = Margin;
                for (int c = 1; c < numCols; c++)
                {
                    colX[c] = colX[c - 1] + colWidths[c - 1] + Gap;
                }

                // 4. 按排计算统一的 Y 坐标 (同一排内所有分区 Y 坐标严格相同，排间以该排最大高度换行)
                double curY = topMargin;
                foreach (var rowItems in rows)
                {
                    double rowMaxH = rowItems.Select(id => GetEffH(partMap[id])).DefaultIfEmpty(FallbackHeight).Max();
                    for (int c = 0; c < rowItems.Count; c++)
                    {
                        string id = rowItems[c];
                        result[id] = (colX[c], curY);
                    }
                    curY += rowMaxH + Gap;
                }
                return result;
            }

            // ── 列式排布：top / left / right 共用 ──
            //
            // top  ：尽量多列（再用可用宽度逐级夹）——整体最紧凑；落位前各列按列高降序摆开，
            //        方向只决定整块贴左还是贴右；
            // left ：最少列数（每列刚好不超过可用高度），贴左；
            // right：与 left 同分组、同列数，整块贴右 —— **left 的严格几何镜像**。
            bool isTop = lowerMode == "top";
            ColumnCountMode countMode = isTop
                ? ColumnCountMode.AtMost
                : ColumnCountMode.MinimumFeasible;
            // 上限 [4, 6] 与 mac `Config.maxColumns` / Electron inline clamp 保持一致
            int columnLimit = isTop ? Math.Clamp(maxColumns, 4, 6) : maxColumns;

            // ⚠️ 「某侧最高」不再有「无解」：各列已按列高排好，方向只负责挑哪一侧是「高」的那一侧。
            // 两个方向共用同一套分组、只翻 fromRight ⇒ **严格几何镜像**。方向不参与分组。
            bool fromRight = isTop
                ? string.Equals(topHeightOrder, "rightToLeft", StringComparison.OrdinalIgnoreCase)
                : lowerMode == "right";

            var placements = ColumnPlacements(
                sortedIds, partMap, GetEffH, GetW,
                screenWidth, availH, availW, topMargin,
                fromRight, countMode, columnLimit,
                sortColumnsByHeight: isTop);

            foreach (var kv in placements) result[kv.Key] = kv.Value;
            return result;
        }
    }
}
