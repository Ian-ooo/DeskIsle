using System.Linq;
using DeskIsle.Services;
using Xunit;

namespace DeskIsle.Tests
{
    /// <summary>
    /// 文件条目「点击 → 选中」的判据。
    ///
    /// ⚠️ 与 mac <c>Tests/DeskIsleCoreTests/FileSelectionTests.swift</c>、
    /// Electron <c>scripts/verify-logic.mts</c> 的场景**逐条对齐** ——
    /// 改任何一条语义，三处断言必须一起改。
    /// </summary>
    public class FileSelectionTests
    {
        private static readonly string[] V = { "/d/a.txt", "/d/b.txt", "/d/c.txt", "/d/d.txt" };

        // ── 单击 / Ctrl 切换 ──────────────────────────────────────

        [Fact]
        public void PlainClick_ReplacesSelection()
        {
            var s = new FileSelection();
            s.Click("/d/a.txt", V);
            s.Click("/d/c.txt", V);
            Assert.Single(s.Selected);
            Assert.Contains("/d/c.txt", s.Selected);
        }

        [Fact]
        public void CtrlClick_Toggles()
        {
            var s = new FileSelection();
            s.Click("/d/a.txt", V);
            s.Click("/d/c.txt", V, ctrl: true);
            Assert.Equal(2, s.Count);
            // 再点一次 = 取消
            s.Click("/d/c.txt", V, ctrl: true);
            Assert.Single(s.Selected);
            Assert.Contains("/d/a.txt", s.Selected);
        }

        // ── Shift 区间 ───────────────────────────────────────────

        [Fact]
        public void Shift_SelectsRange()
        {
            var s = new FileSelection();
            s.Click("/d/b.txt", V);
            s.Click("/d/d.txt", V, shift: true);
            Assert.Equal(3, s.Count);
            Assert.DoesNotContain("/d/a.txt", s.Selected);
        }

        [Fact]
        public void Shift_RangeIsDirectionAgnostic()
        {
            var s = new FileSelection();
            s.Click("/d/d.txt", V);            // 锚点在后面
            s.Click("/d/b.txt", V, shift: true);
            Assert.Equal(3, s.Count);
            // 锚点**不动**：连续 ⇧ 点可以从同一个起点反复调整区间
            s.Click("/d/c.txt", V, shift: true);
            Assert.Equal(2, s.Count);
            Assert.Contains("/d/c.txt", s.Selected);
            Assert.Contains("/d/d.txt", s.Selected);
        }

        [Fact]
        public void Shift_WithoutAnchor_IsPlainClick()
        {
            var s = new FileSelection();
            s.Click("/d/b.txt", V, shift: true);
            Assert.Single(s.Selected);
        }

        [Fact]
        public void Shift_WithDeadAnchor_IsPlainClick()
        {
            var s = new FileSelection();
            s.Click("/d/a.txt", V);
            // 锚点被过滤掉了（搜索框里打字）→ 不能什么都不做，退化为单击
            s.Click("/d/b.txt", new[] { "/d/b.txt" }, shift: true);
            Assert.Single(s.Selected);
            Assert.Contains("/d/b.txt", s.Selected);
        }

        // ── 刷新 / 清空 ──────────────────────────────────────────

        [Fact]
        public void Retain_DropsVanishedPaths()
        {
            var s = new FileSelection();
            s.Click("/d/a.txt", V);
            s.Click("/d/b.txt", V, ctrl: true);
            // b.txt 在别处被删了
            s.Retain(new[] { "/d/a.txt", "/d/c.txt" });
            Assert.Single(s.Selected);
            Assert.Contains("/d/a.txt", s.Selected);
        }

        [Fact]
        public void Retain_KeepsSelectionWhenAlive()
        {
            var s = new FileSelection();
            s.Click("/d/a.txt", V);
            s.Retain(V);
            Assert.Single(s.Selected);
        }

        [Fact]
        public void Clear_DropsEverything()
        {
            var s = new FileSelection();
            s.Click("/d/a.txt", V);
            s.Clear();
            Assert.Empty(s.Selected);
        }
        // ── 选区顺序与右键目标（三端同源，mac / Electron 有同名断言）────────

        [Fact]
        public void OrderedSelectionFollowsDisplayOrder()
        {
            var s = new FileSelection();
            // 故意按「b → a」的点击顺序选中：结果必须按显示顺序输出
            s.Click("/d/b.txt", V);
            s.Click("/d/a.txt", V, ctrl: true);
            Assert.Equal(new[] { "/d/a.txt", "/d/b.txt" }, s.OrderedSelection(V));
        }

        [Fact]
        public void OrderedSelectionDropsFilteredOutItems()
        {
            var s = new FileSelection();
            s.Click("/d/a.txt", V);
            s.Click("/d/c.txt", V, ctrl: true);
            // 模拟搜索过滤：可见列表里只剩 a
            Assert.Equal(new[] { "/d/a.txt" }, s.OrderedSelection(new[] { "/d/a.txt" }));
        }

        [Fact]
        public void MenuTargetsUseWholeSelectionWhenClickingInsideIt()
        {
            var s = new FileSelection();
            s.Click("/d/a.txt", V);
            s.Click("/d/b.txt", V, ctrl: true);
            Assert.Equal(new[] { "/d/a.txt", "/d/b.txt" }, s.MenuTargets("/d/a.txt", V));
        }

        [Fact]
        public void MenuTargetsShrinkToClickedOneWhenClickingOutsideSelection()
        {
            var s = new FileSelection();
            s.Click("/d/a.txt", V);
            // ⚠️ 点在选区外只操作它自己 —— 否则「右键别的文件顺手删一下」会连坐
            Assert.Equal(new[] { "/d/b.txt" }, s.MenuTargets("/d/b.txt", V));
        }

        [Fact]
        public void MenuTargetsFallBackToClickedWhenSelectionIsAllFilteredOut()
        {
            var s = new FileSelection();
            s.Click("/d/c.txt", V);
            // 选区里的 c 已被过滤掉：不能返回空列表（菜单会对着空气操作）
            Assert.Equal(new[] { "/d/c.txt" }, s.MenuTargets("/d/c.txt", new[] { "/d/a.txt" }));
        }

        // ── 选区的作用域（活跃分区变化时是否失效） ─────────────────

        [Fact]
        public void Stays_WhenOwnPartitionBecomesActive()
        {
            // ⚠️ 反向用例同样要钉住：点自己的空白区 / 工具栏也会重发「我活跃」，
            // 若这里也清，选中就根本没法用了。
            Assert.False(FileSelectionScope.ShouldClear("p1", "p1"));
        }

        [Fact]
        public void Clears_WhenAnotherPartitionBecomesActive()
        {
            Assert.True(FileSelectionScope.ShouldClear("p1", "p2"),
                "操作另一个分区 → 本分区的选中必须失效");
        }

        [Fact]
        public void Clears_WhenActiveIsOutsideAnyPartition()
        {
            Assert.True(FileSelectionScope.ShouldClear("p1", null),
                "点到桌面 / 别的应用 → 所有分区的选中都必须失效");
            Assert.True(FileSelectionScope.ShouldClear("p2", null));
        }
    }
}
