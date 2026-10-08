import Foundation

// MARK: - 「文件操作」的键盘意图（三端同源判据）

/// 键位所属习惯。
///
/// ⚠️ 这不是「端」而是**键位习惯**：Electron 跑在 macOS 上时要按 macOS 的习惯走，
/// 跑在 Windows / Linux 上时按 pc 习惯 —— 所以用这张表区分，而不是按三份代码区分。
///
/// - macOS 访达：`⌘⌫` 才是删除，单独的 `⌫` 什么也不做。
/// - Windows 资源管理器：`Delete` 直接删除；而 `Backspace` 是**返回上一级** ——
///   这条绝不能拿来删文件，否则用户想回上一层却把文件删了。
public enum FileKeyLayout: String, Sendable, CaseIterable {
    case mac
    case pc
}

/// 归一化的键标识。三端各自的原生键名（`NSEvent` / `Key` / `KeyboardEvent.key`）
/// 先过 `FileKeyShortcuts.key(fromName:)` 收敛到这里，语义表才只有一份。
public enum FileKey: String, Sendable, CaseIterable {
    case a, c, x, v
    case escape, enter, f2, space
    case delete, backspace
    case other
}

/// 一个按键组合在「文件列表」语境下代表的动作。
public enum FileKeyAction: String, Sendable, CaseIterable, Equatable {
    case none
    case selectAll
    case clearSelection
    case trash
    case rename
    case preview
    case copy
    case cut
    case paste
}

/// 文件列表里的键盘 / 快捷键判据 —— 对齐访达与资源管理器的手感的**唯一出处**。
///
/// 三端各有断言钉住同一张表（见 README「文件操作」小节），改一处必须三处同改。
/// 这里是纯函数：不认识 AppKit / WPF / DOM，只回答「这个组合是什么意思」。
public struct FileKeyShortcuts {

    /// 把平台原生键名收敛成 `FileKey`。
    ///
    /// mac 侧要把「没有字符的特殊键」先翻成这些名字（`NSEvent` 对 Escape / Space 给的
    /// `charactersIgnoringModifiers` 不是可读串），转换表见 `PartitionView.resolveFileKey`。
    public static func key(fromName raw: String) -> FileKey {
        switch raw.lowercased() {
        case "a":                       return .a
        case "c":                       return .c
        case "x":                       return .x
        case "v":                       return .v
        case "escape", "esc":           return .escape
        case "enter", "return":         return .enter
        case "f2":                      return .f2
        case " ", "space":              return .space
        case "delete", "del":           return .delete
        case "backspace":               return .backspace
        default:                        return .other
        }
    }

    /// - Parameters:
    ///   - key: 归一化后的键。
    ///   - primary: **主修饰键**是否按下 —— mac 是 ⌘，Windows / Linux 是 Ctrl。
    ///   - selectedCount: 当前选中了多少个条目（决定 rename / preview 之类有没有意义）。
    ///   - layout: 键位习惯。
    public static func action(
        for key: FileKey,
        primary: Bool,
        shift: Bool = false,
        selectedCount: Int,
        layout: FileKeyLayout
    ) -> FileKeyAction {
        let hasSelection = selectedCount > 0

        switch key {
        case .a:
            // ⌘A / Ctrl+A = 全选。带 ⇧ 时不接管（那是别的意图，别抢）。
            return primary && !shift ? .selectAll : .none

        case .c:
            return primary && !shift && hasSelection ? .copy : .none

        case .x:
            return primary && !shift && hasSelection ? .cut : .none

        case .v:
            // 粘贴跟「当前有没有选中」无关：剪贴板里有东西就该能贴。
            return primary ? .paste : .none

        case .escape:
            return hasSelection ? .clearSelection : .none

        case .enter, .f2:
            // 重命名一次只能改一个名字 —— 多选时按下等于没按，而不是改掉第一个。
            return selectedCount == 1 ? .rename : .none

        case .space:
            // 同理：空格是「看这一个」，多选时没有唯一目标。
            return selectedCount == 1 ? .preview : .none

        case .delete:
            return hasSelection ? .trash : .none

        case .backspace:
            switch layout {
            case .mac:
                // ⚠️ 必须是 ⌘⌫：mac 上单独的 ⌫ 在访达里也不删文件。
                return primary && hasSelection ? .trash : .none
            case .pc:
                // Backspace 属于「返回上一级」，这里永不接管。
                return .none
            }

        case .other:
            return .none
        }
    }
}
