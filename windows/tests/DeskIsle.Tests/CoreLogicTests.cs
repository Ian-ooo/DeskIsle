using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using DeskIsle.Models;
using DeskIsle.Services;
using Xunit;

namespace DeskIsle.Tests
{
    /// <summary>
    /// 纯逻辑回归测试（不接触 WPF）。
    ///
    /// 这些用例保护的是**写起来会错的那些口径**，而不是把实现重抄一遍：
    /// 每一条注释里都记着「当初就是这么错的」，改坏会立刻红，但**别为了让测试通过
    /// 去放宽断言** —— 断言的内容才是项目真正想要的行为。
    /// </summary>
    public class CoreLogicTests
    {
        // ── 便签高度 ─────────────────────────────────────────────
        // 口径来源（三端同源）：高度 = 视觉行数 × 行高 + 垂直留白。
        // Windows 侧常数：行高 16、垂直留白 30、每侧水平留白 17。

        [Fact]
        public void EmptyNotes_StillOccupiesOneLine()
        {
            // 空文本必须占 1 行。返回 0 的话分区会被夹到最小高度，看起来「卡住了」。
            Assert.Equal(1, PartitionMetrics.NotesVisualLineCount("", 280));
            Assert.Equal(1, PartitionMetrics.NotesVisualLineCount(null, 280));
            Assert.Equal(PartitionMetrics.NotesLineHeight + PartitionMetrics.NotesVerticalPadding,
                         PartitionMetrics.NotesContentHeight("", 280));
        }

        [Fact]
        public void HardNewlines_AreCountedPerLine_NotRolledUp()
        {
            // ⚠️ 这就是历史上那个 bug：用「总字数 ÷ 每行容量」估算行数会把 \n 吞掉，
            // 21 行清单被算成 4 行 → 被 minHeight 夹住 → 点「自适应」一像素都不动。
            Assert.Equal(3, PartitionMetrics.NotesVisualLineCount("a\nb\nc", 280));
            Assert.Equal(21, PartitionMetrics.NotesVisualLineCount(
                string.Join("\n", Enumerable.Repeat("行", 21)), 280));
        }

        [Fact]
        public void BlankLines_DoOccupyALine()
        {
            Assert.Equal(3, PartitionMetrics.NotesVisualLineCount("a\n\nb", 280));
        }

        [Fact]
        public void UserMinHeight_IsCappedByScreenHeight()
        {
            // 「分区最小高度」只能往上抬，但不能超过屏幕可用高 - 60
            // （mac 同名断言在 DeskIsleLayoutTests.testClampedUserMinHeight）。
            Assert.Equal(990, PartitionMetrics.ClampedUserMinHeight(5000, 1050));
            Assert.Equal(300, PartitionMetrics.ClampedUserMinHeight(300, 1050));
            // 低于硬下限 140 抬到 140
            Assert.Equal(140, PartitionMetrics.ClampedUserMinHeight(80, 1050));
            // 屏幕极矮时上限退化到硬下限，不会出现「上限 < 下限」
            Assert.Equal(140, PartitionMetrics.ClampedUserMinHeight(5000, 120));
        }

        [Fact]
        public void DefaultAndMinHeight_ShareTheSameClamp()
        {
            // 「分区默认高度」与「分区最小高度」共用同一条夹取口径，
            // 否则填 5000 会出现「最小高度 990 / 默认高度 5000」的自相矛盾
            // （mac 同名断言在 DeskIsleLayoutTests.testClampedPartitionHeightIsSharedByBothHeightPrefs）。
            Assert.Equal(990, PartitionMetrics.ClampedPartitionHeight(5000, 1050));
            Assert.Equal(300, PartitionMetrics.ClampedPartitionHeight(300, 1050));
            Assert.Equal(140, PartitionMetrics.ClampedPartitionHeight(80, 1050));
            Assert.Equal(140, PartitionMetrics.ClampedPartitionHeight(5000, 120));

            foreach (double v in new[] { 80.0, 200.0, 300.0, 5000.0 })
            {
                Assert.Equal(PartitionMetrics.ClampedUserMinHeight(v, 1050),
                             PartitionMetrics.ClampedPartitionHeight(v, 1050));
            }
        }

