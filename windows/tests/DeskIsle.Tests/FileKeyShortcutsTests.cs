using DeskIsle.Services;
using Xunit;

namespace DeskIsle.Tests
{
    /// <summary>
    /// 文件操作的键盘意图判据。
    /// <para>
    /// ⚠️ 三端的断言集必须一起改 —— mac 见 <c>FileKeyShortcutsTests.swift</c>，
    /// Electron 见 <c>verify-logic.mts</c> 的「文件操作的键盘意图」小节。
    /// </para>
    /// </summary>
    public class FileKeyShortcutsTests
    {
        // MARK: - 键名归一化

        [Fact]
        public void KeyNameNormalization()
        {
            // 三端原生键名不同（Key.Space / KeyboardEvent.key / NSEvent 转出来的串），
            // 收敛后必须一致 —— 否则同一张语义表会在某一端失效。
            Assert.Equal(FileKey.A, FileKeyShortcuts.FromName("a"));
            Assert.Equal(FileKey.A, FileKeyShortcuts.FromName("A")); // 大小写不敏感
            Assert.Equal(FileKey.V, FileKeyShortcuts.FromName("v"));
            Assert.Equal(FileKey.Space, FileKeyShortcuts.FromName(" "));
            Assert.Equal(FileKey.Space, FileKeyShortcuts.FromName("Space"));
            Assert.Equal(FileKey.Escape, FileKeyShortcuts.FromName("escape"));
            Assert.Equal(FileKey.Escape, FileKeyShortcuts.FromName("Esc"));
            Assert.Equal(FileKey.Enter, FileKeyShortcuts.FromName("Return"));
            Assert.Equal(FileKey.Enter, FileKeyShortcuts.FromName("Enter"));
            Assert.Equal(FileKey.F2, FileKeyShortcuts.FromName("F2"));
            Assert.Equal(FileKey.Delete, FileKeyShortcuts.FromName("Delete"));
            Assert.Equal(FileKey.Delete, FileKeyShortcuts.FromName("Del"));
            Assert.Equal(FileKey.Backspace, FileKeyShortcuts.FromName("Backspace"));
            Assert.Equal(FileKey.Other, FileKeyShortcuts.FromName("Tab"));
            Assert.Equal(FileKey.Other, FileKeyShortcuts.FromName("")); // 空串不能崩
            Assert.Equal(FileKey.Other, FileKeyShortcuts.FromName(null));
        }

        // MARK: - 全选

        [Fact]
        public void SelectAllNeedsPrimaryModifier()
        {
            Assert.Equal(FileKeyAction.SelectAll, FileKeyShortcuts.Action(FileKey.A, true, 0, FileKeyLayout.Mac));
            Assert.Equal(FileKeyAction.SelectAll, FileKeyShortcuts.Action(FileKey.A, true, 0, FileKeyLayout.Pc));
            Assert.Equal(FileKeyAction.None, FileKeyShortcuts.Action(FileKey.A, false, 0, FileKeyLayout.Mac));
            Assert.Equal(FileKeyAction.None,
                FileKeyShortcuts.Action(FileKey.A, true, 3, FileKeyLayout.Mac, shift: true)); // Ctrl+Shift+A
        }

        // MARK: - 剪贴板三件套

        [Fact]
        public void CopyCutRequireSelection()
        {
            Assert.Equal(FileKeyAction.Copy, FileKeyShortcuts.Action(FileKey.C, true, 2, FileKeyLayout.Mac));
            Assert.Equal(FileKeyAction.None, FileKeyShortcuts.Action(FileKey.C, true, 0, FileKeyLayout.Mac));
            Assert.Equal(FileKeyAction.None, FileKeyShortcuts.Action(FileKey.C, false, 2, FileKeyLayout.Pc));
            Assert.Equal(FileKeyAction.Cut, FileKeyShortcuts.Action(FileKey.X, true, 1, FileKeyLayout.Pc));
            Assert.Equal(FileKeyAction.None, FileKeyShortcuts.Action(FileKey.X, true, 0, FileKeyLayout.Pc));
            Assert.Equal(FileKeyAction.None,
                FileKeyShortcuts.Action(FileKey.C, true, 1, FileKeyLayout.Mac, shift: true));
        }

