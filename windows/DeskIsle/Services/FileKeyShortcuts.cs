using System;

namespace DeskIsle.Services
{
    /// <summary>
    /// 键位习惯。
    /// <para>
    /// ⚠️ 这不是「端」而是<strong>键位习惯</strong>：Electron 跑在 macOS 上时要按 macOS 的习惯走，
    /// 跑在 Windows / Linux 上时按 pc 习惯 —— 所以用这张表区分，而不是按三份代码区分。
    /// </para><para>
    /// - macOS 访达：<c>⌘⌫</c> 才是删除，单独的 <c>⌫</c> 什么也不做。<br/>
    /// - Windows 资源管理器：<c>Delete</c> 直接删除；而 <c>Backspace</c> 是<strong>返回上一级</strong> ——
    ///   这条绝不能拿来删文件，否则用户想回上一层却把文件删了。
    /// </para>
    /// </summary>
    public enum FileKeyLayout { Mac, Pc }

    /// <summary>
    /// 归一化的键标识。三端各自的原生键名（<c>NSEvent</c> / WPF 的 <c>Key</c> / <c>KeyboardEvent.key</c>）
    /// 先过 <see cref="FileKeyShortcuts.FromName"/> 收敛到这里，语义表才只有一份。
    /// </summary>
    public enum FileKey { A, C, X, V, Escape, Enter, F2, Space, Delete, Backspace, Other }

    /// <summary>一个按键组合在「文件列表」语境下代表的动作。</summary>
    public enum FileKeyAction
    {
        None,
        SelectAll,
        ClearSelection,
        Trash,
        Rename,
        Preview,
        Copy,
        Cut,
        Paste
    }

    /// <summary>
    /// 文件列表里的键盘 / 快捷键判据 —— 对齐访达与资源管理器的手感的<strong>唯一出处</strong>。
    /// <para>
    /// 三端各有断言钉住同一张表（见 README「文件操作」小节），改一处必须三处同改。
    /// 这里是纯函数：不认识 AppKit / WPF / DOM，只回答「这个组合是什么意思」。
    /// </para>
    /// </summary>
    public static class FileKeyShortcuts
    {
        /// <summary>把平台原生键名收敛成 <see cref="FileKey"/>。</summary>
        public static FileKey FromName(string? raw)
        {
            switch ((raw ?? string.Empty).ToLowerInvariant())
            {
                case "a": return FileKey.A;
                case "c": return FileKey.C;
                case "x": return FileKey.X;
                case "v": return FileKey.V;
                case "escape":
                case "esc": return FileKey.Escape;
                case "enter":
                case "return": return FileKey.Enter;
                case "f2": return FileKey.F2;
                case " ":
                case "space": return FileKey.Space;
                case "delete":
                case "del": return FileKey.Delete;
                case "backspace": return FileKey.Backspace;
                default: return FileKey.Other;
            }
        }

        /// <summary>
        /// 解析一个按键组合的意图。
        /// </summary>
        /// <param name="key">归一化后的键。</param>
        /// <param name="primary"><strong>主修饰键</strong>是否按下 —— mac 是 ⌘，Windows / Linux 是 Ctrl。</param>
        /// <param name="selectedCount">当前选中了多少个条目（决定 rename / preview 之类有没有意义）。</param>
        /// <param name="layout">键位习惯。</param>
        /// <param name="shift">⇧ / Shift 是否按下。</param>
        public static FileKeyAction Action(
            FileKey key, bool primary, int selectedCount, FileKeyLayout layout, bool shift = false)
        {
            bool hasSelection = selectedCount > 0;

            switch (key)
            {
                case FileKey.A:
                    // ⌘A / Ctrl+A = 全选。带 ⇧ 时不接管（那是别的意图，别抢）。
                    return primary && !shift ? FileKeyAction.SelectAll : FileKeyAction.None;

                case FileKey.C:
                    return primary && !shift && hasSelection ? FileKeyAction.Copy : FileKeyAction.None;

                case FileKey.X:
                    return primary && !shift && hasSelection ? FileKeyAction.Cut : FileKeyAction.None;

                case FileKey.V:
                    // 粘贴跟「当前有没有选中」无关：剪贴板里有东西就该能贴。
                    return primary ? FileKeyAction.Paste : FileKeyAction.None;

                case FileKey.Escape:
                    return hasSelection ? FileKeyAction.ClearSelection : FileKeyAction.None;

                case FileKey.Enter:
                case FileKey.F2:
                    // 重命名一次只能改一个名字 —— 多选时按下等于没按，而不是改掉第一个。
                    return selectedCount == 1 ? FileKeyAction.Rename : FileKeyAction.None;

                case FileKey.Space:
                    // 同理：空格是「看这一个」，多选时没有唯一目标。
                    return selectedCount == 1 ? FileKeyAction.Preview : FileKeyAction.None;

                case FileKey.Delete:
                    return hasSelection ? FileKeyAction.Trash : FileKeyAction.None;

                case FileKey.Backspace:
                    return layout == FileKeyLayout.Mac
                        // ⚠️ 必须是 ⌘⌫：mac 上单独的 ⌫ 在访达里也不删文件。
                        ? (primary && hasSelection ? FileKeyAction.Trash : FileKeyAction.None)
                        // Backspace 属于「返回上一级」，这里永不接管。
                        : FileKeyAction.None;

                default:
                    return FileKeyAction.None;
            }
        }
    }
}