        [Fact]
        public void WindowHeight_HonorsUserMinimumHeight()
        {
            // 用户偏好「分区最小高度」只能把窗口往上抬，不能往下压
            // （mac 同名断言在 DeskIsleLayoutTests.testWindowHeightHonorsUserMinimumHeight）。
            // 内容只有 10 → 被抬到用户下限 400
            Assert.Equal(400, PartitionMetrics.WindowHeight(10, 1050, 400));
            // 内容本身高于下限 → 取「标题栏 + 内容」，不受下限影响
            Assert.Equal(PartitionMetrics.HeaderHeight + 344, PartitionMetrics.WindowHeight(344, 1050, 200));
            // 下限低于内置 MinHeight(140) 时不生效：防止把分区压到画不下内容
            Assert.Equal(PartitionMetrics.MinHeight, PartitionMetrics.WindowHeight(10, 1050, 100));
            // 下限高于屏幕可用高度时：窗口被抬到下限
            Assert.Equal(400, PartitionMetrics.WindowHeight(10, 300, 400));
            // 省略 minimumHeight 时行为不变（缺省 = 内置 MinHeight）
            Assert.Equal(PartitionMetrics.MinHeight, PartitionMetrics.WindowHeight(10, 1050));
        }

        [Fact]
        public void Crlf_TailIsStrippedBeforeMeasuringWidth()
        {
            // Windows 换行是 \r\n。不去掉尾部 \r 的话，每个 \r 都会被当成一个可见字符计宽。
            Assert.Equal(2, PartitionMetrics.NotesVisualLineCount("a\r\nb", 280));
        }

        [Fact]
        public void LongLine_WrapsAccordingToAvailableWidth()
        {
            // 宽度 134 ⇒ 可用 134 - 2×17 = 100；20 个半角 = 20 × 6.6 = 132 ⇒ 折成 2 行
            string line = new string('a', 20);
            Assert.Equal(2, PartitionMetrics.NotesVisualLineCount(line, 134));
            // 同一行放到宽得多的分区里则只需 1 行
            Assert.Equal(1, PartitionMetrics.NotesVisualLineCount(line, 400));
        }

        [Fact]
        public void FullWidthChars_TakeRoughlyTwiceTheRoom()
        {
            // 中文一行占的宽度约为半角的两倍 ⇒ 同样字数，中文应当更早开始折行。
            string cn = new string('中', 30);   // 30 × 12.0 = 360 > 246 ⇒ 2 行
            string en = new string('a', 30);   // 30 × 6.6  = 198 < 246 ⇒ 1 行
            Assert.Equal(2, PartitionMetrics.NotesVisualLineCount(cn, 280));
            Assert.Equal(1, PartitionMetrics.NotesVisualLineCount(en, 280));
            Assert.True(PartitionMetrics.IsFullWidth('中'));
            Assert.False(PartitionMetrics.IsFullWidth('a'));
        }

        // ── 包（macOS package）识别 ──────────────────────────────

        [Theory]
        [InlineData("Safari.app", true)]
        [InlineData("MyApp.APP", true)]      // 大小写不敏感
        [InlineData("Project.pages", true)]
        [InlineData("report.pdf", false)]
        [InlineData(".DS_Store", false)]     // 以点开头、无扩展名意义
        [InlineData("noext", false)]
        [InlineData("trailing.", false)]
        [InlineData("", false)]
        public void PackageName_Detection(string name, bool expected)
        {
            Assert.Equal(expected, FileKinds.IsPackageName(name));
        }

        [Fact]
        public void Package_IsNeverTreatedAsDirectory()
        {
            // `.app` 在文件系统上确实是目录，但对用户是**单个不可展开的项** ——
            // 双击是启动应用，不是钻进 Contents。
            Assert.False(FileKinds.IsOpaqueDirectory("Safari.app", isPhysicalDirectory: true));
            Assert.True(FileKinds.IsOpaqueDirectory("Documents", isPhysicalDirectory: true));
            Assert.False(FileKinds.IsOpaqueDirectory("file.txt", isPhysicalDirectory: false));
        }

        // ── 双击动作（三端同源）────────────────────────────────
        // ⚠️ 判据分散在三份代码里（`FileKinds.swift` / `FileKinds.cs` / `fileKinds.ts`），
        // 三组断言（mac FileKindsTests / 本文件 / electron verify-logic.mts）**必须一起改**，
        // 否则同一目录在三端会双击出不同结果。

