using System.Collections.Generic;
using System.Linq;
using DeskIsle.Models;
using DeskIsle.Services;
using Xunit;

namespace DeskIsle.Tests
{
    /// <summary>
    /// 已下线分区类型的剔除判据测试。
    ///
    /// ⚠️ 这批断言是**安全绳**：这里判断失误的代价是「用户的分区被永久丢掉」
    /// （不是「少显示一个」，是配置里真的没了）。所以每条 undo 路径都要有断言。
    ///
    /// 两端同防：mac <c>RemovedPartitionTests</c>。改任何一条语义，**两处必须一起改**。
    /// </summary>
    public class RemovedPartitionTests
    {
        private static PartitionModel Part(string type) => new() { Type = type, Title = "t-" + type };

        // ── 谁被判死 ────────────────────────────────────────────

        [Fact]
        public void CollectionIsRemoved()
        {
            Assert.True(RemovedPartition.IsRemoved("collection"));
        }

        [Fact]
        public void LiveTypesAreKept()
        {
            foreach (string t in new[] { "portal", "notes", "todo" })
            {
                Assert.False(RemovedPartition.IsRemoved(t), $"{t} 仍受支持，不能被剔除");
            }
        }

        /// <summary>
        /// 未知类型**必须保留**：宁可渲染出一个可删除的空壳，也不能偷偷删掉用户的数据。
        /// 这是本文件里最重要的一条。
        /// </summary>
        [Theory]
        [InlineData("smart")]
        [InlineData("")]
        [InlineData("🤷‍♂️")]
        [InlineData(null)]
        public void UnknownTypeIsKept(string? type)
        {
            Assert.False(RemovedPartition.IsRemoved(type));
        }

        // ── 整份剔除 ────────────────────────────────────────────

        [Fact]
        public void DropsOnlyCollection()
        {
            var parts = new List<PartitionModel>
            {
                Part("portal"), Part("collection"), Part("notes"), Part("collection"), Part("todo")
            };
            var r = RemovedPartition.DroppingRemovedTypes(parts);
            Assert.Equal(2, r.dropped);
            Assert.Equal(new[] { "portal", "notes", "todo" },
                         r.kept.Select(p => p.Type).ToArray());   // 保留项维持原顺序
        }

        [Fact]
        public void NothingToDropKeepsEverythingAndReportsZero()
        {
            var parts = new List<PartitionModel> { Part("portal"), Part("notes") };
            var r = RemovedPartition.DroppingRemovedTypes(parts);
            Assert.Equal(0, r.dropped);   // 调用方据此决定要不要落盘 —— 误报会让每次读盘都重写文件
            Assert.Equal(2, r.kept.Count);
        }

        [Fact]
        public void Idempotent()
        {
            var parts = new List<PartitionModel> { Part("portal"), Part("collection"), Part("todo") };
            var once = RemovedPartition.DroppingRemovedTypes(parts);
            var twice = RemovedPartition.DroppingRemovedTypes(once.kept);
            Assert.Equal(0, twice.dropped);   // 再跑一次必须什么都不做
            Assert.Equal(once.kept.Count, twice.kept.Count);
        }

        [Fact]
        public void EmptyInputIsNoOp()
        {
            var r = RemovedPartition.DroppingRemovedTypes(new List<PartitionModel>());
            Assert.Equal(0, r.dropped);
            Assert.Empty(r.kept);
        }

        // ── 只过滤类型串 ────────────────────────────────────────

        [Fact]
        public void KeepingSupportedFiltersOnlyRemoved()
        {
            Assert.Equal(new[] { "portal", "notes" },
                         RemovedPartition.KeepingSupported(new[] { "portal", "collection", "notes" }));
            Assert.Empty(RemovedPartition.KeepingSupported(new[] { "collection" }));
            Assert.Empty(RemovedPartition.KeepingSupported(new string[0]));
        }
    }
}