        [Fact]
        public void PasteDoesNotDependOnSelection()
        {
            // 粘贴看的是剪贴板里有没有东西，跟当前选区无关 —— 选区只决定「贴到哪」。
            Assert.Equal(FileKeyAction.Paste, FileKeyShortcuts.Action(FileKey.V, true, 0, FileKeyLayout.Mac));
            Assert.Equal(FileKeyAction.Paste, FileKeyShortcuts.Action(FileKey.V, true, 3, FileKeyLayout.Mac));
            Assert.Equal(FileKeyAction.None, FileKeyShortcuts.Action(FileKey.V, false, 0, FileKeyLayout.Pc));
        }

        // MARK: - 删除：mac 与 pc 的键位习惯不同

        [Fact]
        public void TrashUsesMacConvention()
        {
            Assert.Equal(FileKeyAction.Trash,
                FileKeyShortcuts.Action(FileKey.Backspace, true, 2, FileKeyLayout.Mac)); // ⌘⌫
            Assert.True(FileKeyShortcuts.Action(FileKey.Backspace, false, 2, FileKeyLayout.Mac) == FileKeyAction.None,
                "⚠️ 单独的 ⌫ 在访达里也不删文件，不能因为「方便」就抢过来");
            Assert.Equal(FileKeyAction.None, FileKeyShortcuts.Action(FileKey.Backspace, true, 0, FileKeyLayout.Mac));
            Assert.Equal(FileKeyAction.Trash, FileKeyShortcuts.Action(FileKey.Delete, false, 1, FileKeyLayout.Mac));
        }

        [Fact]
        public void TrashUsesPcConvention()
        {
            Assert.Equal(FileKeyAction.Trash, FileKeyShortcuts.Action(FileKey.Delete, false, 3, FileKeyLayout.Pc));
            Assert.Equal(FileKeyAction.None, FileKeyShortcuts.Action(FileKey.Delete, false, 0, FileKeyLayout.Pc));
            Assert.True(FileKeyShortcuts.Action(FileKey.Backspace, false, 3, FileKeyLayout.Pc) == FileKeyAction.None,
                "⚠️ pc 上 Backspace 是「返回上一级」，抢来删文件会造成不可挽回的损失");
            Assert.Equal(FileKeyAction.None, FileKeyShortcuts.Action(FileKey.Backspace, true, 3, FileKeyLayout.Pc));
        }

        // MARK: - 只作用于单个条目的动作

        [Fact]
        public void RenameRequiresExactlyOneSelection()
        {
            Assert.Equal(FileKeyAction.Rename, FileKeyShortcuts.Action(FileKey.Enter, false, 1, FileKeyLayout.Mac));
            Assert.Equal(FileKeyAction.Rename, FileKeyShortcuts.Action(FileKey.F2, false, 1, FileKeyLayout.Pc));
            Assert.Equal(FileKeyAction.None, FileKeyShortcuts.Action(FileKey.Enter, false, 0, FileKeyLayout.Pc));
            Assert.True(FileKeyShortcuts.Action(FileKey.Enter, false, 2, FileKeyLayout.Pc) == FileKeyAction.None,
                "多选时回车没有唯一改名目标 —— 宁可没反应，也不要偷偷改掉某一个");
        }

        [Fact]
        public void PreviewRequiresExactlyOneSelection()
        {
            Assert.Equal(FileKeyAction.Preview, FileKeyShortcuts.Action(FileKey.Space, false, 1, FileKeyLayout.Mac));
            Assert.Equal(FileKeyAction.None, FileKeyShortcuts.Action(FileKey.Space, false, 0, FileKeyLayout.Mac));
            Assert.Equal(FileKeyAction.None, FileKeyShortcuts.Action(FileKey.Space, false, 2, FileKeyLayout.Pc));
        }

        // MARK: - 其它

        [Fact]
        public void EscapeClearsSelectionOnlyWhenThereIsOne()
        {
            Assert.Equal(FileKeyAction.ClearSelection,
                FileKeyShortcuts.Action(FileKey.Escape, false, 4, FileKeyLayout.Mac));
            Assert.True(FileKeyShortcuts.Action(FileKey.Escape, false, 0, FileKeyLayout.Pc) == FileKeyAction.None,
                "没有选区时 Esc 应该留给上层（关面板 / 退出搜索）");
        }

        [Fact]
        public void UnrelatedKeysAreNeverClaimed()
        {
            Assert.Equal(FileKeyAction.None, FileKeyShortcuts.Action(FileKey.Other, true, 2, FileKeyLayout.Mac));
            Assert.Equal(FileKeyAction.None, FileKeyShortcuts.Action(FileKey.Other, false, 2, FileKeyLayout.Pc));
        }
    }
}