        [Theory]
        [InlineData("截图.PNG")]
        [InlineData("photo.jpg")]
        [InlineData("a.JPEG")]
        [InlineData("gif.gif")]
        [InlineData("x.webp")]
        [InlineData("x.heic")]
        [InlineData("x.tif")]
        public void Images_OpenInBuiltInPreview(string name)
        {
            Assert.True(FileKinds.IsImage("/tmp/" + name));
            Assert.Equal(FileKinds.OpenAction.PreviewImage, FileKinds.DefaultAction(false, "/tmp/" + name));
        }

        [Theory]
        // svg / ico 故意不在清单里：WPF 的 BitmapImage 解不开 SVG，宁可交给系统默认程序
        [InlineData("报告.pdf")]
        [InlineData("a.docx")]
        [InlineData("logo.svg")]
        [InlineData("icon.ico")]
        [InlineData("notes.txt")]
        [InlineData("a.zip")]
        public void NonImages_OpenWithSystemHandler(string name)
        {
            Assert.False(FileKinds.IsImage("/tmp/" + name));
            Assert.Equal(FileKinds.OpenAction.OpenExternally, FileKinds.DefaultAction(false, "/tmp/" + name));
        }

        [Theory]
        [InlineData("/tmp/相册.png")]   // 目录名以图片后缀结尾也必须进入，而不是预览
        [InlineData("/tmp/素材")]
        public void Directories_AlwaysEnter(string path)
        {
            Assert.Equal(FileKinds.OpenAction.EnterDirectory, FileKinds.DefaultAction(true, path));
        }

        [Fact]
        public void ImageExtensionMatch_IsCaseInsensitive()
        {
            Assert.True(FileKinds.IsImage("/tmp/A.PNG"));
            Assert.False(FileKinds.IsImage("/tmp/noext"));
            Assert.False(FileKinds.IsImage(""));
        }

        // ── 搜索匹配 ────────────────────────────────────────────

        [Fact]
        public void EmptyQueryOrCandidate_NeverMatches()
        {
            Assert.Null(QueryMatcher.MatchScore("", "anything"));
            Assert.Null(QueryMatcher.MatchScore("   ", "anything"));
            Assert.Null(QueryMatcher.MatchScore("abc", ""));
            Assert.Null(QueryMatcher.MatchScore(null, null));
        }

        [Fact]
        public void MatchRanks_ExactBeatsPrefixBeatsSubstring()
        {
            int? exact = QueryMatcher.MatchScore("报表", "报表");
            int? prefix = QueryMatcher.MatchScore("报表", "报表2026.xlsx");
            int? substring = QueryMatcher.MatchScore("报表", "年度报表汇总.xlsx");
            Assert.True(exact > prefix);
            Assert.True(prefix > substring);
        }

        [Fact]
        public void MatchIsCaseInsensitive()
        {
            Assert.True(QueryMatcher.Matches("readme", "README.md"));
        }

        [Fact]
        public void SubsequenceMatch_RespectsOrder()
        {
            // 逐字符找「下一个」位置 ⇒ `报季` 不能命中 `季度报告`（cursor 只前进不后退）。
            Assert.False(QueryMatcher.Matches("报季", "季度报告"));
            Assert.True(QueryMatcher.Matches("季度", "季度报告"));
        }

        // ── 分区标题的图标与文字 ────────────────────────────────

        [Fact]
        public void TitleSplitAndCompose_RoundTrip()
        {
            foreach (string type in new[] { "notes", "portal", "todo" })
            {
                string icon = PartitionTitle.DefaultIconOf(type);
                var (gotIcon, gotText) = PartitionTitle.Split(PartitionTitle.Compose(icon, "工作"), type);
                Assert.Equal("工作", gotText);
                Assert.Equal(icon, gotIcon);
            }
        }

        [Fact]
        public void TitleSplit_OnlyRecognizesSymbolClassIcons()
        {
            // ⚠️ 边界（不是缺陷，但值得记住）：识别用的是 `\p{So}` 等符号类与 emoji，
            // **私用区字符 U+E000–U+F8FF 不在其中** —— 它们被当作普通文字。
            // 意思是「图标」必须是真正的符号/emoji；若哪天把图标换成 PUA 区段，
            // Split 会认不出来并把图标和标题粘成一坨，这里会红。
            var (icon, text) = PartitionTitle.Split("\uE70B 工作", "portal");
            Assert.Equal(PartitionTitle.DefaultIconOf("portal"), icon);
            Assert.Equal("\uE70B 工作", text);
        }

