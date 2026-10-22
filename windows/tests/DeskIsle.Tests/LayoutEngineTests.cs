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
        [InlineData("top")]
        [InlineData("left")]
        [InlineData("right")]
        public void PlacementsNeverOverlap(string mode)
        {
            // 三种模式都允许出界（竖向超高时会到底），但**绝不能互相压住** ——
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

        /// <summary>
        /// first-fit 必须<b>跳过塞不下的、去捡后面更矮的</b> —— 2026-10-12 修的核心。
        /// <para>
        /// 用户真实配置（675 / 388 / 240，可用高 940）：旧的 next-fit 第一列只有 [675]，
        /// 因为 675+16+388 = 1079 &gt; 940 就立刻换列；first-fit 跳过 388、拉进 240
        /// ⇒ 675+16+240 = 931 ⇒ 第一列 [675,240]、第二列 [388]。这正是用户要的。
        /// </para>
        /// </summary>
        [Fact]
        public void FirstFitColumnGroups_SkipsUnfittingItemsInsteadOfEndingTheColumn()
        {
            double gap = LayoutEngine.Gap;

            var real = LayoutEngine.FirstFitColumnGroups(
                3, gap, i => new[] { 675.0, 388.0, 240.0 }[i], 940);
            Assert.Equal(2, real.Count);
            Assert.Equal(new[] { 0, 2 }, real[0]);   // 675 + 16 + 240 = 931
            Assert.Equal(new[] { 1 }, real[1]);       // 388 自己一列

            // 全都塞得下 ⇒ 只有一列
            var one = LayoutEngine.FirstFitColumnGroups(
                3, gap, i => new[] { 240.0, 388.0, 314.0 }[i], 1000);
            Assert.Single(one);
            Assert.Equal(new[] { 0, 1, 2 }, one[0]);

            // 塞不下就跳过，而不是提前结束这一列
            var skip = LayoutEngine.FirstFitColumnGroups(
                3, gap, i => new[] { 500.0, 400.0, 300.0 }[i], 750);
            Assert.Equal(2, skip.Count);
            Assert.Equal(new[] { 0 }, skip[0]);       // 500+16+400 = 916 > 750
            Assert.Equal(new[] { 1, 2 }, skip[1]);// 400+16+300 = 716 放得下

            Assert.Empty(LayoutEngine.FirstFitColumnGroups(0, gap, _ => 100, 940));
        }

        /// <summary>
        /// 单条本身超高时它自己独占一列；而它<b>两侧</b>的矮分区仍能被收进同一列
        /// （中间那条超高不会把两侧拆散）—— 这正是 first-fit 优于 next-fit 的价值。
        /// </summary>
        [Fact]
        public void FirstFitColumnGroups_OversizedItemGetsItsOwnColumn()
        {
            double gap = LayoutEngine.Gap;
            var two = LayoutEngine.FirstFitColumnGroups(
                2, gap, i => new[] { 900.0, 200.0 }[i], 600);
            Assert.Equal(2, two.Count);
            Assert.Equal(new[] { 0 }, two[0]);
            Assert.Equal(new[] { 1 }, two[1]);

            var twoTall = LayoutEngine.FirstFitColumnGroups(
                2, gap, i => new[] { 900.0, 800.0 }[i], 600);
            Assert.Equal(2, twoTall.Count);
            Assert.Equal(new[] { 0 }, twoTall[0]);
            Assert.Equal(new[] { 1 }, twoTall[1]);

            // 超高条在中间：前后两条 200 收进同一列（200+16+200 = 416 ≤ 600）
            var mid = LayoutEngine.FirstFitColumnGroups(
                3, gap, i => new[] { 200.0, 900.0, 200.0 }[i], 600);
            Assert.Equal(2, mid.Count);
            Assert.Equal(new[] { 0, 2 }, mid[0]);
            Assert.Equal(new[] { 1 }, mid[1]);
        }

        /// <summary>
        /// 端到端：left / right 拿到的分组完全一致 ⇒ 结果互为严格几何镜像。
        /// </summary>
        [Fact]
        public void LeftAndRight_ShareOneGrouping_EvenWithFirstFit()
        {
            // 12 条参差不齐、可用高 910（screenH 1050 − top 76 − bottom 40）
            double[] hs = { 500, 200, 300, 200, 400, 250, 180, 320, 210, 260, 190, 240 };
            var ps = hs.Select((h, i) => new PartitionModel
            {
                Id = $"p{i:00}", X = 16, Y = 100, Width = 316, Height = h, IsCollapsed = false
            }).ToList();

            var left = LayoutEngine.CalculateLayout("left", ps, 1680, 1050, 76, 40, 5);
            var right = LayoutEngine.CalculateLayout("right", ps, 1680, 1050, 76, 40, 5);

            foreach (var p in ps)
                Assert.Equal(1680, left[p.Id].X + p.Width + right[p.Id].X, 6);

            // 每列都不超出可用高，且 Y 在两向完全相同（同一分组的直接后果）
            const double availH = 1050 - 76 - 40;
            foreach (var g in left.GroupBy(kv => kv.Value.X))
            {
                double colH = g.Sum(kv => hs[int.Parse(kv.Key.Substring(1))])
                              + (g.Count() - 1) * LayoutEngine.Gap;
                Assert.True(colH <= availH + 0.001, $"列高 {colH} 超出可用高 {availH}");
            }
            foreach (var p in ps)
                Assert.Equal(left[p.Id].Y, right[p.Id].Y, 6);
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

        // ── 模式归一化（老配置里的 grid 必须回退 top）──────────────────────────

        /// <summary>
        /// <c>grid</c> 已下线，但老配置里仍存着它。归一化必须把它翻成 <c>top</c>，
        /// 否则它会掉进非 top 的读序分支，与 Swift / Python 结果不一致、重排后位置漂移。
        /// 本测试与 <c>mac/Tests/.../LayoutEngineTests.swift</c> 的同名用例一一对应。
        /// </summary>
        [Theory]
        [InlineData("grid", "top")]
        [InlineData("", "top")]
        [InlineData("nonsense", "top")]
        [InlineData("top", "top")]
        [InlineData("left", "left")]
        [InlineData("right", "right")]
        [InlineData("LEFT", "left")]
        [InlineData("Right", "right")]
        public void NormalizeAlignMode_FallsBackToTop(string input, string expected)
        {
            Assert.Equal(expected, LayoutEngine.NormalizeAlignMode(input));
        }

        /// <summary>
        /// 端到端兜底：传 "grid" 给 CalculateLayout，结果必须与传 "top" **逐个坐标相同**。
        /// 只测归一化函数不够 —— 真正要守的是「入口有没有调用它」。
        /// </summary>
        [Fact]
        public void CalculateLayout_GridMode_ProducesIdenticalLayoutToTop()
        {
            double[] heights = { 670, 388, 314, 500, 220 };
            List<PartitionModel> Make()
            {
                var list = new List<PartitionModel>();
                for (int i = 0; i < heights.Length; i++)
                {
                    list.Add(new PartitionModel
                    {
                        Id = "p" + i,
                        X = 0,
                        Y = 0,
                        Width = 364,
                        Height = heights[i],
                        IsCollapsed = false,
                    });
                }
                return list;
            }

            var byGrid = LayoutEngine.CalculateLayout("grid", Make(), 1920, 1080, 100, 40, 5, "leftToRight");
            var byTop = LayoutEngine.CalculateLayout("top", Make(), 1920, 1080, 100, 40, 5, "leftToRight");

            Assert.Equal(byTop.Count, byGrid.Count);
            Assert.NotEmpty(byGrid);
            foreach (var kv in byTop)
            {
                Assert.True(byGrid.ContainsKey(kv.Key), $"grid 回退后缺分区 {kv.Key}");
                Assert.Equal(kv.Value.X, byGrid[kv.Key].X, 6);
                Assert.Equal(kv.Value.Y, byGrid[kv.Key].Y, 6);
            }
        }

        /// <summary>
        /// 贴底的最后一个分区不能为了底部边距被上移、从而挤掉与上一个分区的间距。
        /// 与 mac <c>testBottomClampKeepsGapWithPartitionAbove</c> 同一组数字。
        /// </summary>
        [Fact]
        public void PositionKeepingGap_BottomClamp_KeepsGapWithPartitionAbove()
        {
            var above = new List<(double X, double Y, double W, double H)>
            {
                (348, 430, 316, 314),
            };
            var aligned = LayoutEngine.PositionKeepingGap(348, 760, 316, 200, 1512, 965, 100, above);
            Assert.Equal(760, aligned.Y, 3);

            var repaired = LayoutEngine.PositionKeepingGap(348, 749, 316, 200, 1512, 965, 100, above);
            Assert.Equal(760, repaired.Y, 3);
        }

        [Fact]
        public void PositionKeepingGap_LoneWindow_StillPulledOnScreen()
        {
            var r = LayoutEngine.PositionKeepingGap(
                16, 900, 316, 200, 1512, 965, 100,
                new List<(double X, double Y, double W, double H)>());
            Assert.Equal(965 - 200 - 16, r.Y, 3);
        }

        [Fact]
        public void PositionKeepingGap_FlushStackAwayFromBottom_IsLeftAlone()
        {
            var above = new List<(double X, double Y, double W, double H)>
            {
                (348, 100, 316, 314),
            };
            var r = LayoutEngine.PositionKeepingGap(348, 414, 316, 314, 1512, 965, 100, above);
            Assert.Equal(414, r.Y, 3);
        }

        /// <summary>
        /// 100% 主屏：锚点与像素重合，工作区原样返回。
        /// </summary>
        [Fact]
        public void TryMapRectFromAnchor_IdentityOn100PercentPrimary()
        {
            bool ok = LayoutEngine.TryMapRectFromAnchor(
                16, 76, 316, 200,
                16, 76, 332, 276,
                0, 0, 1920, 1040,
                out double x, out double y, out double w, out double h);
            Assert.True(ok);
            Assert.Equal(0, x, 3);
            Assert.Equal(0, y, 3);
            Assert.Equal(1920, w, 3);
            Assert.Equal(1040, h, 3);
        }

        /// <summary>
        /// 150% 主屏：像素工作区要缩回逻辑尺寸，原点仍在 (0,0)。
        /// </summary>
        [Fact]
        public void TryMapRectFromAnchor_ScalesPrimaryAt150Percent()
        {
            bool ok = LayoutEngine.TryMapRectFromAnchor(
                16, 76, 316, 200,
                24, 114, 498, 414,
                0, 0, 1920, 1560,
                out double x, out double y, out double w, out double h);
            Assert.True(ok);
            Assert.Equal(0, x, 3);
            Assert.Equal(0, y, 3);
            Assert.Equal(1280, w, 3);
            Assert.Equal(1040, h, 3);
        }

        /// <summary>
        /// 副屏 150%、主屏 100%：工作区像素原点是 1920，不能再除以 1.5 变成 1280
        /// （那会整块叠进主屏）。锚点换算后原点停在逻辑坐标 1920。
        /// </summary>
        [Fact]
        public void TryMapRectFromAnchor_DoesNotScaleSecondaryOrigin()
        {
            bool ok = LayoutEngine.TryMapRectFromAnchor(
                1936, 16, 316, 200,
                1944, 24, 2418, 324,
                1920, 0, 3840, 1080,
                out double x, out double y, out double w, out double h);
            Assert.True(ok);
            Assert.Equal(1920, x, 3);
            Assert.Equal(0, y, 3);
            Assert.Equal(1280, w, 3);
            Assert.Equal(720, h, 3);
        }
    }
}
