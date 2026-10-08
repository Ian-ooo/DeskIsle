import XCTest
@testable import DeskIsleCore

/// 文件操作的键盘意图判据。
///
/// ⚠️ 三端的断言集必须一起改 —— Windows 见 `FileKeyShortcutsTests.cs`，
/// Electron 见 `verify-logic.mts` 的「文件操作的键盘意图」小节。
final class FileKeyShortcutsTests: XCTestCase {

    // MARK: - 键名归一化

    func testKeyNameNormalization() {
        // 三端原生键名不同（`Key.Space` / `KeyboardEvent.key` / NSEvent 转出来的串），
        // 收敛后必须一致 —— 否则同一张语义表会在某一端失效。
        XCTAssertEqual(FileKeyShortcuts.key(fromName: "a"), .a)
        XCTAssertEqual(FileKeyShortcuts.key(fromName: "A"), .a, "大小写不敏感：⌘⇧A 与 ⌘A 是同一个键")
        XCTAssertEqual(FileKeyShortcuts.key(fromName: "v"), .v)
        XCTAssertEqual(FileKeyShortcuts.key(fromName: " "), .space)
        XCTAssertEqual(FileKeyShortcuts.key(fromName: "Space"), .space)
        XCTAssertEqual(FileKeyShortcuts.key(fromName: "escape"), .escape)
        XCTAssertEqual(FileKeyShortcuts.key(fromName: "Esc"), .escape)
        XCTAssertEqual(FileKeyShortcuts.key(fromName: "Return"), .enter)
        XCTAssertEqual(FileKeyShortcuts.key(fromName: "Enter"), .enter)
        XCTAssertEqual(FileKeyShortcuts.key(fromName: "F2"), .f2)
        XCTAssertEqual(FileKeyShortcuts.key(fromName: "Delete"), .delete)
        XCTAssertEqual(FileKeyShortcuts.key(fromName: "Del"), .delete)
        XCTAssertEqual(FileKeyShortcuts.key(fromName: "Backspace"), .backspace)
        XCTAssertEqual(FileKeyShortcuts.key(fromName: "Tab"), .other)
        XCTAssertEqual(FileKeyShortcuts.key(fromName: ""), .other, "空串不能崩，也不能误判成某个动作")
    }

    // MARK: - 全选

    func testSelectAllNeedsPrimaryModifier() {
        XCTAssertEqual(FileKeyShortcuts.action(for: .a, primary: true,  selectedCount: 0, layout: .mac), .selectAll)
        XCTAssertEqual(FileKeyShortcuts.action(for: .a, primary: true,  selectedCount: 0, layout: .pc), .selectAll)
        XCTAssertEqual(FileKeyShortcuts.action(for: .a, primary: false, selectedCount: 0, layout: .mac), .none,
                       "裸按 a 不能全选：那会把「打字」吃掉")
        XCTAssertEqual(FileKeyShortcuts.action(for: .a, primary: true, shift: true, selectedCount: 3, layout: .mac), .none,
                       "⌘⇧A 不是全选意图，不接管（留给系统）")
    }

    // MARK: - 剪贴板三件套

    func testCopyCutRequireSelection() {
        XCTAssertEqual(FileKeyShortcuts.action(for: .c, primary: true,  selectedCount: 2, layout: .mac), .copy)
        XCTAssertEqual(FileKeyShortcuts.action(for: .c, primary: true,  selectedCount: 0, layout: .mac), .none,
                       "没选中任何东西时 ⌘C 没有意义")
        XCTAssertEqual(FileKeyShortcuts.action(for: .c, primary: false, selectedCount: 2, layout: .pc), .none)
        XCTAssertEqual(FileKeyShortcuts.action(for: .x, primary: true,  selectedCount: 1, layout: .pc), .cut)
        XCTAssertEqual(FileKeyShortcuts.action(for: .x, primary: true,  selectedCount: 0, layout: .pc), .none)
        XCTAssertEqual(FileKeyShortcuts.action(for: .c, primary: true, shift: true, selectedCount: 1, layout: .mac), .none,
                       "⌘⇧C 是「复制路径」一类别的意图，不抢")
    }