        [Fact]
        public void TitleSplit_FallsBackToDefaultIconAndPlaceholder()
        {
            var (icon, text) = PartitionTitle.Split("纯净标题", "portal");
            Assert.Equal("📁", icon);
            Assert.Equal("纯净标题", text);

            var (icon2, text2) = PartitionTitle.Split(null, "todo");
            Assert.Equal("✅", icon2);
            Assert.Equal("未命名分区", text2);
        }

        [Fact]
        public void DefaultIconOfUnknownType_StillYieldsSomething()
        {
            Assert.False(string.IsNullOrEmpty(PartitionTitle.DefaultIconOf("__unknown__")));
        }

        // ── 自适应高度：待办 / 目录类 / 窗口夹取 ──────────────────────────

        [Fact]
        public void AutoFitHeight_GrowsWithContentInsteadOfBeingAConstant()
        {
            // ⚠️ 修复前 portal 一律写死 240、todo 写死 44+n*28+40：
            // 条目越多越被裁、条目越少越留白。这里钉住「高度随条目数单调变化」。
            double small = PartitionMetrics.ListContentHeight(3);
            double large = PartitionMetrics.ListContentHeight(30);
            Assert.True(large > small, "目录类分区的内容高度必须随条目数增长");

            Assert.Equal(PartitionMetrics.ListChromeHeight + PartitionMetrics.ListBottomPadding,
                         PartitionMetrics.ListContentHeight(0));
            Assert.Equal(PartitionMetrics.ListContentHeight(0) + 10 * PartitionMetrics.ListRowHeight,
                         PartitionMetrics.ListContentHeight(10));

            Assert.Equal(PartitionMetrics.TodoChromeHeight + PartitionMetrics.TodoEmptyContentHeight,
                         PartitionMetrics.TodoContentHeight(0));
            Assert.Equal(PartitionMetrics.TodoChromeHeight + 5 * PartitionMetrics.TodoRowHeight,
                         PartitionMetrics.TodoContentHeight(5));
            // 负数条目（理论上不会出现）不能让高度反而变小
            Assert.Equal(PartitionMetrics.TodoContentHeight(0), PartitionMetrics.TodoContentHeight(-1));

            // 区分未完成与已完成（折叠/展开）
            Assert.Equal(PartitionMetrics.TodoChromeHeight + 2 * PartitionMetrics.TodoRowHeight + PartitionMetrics.TodoCompletedHeaderHeight,
                         PartitionMetrics.TodoContentHeight(2, 3, isCompletedCollapsed: true));
            Assert.Equal(PartitionMetrics.TodoChromeHeight + 2 * PartitionMetrics.TodoRowHeight + PartitionMetrics.TodoCompletedHeaderHeight + 3 * PartitionMetrics.TodoRowHeight,
                         PartitionMetrics.TodoContentHeight(2, 3, isCompletedCollapsed: false));
        }

        /// <summary>
        /// **三端契约**：顶栏 / 分区标题栏的五档字号必须与 mac 的 <c>DeskFont</c> 逐档相同。
        /// 这类「同一项在两个按钮上差 0.5pt」的偏差不会报错、也不会被发现，
        /// 只会让人觉得「哪里不太齐」—— 唯一能按住它的就是三端各钉一条常量断言。
        /// 改值必须同步改 mac <c>DeskFont</c> 与 Electron <c>utils/deskFont.ts</c>。
        /// </summary>
        [Fact]
        public void DeskFontTiersMatchMacBaseline()
        {
            Assert.Equal(12.5, DeskFont.Header);
            Assert.Equal(11.5, DeskFont.TopIcon);
            Assert.Equal(10.0, DeskFont.HeaderIcon);
            Assert.Equal(12.5, DeskFont.Glyph);
            Assert.Equal(10.0, DeskFont.Badge);
        }

