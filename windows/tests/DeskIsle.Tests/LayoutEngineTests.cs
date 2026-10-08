using System;
using System.Collections.Generic;
using System.Linq;
using DeskIsle.Models;
using DeskIsle.Services;
using Xunit;

namespace DeskIsle.Tests
{
    /// <summary>
    /// 布局引擎回归测试。
    ///
    /// 这些断言钉的是**三端共同的行为契约**（同一份契约也写在 mac 的
    /// <c>DeskIsleLayoutTests</c> 与 Electron 的 <c>verify-logic.mts</c> 里），
    /// 而不是某一端实现细节 —— 改 Windows 侧算法前，先看它是否三端同步改。
    /// </summary>
    public class LayoutEngineTests
    {
        private const double ScreenW = 1728;
        private const double ScreenH = 1117;

        private static List<PartitionModel> Uniform(int n, double w = 280, double h = 200)
            => Enumerable.Range(0, n)
                .Select(i => new PartitionModel { Id = "p" + i, Type = "portal", Width = w, Height = h })
                .ToList();

        private static List<PartitionModel> OfHeights(params double[] hs)
            => hs.Select((h, i) => new PartitionModel { Id = "p" + i, Type = "portal", Width = 280, Height = h })
                 .ToList();

        // ── 通用契约 ────────────────────────────────────────────

        [Theory]
        [InlineData("grid")]
        [InlineData("top")]
        [InlineData("left")]
        [InlineData("right")]
        public void EveryPartitionGetsAPlacement(string mode)
        {
            var ps = Uniform(7);
            var layout = LayoutEngine.CalculateLayout(mode, ps, ScreenW, ScreenH);
            Assert.Equal(ps.Count, layout.Count);
            foreach (var p in ps) Assert.True(layout.ContainsKey(p.Id));
        }

        [Fact]
        public void EmptyInput_ProducesEmptyLayout()
        {
            Assert.Empty(LayoutEngine.CalculateLayout("top", new List<PartitionModel>(), ScreenW, ScreenH));
        }

        [Theory]
        [InlineData("grid")]
        [InlineData("top")]
        [InlineData("left")]
        [InlineData("right")]
        public void PlacementsNeverOverlap(string mode)
        {
            // 四种模式都许 NK 出界（竖向超高时会到底），但**绝不能互相压住** ——
            // 重叠意味着「调皮算错了」，用户会看到两个分区糊在一起。
            var ps = OfHeights(316, 316, 480, 428, 610, 196, 288);
            var layout = LayoutEngine.CalculateLayout(mode, ps, ScreenW, ScreenH);

            for (int i = 0; i < ps.Count; i++)
            {
                for (int j = i + 1; j < ps.Count; j++)
                {
                    var a = ps[i];
                    var b = ps[j];
                    bool overlap =
                        layout[a.Id].X < layout[b.Id].X + b.Width &&
                        layout[b.Id].X < layout[a.Id].X + a.Width &&
                        layout[a.Id].Y < layout[b.Id].Y + b.Height &&
                        layout[b.Id].Y < layout[a.Id].Y + a.Height;
                    Assert.False(overlap, $"{mode}: {a.Id} 与 {b.Id} 位置重叠");
                }
            }
        }

        [Theory]
        [InlineData("grid")]
        [InlineData("top")]
        [InlineData("left")]
        [InlineData("right")]
        public void LayoutIsDeterministic(string mode)
        {
            // 幂等：多调一次不能换出另一套坐标，否则「点两下同一个按钮」会窜位。
            var ps = OfHeights(288, 299, 625, 306, 54, 196);
            var first = LayoutEngine.CalculateLayout(mode, ps, ScreenW, ScreenH);
            var second = LayoutEngine.CalculateLayout(mode, ps, ScreenW, ScreenH);
            foreach (var p in ps)
            {
                Assert.Equal(first[p.Id].X, second[p.Id].X, 6);
                Assert.Equal(first[p.Id].Y, second[p.Id].Y, 6);
            }
        }

        // ── top：横向尽量多列 ───────────────────────────────────

        [Fact]
        public void Top_PutsShortListOnASingleRow()
        {
            var ps = Uniform(3);
            var layout = LayoutEngine.CalculateLayout("top", ps, ScreenW, ScreenH, maxColumns: 5);
            Assert.All(ps, p => Assert.Equal(layout["p0"].Y, layout[p.Id].Y, 6));
        }

