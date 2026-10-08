using DeskIsle.Services;
using Xunit;

namespace DeskIsle.Tests
{
    /// <summary>
    /// 「这一次鼠标移动该不该发起拖出」的判据 ——
    /// 与 mac <c>Tests/DeskIsleCoreTests/FileDragLaunchTests.swift</c> <b>逐条对齐</b>。
    /// 改任何一条语义，两处断言必须一起改。
    ///
    /// <para>场景编号即判据顺序，别重排 —— 出问题时按编号就能定位漏了哪一条。</para>
    /// </summary>
    public class FileDragLaunchTests
    {
        private const int WinA = 1001;
        private const int WinB = 1002;

        private static DragLaunchInput Input(
            int eventWindowID,
            int? ownWindowID,
            int downWindowID,
            bool downInsideRow = true,
            bool alreadyBegan = false,
            bool anotherSessionActive = false,
            double dx = 10,
            double dy = 0)
        {
            return new DragLaunchInput
            {
                EventWindowID = eventWindowID,
                OwnWindowID = ownWindowID,
                DownWindowID = downWindowID,
                DownInsideRow = downInsideRow,
                AlreadyBegan = alreadyBegan,
                AnotherSessionActive = anotherSessionActive,
                Dx = dx,
                Dy = dy,
            };
        }

        // ── 0. 正常发起 ────────────────────────────────────────────

        [Fact]
        public void SameWindow_AndEnoughMove_Begins()
        {
            Assert.True(FileDragLaunch.ShouldBegin(Input(WinA, WinA, WinA)));
        }

        [Fact]
        public void DiagonalMove_UsesSquaredDistance()
        {
            // 3²+3²=18 过阈值，但单独看 dx、dy 都只有 3pt —— 必须按**距离**算，不能按分量算
            Assert.True(FileDragLaunch.ShouldBegin(Input(WinA, WinA, WinA, dx: 3, dy: 3)));
        }

        // ── 1. 位移阈值（4pt，手抖不该变拖拽） ──────────────────────

        [Fact]
        public void TinyMove_DoesNotBegin()
        {
            Assert.False(FileDragLaunch.ShouldBegin(Input(WinA, WinA, WinA, dx: 2, dy: 0)));
        }

        [Fact]
        public void ExactlyAtThreshold_DoesNotBegin()
        {
            // 阈值是「严格大于」：恰好等于 4pt 不算拖动
            Assert.False(FileDragLaunch.ShouldBegin(Input(WinA, WinA, WinA, dx: 4, dy: 0)));
        }

        [Fact]
        public void JustOverThreshold_Begins()
        {
            Assert.True(FileDragLaunch.ShouldBegin(Input(WinA, WinA, WinA, dx: 4.001, dy: 0)));
        }

        // ── 2. 窗口（mac 事故的根因，Windows 恒真但照测） ────────────

        [Fact]
        public void EventFromAnotherWindow_NeverBegins()
        {
            // ⚠️ 在 B 窗口按下，A 窗口里同坐标的那一行不许发起 ——
            // 否则用户拖的是 B 的文件，被搬走的却是 A 里恰好同位置的另一个文件。
            Assert.False(FileDragLaunch.ShouldBegin(Input(WinB, WinA, WinB)));
        }

        [Fact]
        public void ViewNotInAnyWindow_NeverBegins()
        {
            Assert.False(FileDragLaunch.ShouldBegin(Input(WinA, null, WinA)));
        }

        [Fact]
        public void DownAndDragInDifferentWindows_DoesNotBegin()
        {
            Assert.False(FileDragLaunch.ShouldBegin(Input(WinA, WinA, WinB)));
        }

        // ── 3. 只有被按住的那一行能发起 ────────────────────────────

        [Fact]
        public void DownOutsideThisRow_DoesNotBegin()
        {
            // Windows 上这条是真的会咬人：按住条目 A 横向划到条目 B，
            // B 也会收到 PreviewMouseMove，不放这条就会把 B 拖出去。
            Assert.False(FileDragLaunch.ShouldBegin(Input(WinA, WinA, WinA, downInsideRow: false)));
        }

        // ── 4. 一次按下只发起一次，全局同时只有一个会话 ──────────────

        [Fact]
        public void AlreadyBegan_DoesNotBeginAgain()
        {
            Assert.False(FileDragLaunch.ShouldBegin(Input(WinA, WinA, WinA, alreadyBegan: true)));
        }

        [Fact]
        public void AnotherSessionActive_DoesNotBegin()
        {
            // 第二把锁：即便窗口判据被改坏，也保证一次拖动只带出一组文件
            Assert.False(FileDragLaunch.ShouldBegin(Input(WinA, WinA, WinA, anotherSessionActive: true)));
        }
    }
}