    func testPasteDoesNotDependOnSelection() {
        // 粘贴看的是剪贴板里有没有东西，跟当前选区无关 —— 选区只决定「贴到哪」。
        XCTAssertEqual(FileKeyShortcuts.action(for: .v, primary: true,  selectedCount: 0, layout: .mac), .paste)
        XCTAssertEqual(FileKeyShortcuts.action(for: .v, primary: true,  selectedCount: 3, layout: .mac), .paste)
        XCTAssertEqual(FileKeyShortcuts.action(for: .v, primary: false, selectedCount: 0, layout: .pc), .none)
    }

    // MARK: - 删除：mac 与 pc 的键位习惯不同

    func testTrashUsesMacConvention() {
        XCTAssertEqual(FileKeyShortcuts.action(for: .backspace, primary: true,  selectedCount: 2, layout: .mac), .trash,
                       "macOS 上删除文件是 ⌘⌫")
        XCTAssertEqual(FileKeyShortcuts.action(for: .backspace, primary: false, selectedCount: 2, layout: .mac), .none,
                       "⚠️ 单独的 ⌫ 在访达里也不删文件，不能因为「方便」就抢过来")
        XCTAssertEqual(FileKeyShortcuts.action(for: .backspace, primary: true,  selectedCount: 0, layout: .mac), .none)
        XCTAssertEqual(FileKeyShortcuts.action(for: .delete,    primary: false, selectedCount: 1, layout: .mac), .trash)
    }

    func testTrashUsesPcConvention() {
        XCTAssertEqual(FileKeyShortcuts.action(for: .delete,    primary: false, selectedCount: 3, layout: .pc), .trash,
                       "Windows 上 Delete 直接删除")
        XCTAssertEqual(FileKeyShortcuts.action(for: .delete,    primary: false, selectedCount: 0, layout: .pc), .none)
        XCTAssertEqual(FileKeyShortcuts.action(for: .backspace, primary: false, selectedCount: 3, layout: .pc), .none,
                       "⚠️ pc 上 Backspace 是「返回上一级」，抢来删文件会造成不可挽回的损失")
        XCTAssertEqual(FileKeyShortcuts.action(for: .backspace, primary: true,  selectedCount: 3, layout: .pc), .none,
                       "Ctrl+Backspace 同样不接管")
    }

    // MARK: - 只作用于单个条目的动作

    func testRenameRequiresExactlyOneSelection() {
        XCTAssertEqual(FileKeyShortcuts.action(for: .enter, primary: false, selectedCount: 1, layout: .mac), .rename)
        XCTAssertEqual(FileKeyShortcuts.action(for: .f2,    primary: false, selectedCount: 1, layout: .pc), .rename,
                       "Windows 上 F2 是重命名")
        XCTAssertEqual(FileKeyShortcuts.action(for: .enter, primary: false, selectedCount: 0, layout: .pc), .none)
        XCTAssertEqual(FileKeyShortcuts.action(for: .enter, primary: false, selectedCount: 2, layout: .pc), .none,
                       "多选时回车没有唯一改名目标 —— 宁可没反应，也不要偷偷改掉某一个")
    }

    func testPreviewRequiresExactlyOneSelection() {
        XCTAssertEqual(FileKeyShortcuts.action(for: .space, primary: false, selectedCount: 1, layout: .mac), .preview,
                       "空格 = 快速查看")
        XCTAssertEqual(FileKeyShortcuts.action(for: .space, primary: false, selectedCount: 0, layout: .mac), .none)
        XCTAssertEqual(FileKeyShortcuts.action(for: .space, primary: false, selectedCount: 2, layout: .pc), .none)
    }

    // MARK: - 其它

    func testEscapeClearsSelectionOnlyWhenThereIsOne() {
        XCTAssertEqual(FileKeyShortcuts.action(for: .escape, primary: false, selectedCount: 4, layout: .mac), .clearSelection)
        XCTAssertEqual(FileKeyShortcuts.action(for: .escape, primary: false, selectedCount: 0, layout: .pc), .none,
                       "没有选区时 Esc 应该留给上层（关面板 / 退出搜索）")
    }

    func testUnrelatedKeysAreNeverClaimed() {
        XCTAssertEqual(FileKeyShortcuts.action(for: .other, primary: true,  selectedCount: 2, layout: .mac), .none)
        XCTAssertEqual(FileKeyShortcuts.action(for: .other, primary: false, selectedCount: 2, layout: .pc), .none)
    }
}