        /// <summary>
        /// <c>top</c> 的列数被夹在 **[4, 6]** —— 这条是三端契约，不是 Windows 自己的习惯。
        ///
        /// 起因是历史上一件真事：Windows 原为 [4,8] 默认 6，mac / Electron 是 [4,6] 默认 5，
        /// 于是**同一份配置文件在两个端上算出不同列数**。收敛之后这里必须钉死：
        /// 传 2 会被抬到 4，传 9 会被压回 6。改动前请先三端同步。
        /// </summary>
        [Fact]
        public void Top_ClampsMaxColumnsToFourThroughSix()
        {
            var ps = Uniform(7);

            // 下限：传 2 ⇒ 按 4 处理 ⇒ 第一行正好 4 个
            var low = LayoutEngine.CalculateLayout("top", ps, ScreenW, ScreenH, maxColumns: 2);
            int firstRowLow = ps.Count(p => Math.Abs(low[p.Id].Y - low["p0"].Y) < 1);
            Assert.Equal(4, firstRowLow);

            // 上限：传 9 ⇒ 按 6 处理；宽度装不下时还会继续往下减，所以只断言「不超过 6」
            var high = LayoutEngine.CalculateLayout("top", ps, ScreenW, ScreenH, maxColumns: 9);
            int firstRowHigh = ps.Count(p => Math.Abs(high[p.Id].Y - high["p0"].Y) < 1);
            Assert.True(firstRowHigh <= 6, $"第一行落了 {firstRowHigh} 个，超过列数上限 6");
            Assert.True(firstRowHigh >= 4, $"第一行只有 {firstRowHigh} 个，低于列数下限 4");
        }

        // ── left / right：严格互为镜像 ──────────────────────────

        /// <summary>
        /// 严格镜像 —— 分区 <c>p</c> 在左磁共振到的位置与其在右侧的位置关于屏幕中线对称：
        /// <c>x_left + width + x_right == 屏幕宽</c>。
        ///
        /// 这条银子成立的前提是「两种模式**共用同一套分组**、只翻转落到哪一边」；
        /// 一旦哪天为了「右对齐看起来更自然」给 right 换成另一套读序，这条会当场红。
        /// 这是**有意为之**：牺牲自然感换来的对称性是三端一致的行为。
        /// </summary>
        [Fact]
        public void LeftAndRight_AreStrictMirrors()
        {
            var ps = Uniform(5);
            double width = ps[0].Width;
            var left = LayoutEngine.CalculateLayout("left", ps, ScreenW, ScreenH);
            var right = LayoutEngine.CalculateLayout("right", ps, ScreenW, ScreenH);

            foreach (var p in ps)
            {
                Assert.Equal(ScreenW, left[p.Id].X + width + right[p.Id].X, 6);
            }
        }

        // ── 均衡分组辅助函数 ────────────────────────────────────

        [Fact]
        public void BalancedColumnRanges_CoversEachIndexExactlyOnceAndInOrder()
        {
            var hs = new double[] { 316, 316, 480, 428, 610, 196, 288 };
            var ranges = LayoutEngine.BalancedColumnRanges(hs.Length, 3, LayoutEngine.Gap, i => hs[i]);

            Assert.Equal(3, ranges.Count);
            int cursor = 0;
            foreach (var r in ranges)
            {
                Assert.Equal(cursor, r.Start);   // 连续、保序
                Assert.True(r.End > r.Start);
                cursor = r.End;
            }
            Assert.Equal(hs.Length, cursor);
        }

        [Fact]
        public void BalancedColumnRanges_WithOneColumn_IsEverything()
        {
            var ranges = LayoutEngine.BalancedColumnRanges(4, 1, LayoutEngine.Gap, _ => 100);
            Assert.Single(ranges);
            Assert.Equal((0, 4), ranges[0]);
        }

        [Fact]
        public void MinimumFeasibleColumnCount_GrowsWhenThingsDoNotFit()
        {
            // 全部塞得进一列
            Assert.Equal(1, LayoutEngine.MinimumFeasibleColumnCount(3, LayoutEngine.Gap, _ => 100, 1000));
            // 每条都比可用高度还高 ⇒ 一条一列
            Assert.Equal(3, LayoutEngine.MinimumFeasibleColumnCount(3, LayoutEngine.Gap, _ => 500, 400));
            Assert.Equal(0, LayoutEngine.MinimumFeasibleColumnCount(0, LayoutEngine.Gap, _ => 100, 1000));
        }

        [Fact]
        public void SortColumnsByHeight_PutsTallestColumnFirst()
        {
            var cols = new List<List<string>>
            {
                new List<string> { "c" },   // 100
                new List<string> { "a" },   // 300
                new List<string> { "b" }    // 200
            };
            Func<string, double> heightOf = id => id switch { "a" => 300, "b" => 200, "c" => 100, _ => 0 };

            var sorted = LayoutEngine.SortColumnsByHeight(cols, heightOf, LayoutEngine.Gap);
            var heights = LayoutEngine.ColumnHeightsOf(sorted, heightOf, LayoutEngine.Gap);

            Assert.Equal(new[] { "a", "b", "c" }, sorted.Select(c => c[0]).ToArray());
            for (int i = 1; i < heights.Count; i++)
                Assert.True(heights[i - 1] >= heights[i], $"列高未按降序排开：{string.Join(" / ", heights)}");
        }

        [Fact]
        public void ColumnHeightsOf_AddsGapBetweenItemsOnly()
        {
            // 单列内的间隔是 (项数-1) × gap —— 上下各留一个 gap 是历史上算错的写法
            var cols = new List<List<string>> { new List<string> { "a", "b", "c" } };
            var heights = LayoutEngine.ColumnHeightsOf(cols, _ => 100, LayoutEngine.Gap);
            Assert.Equal(100 * 3 + LayoutEngine.Gap * 2, heights[0], 6);
        }
    }
}