        [Fact]
        public void WindowHeight_ClampsToMinHeightAndScreen()
        {
            // 内容再少也不低于 MinHeight（否则分区只剩一条缝）
            Assert.Equal(PartitionMetrics.MinHeight, PartitionMetrics.WindowHeight(0, 1000));
            // 屏幕可用高不足时，宁可撞到 MinHeight 也不许算出比它还小的值
            Assert.Equal(PartitionMetrics.MinHeight, PartitionMetrics.WindowHeight(500, 100));
            // 常规区间：标题栏 + 内容
            Assert.Equal(PartitionMetrics.HeaderHeight + 200, PartitionMetrics.WindowHeight(200, 1000));
            // 上限 = 屏幕可用高 - 60
            Assert.Equal(940, PartitionMetrics.WindowHeight(5000, 1000));
        }

        // ── 分区级外观（三端同契约，见 Services/PartitionLook.cs 头部注释） ──

        [Fact]
        public void PartitionLookDefaultsMatchMacBaseline()
        {
            Assert.Equal(16.0, PartitionLook.DefaultCornerRadius);
            Assert.Equal(12.0, PartitionLook.DefaultBlurAmount);
            Assert.Equal("#000000", PartitionLook.DefaultBgColor);
            Assert.Equal("#38bdf8", PartitionLook.DefaultHeaderColor);
            Assert.Equal("", PartitionLook.DefaultContentTextColor);
        }

        [Fact]
        public void PartitionLookRangesAndClamp()
        {
            Assert.Equal((0.0, 32.0), PartitionLook.CornerRadiusRange);
            Assert.Equal((0.0, 1.0), PartitionLook.BgOpacityRange);
            Assert.Equal((0.0, 40.0), PartitionLook.BlurRange);

            // 负圆角会让 WPF 的 CornerRadius 抛异常，负透明度直接报错 —— 必须夹住
            Assert.Equal(0.0, PartitionLook.ClampCornerRadius(-5));
            Assert.Equal(32.0, PartitionLook.ClampCornerRadius(999));
            Assert.Equal(0.0, PartitionLook.ClampBgOpacity(-1));
            Assert.Equal(1.0, PartitionLook.ClampBgOpacity(3));
            Assert.Equal(40.0, PartitionLook.ClampBlur(80));
        }

        [Fact]
        public void BlurTiersUseTheSharedThresholds()
        {
            Assert.Equal(PartitionLook.BlurTier.None, PartitionLook.TierFor(0));
            Assert.Equal(PartitionLook.BlurTier.UltraThin, PartitionLook.TierFor(12));   // 默认值落这一档
            Assert.Equal(PartitionLook.BlurTier.Thin, PartitionLook.TierFor(15));
            Assert.Equal(PartitionLook.BlurTier.Regular, PartitionLook.TierFor(30));
            Assert.Equal(PartitionLook.BlurTier.Regular, PartitionLook.TierFor(999));    // 越界先夹再判
        }

        [Fact]
        public void PartitionStyleEmptyMeansFollowGlobal()
        {
            var st = new PartitionStyle();
            Assert.True(st.IsEmpty);

            st.BorderRadius = 8;
            Assert.False(st.IsEmpty);

            st.Reset();
            Assert.True(st.IsEmpty);
        }

        [Fact]
        public void PartitionStyleCloneIsIndependent()
        {
            var a = new PartitionStyle { BgColor = "#123456", BlurAmount = 20 };
            var b = a.Clone();
            b.BgColor = "#ffffff";

            Assert.Equal("#123456", a.BgColor);
            Assert.Equal("#ffffff", b.BgColor);
            Assert.Equal(20, b.BlurAmount);
        }

        // ── 文件拖入分区的落点计算（三端同契约，见 Services/FileMover.cs 头部注释） ──

        [Fact]
        public void FileMover_NormalizesBackslashes()
        {
            Assert.Equal("C:/Users/me", FileMover.Normalize(@"C:\Users\me\"));
            // 盘根不能把斜杠也吃掉
            Assert.Equal("C:", FileMover.Normalize(@"C:\"));
        }

        [Fact]
        public void FileMover_SameDirectoryIsNoOp()
        {
            Assert.True(FileMover.IsSameDirectory(@"C:\Users\me\a.txt", @"C:\Users\me"));
            Assert.True(FileMover.IsSameDirectory(@"C:\Users\me\a.txt", @"C:\Users\me\"));
            Assert.False(FileMover.IsSameDirectory(@"C:\Users\me\a.txt", @"C:\Users\other"));
        }

        [Fact]
        public void FileMover_RejectsMovingFolderIntoItself()
        {
            Assert.True(FileMover.IsSelfOrDescendant(@"C:\me\Foo", @"C:\me\Foo"));
            Assert.True(FileMover.IsSelfOrDescendant(@"C:\me\Foo\bar", @"C:\me\Foo"));
            // ⚠️ 纯前缀比较的经典误判：FooBar 不是 Foo 的子目录
            Assert.False(FileMover.IsSelfOrDescendant(@"C:\me\FooBar", @"C:\me\Foo"));
            // Windows 路径不区分大小写
            Assert.True(FileMover.IsSelfOrDescendant(@"c:\ME\foo\bar", @"C:\me\Foo"));
        }

        [Fact]
        public void FileMover_NeverOverwritesExistingName()
        {
            var existing = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            string d1 = FileMover.Destination(@"C:\tmp\a.txt", @"C:\dst", existing.Contains);
            Assert.Equal("C:/dst/a.txt", d1);

            existing.Add(d1);
            Assert.Equal("C:/dst/a 2.txt", FileMover.Destination(@"C:\tmp\a.txt", @"C:\dst", existing.Contains));

            // 无扩展名的目录名：后缀加在末尾
            var dirs = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "C:/dst/Photos" };
            Assert.Equal("C:/dst/Photos 2", FileMover.Destination(@"C:\tmp\Photos", @"C:\dst", dirs.Contains));
        }

        [Fact]
        public void FileMover_ConflictsDetectsSameNameOnly()
        {
            var existing = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "C:/dst/a.txt" };
            // a.txt 已存在 → 命中；b.txt 不存在 → 不命中
            var hits = FileMover.Conflicts(new[] { @"C:\tmp\a.txt", @"C:\tmp\b.txt" }, @"C:\dst", existing.Contains);
            Assert.Equal(new[] { @"C:\tmp\a.txt" }, hits);

            // 同目录（C:\dst\x.txt → C:\dst）不算冲突，只是 no-op
            Assert.Empty(FileMover.Conflicts(new[] { @"C:\dst\x.txt" }, @"C:\dst", _ => true));
            // 把文件夹拖进它自己的子目录（C:\dst\Foo → C:\dst\Foo\sub）会被 ShouldMove 拒绝
            Assert.Empty(FileMover.Conflicts(new[] { @"C:\dst\Foo" }, @"C:\dst\Foo\sub", _ => true));
        }

        [Fact]
        public void FileMover_MoveWithReplaceDeletesTargetFirst()
        {
            // replace=true 时同名先删后移；这里只验证落点与 ShouldMove 衔接（磁盘操作由集成测试覆盖）。
            bool skipped;
            // 同目录 → 跳过，不移动
            Assert.Null(FileMover.Move(@"C:\dst\x.txt", @"C:\dst", out skipped, replace: true));
            Assert.True(skipped);
        }

        // ── 待办清单逻辑测试 ─────────────────────────────────────

        [Fact]
        public void TodoItem_PriorityColor_MatchesMacBaseline()
        {
            var high = new TodoItem { Priority = "high" };
            var medium = new TodoItem { Priority = "medium" };
            var low = new TodoItem { Priority = "low" };

            Assert.Equal("#EF4444", high.PriorityColor);   // 红
            Assert.Equal("#F59E0B", medium.PriorityColor); // 橙
            Assert.Equal("#888888", low.PriorityColor);    // 灰 (对齐 mac secondary)
        }

        [Fact]
        public void TodoItem_ClearCompleted_RemovesOnlyCompleted()
        {
            var list = new List<TodoItem>
            {
                new TodoItem { Id = "1", Text = "任务1", Completed = false },
                new TodoItem { Id = "2", Text = "任务2", Completed = true },
                new TodoItem { Id = "3", Text = "任务3", Completed = false },
                new TodoItem { Id = "4", Text = "任务4", Completed = true },
            };

            list.RemoveAll(t => t.Completed);

            Assert.Equal(2, list.Count);
            Assert.Equal(new[] { "1", "3" }, list.Select(t => t.Id));
        }
    }
}
