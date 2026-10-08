using System;
using System.Collections.Generic;
using System.Windows.Forms;
using DeskIsle.Native;

namespace DeskIsle.Services
{
    /// <summary>
    /// 全局热键字符串 ↔ Win32「修饰键 + 虚拟键码」的互转。
    ///
    /// 存在的理由：配置里存的是人可读的 <c>"Alt+D"</c>，而 <c>RegisterHotKey</c>
    /// 需要 <c>(MOD_ALT, 0x44)</c>。此前这段转换**根本不存在** ——
    /// 界面把用户录制的字符串原样存进配置就不管了，注册时却硬编码 Alt+D，
    /// 于是「说了能改、改了没用」。这个类就是补上缺失的那一环。
    ///
    /// 解析对顺序与大小写都不敏感（<c>Ctrl+Alt+D</c> / <c>alt+ctrl+d</c> 等价），
    /// 输出则统一成固定顺序，保证「同一组合在界面上永远显示成同一个样子」。
    /// </summary>
    public static class HotkeyParser
    {
        /// <summary>
        /// 解析形如 <c>"Ctrl+Alt+D"</c> 的热键字符串。
        /// 返回 false 表示格式不合法，或**一个修饰键都没有** ——
        /// 裸字母做全局热键会把用户正常打字全抢走，一律拒绝。
        /// </summary>
        public static bool TryParse(string? text, out uint modifiers, out uint virtualKey)
        {
            modifiers = 0;
            virtualKey = 0;
            if (string.IsNullOrWhiteSpace(text)) return false;

            string[] parts = text!.Split('+', StringSplitOptions.RemoveEmptyEntries);
            string? keyName = null;

            foreach (var raw in parts)
            {
                string token = raw.Trim();
                if (token.Length == 0) continue;

                switch (token.ToLowerInvariant())
                {
                    case "ctrl":
                    case "control":
                        modifiers |= Win32.MOD_CONTROL;
                        break;
                    case "alt":
                        modifiers |= Win32.MOD_ALT;
                        break;
                    case "shift":
                        modifiers |= Win32.MOD_SHIFT;
                        break;
                    case "win":
                    case "meta":
                    case "super":
                        modifiers |= Win32.MOD_WIN;
                        break;
                    default:
                        keyName = token;
                        break;
                }
            }

            if (keyName == null || modifiers == 0) return false;

            // Keys 与 WPF 的 Key 枚举成员名基本一一对应（都源自 Win32 虚拟键命名），
            // 所以录制侧 e.Key.ToString() 的结果可以直接在这里解析回来。
            if (!Enum.TryParse<Keys>(keyName, ignoreCase: true, out var key)) return false;

            var vk = (int)key;
            // 只剩修饰键（F1-F24 / 字母 / 数字之外的纯修饰键）没有意义
            if (vk == 0 || vk == (int)Keys.ControlKey || vk == (int)Keys.Menu ||
                vk == (int)Keys.ShiftKey || vk == (int)Keys.LWin || vk == (int)Keys.RWin)
            {
                return false;
            }

            virtualKey = (uint)vk;
            return true;
        }

        /// <summary>把「修饰键 + 虚拟键码」重新写成人可读字符串（固定 Ctrl→Alt→Shift→Win 顺序）。</summary>
        public static string Describe(uint modifiers, uint virtualKey)
        {
            if (virtualKey == 0) return string.Empty;

            var parts = new List<string>(5);
            if ((modifiers & Win32.MOD_CONTROL) != 0) parts.Add("Ctrl");
            if ((modifiers & Win32.MOD_ALT) != 0) parts.Add("Alt");
            if ((modifiers & Win32.MOD_SHIFT) != 0) parts.Add("Shift");
            if ((modifiers & Win32.MOD_WIN) != 0) parts.Add("Win");
            parts.Add(KeyName(virtualKey));
            return string.Join("+", parts);
        }

        /// <summary>虚拟键码 → 名称。取不到枚举名时退回数字，保证往返不丢信息。</summary>
        public static string KeyName(uint virtualKey)
        {
            string? name = Enum.GetName(typeof(Keys), (Keys)(int)virtualKey);
            return string.IsNullOrEmpty(name) ? virtualKey.ToString() : name!;
        }

        /// <summary>两个组合是否相等（用于「两个热键不能撞车」的校验）。</summary>
        public static bool IsSameCombo(string? a, string? b)
        {
            if (!TryParse(a, out uint modA, out uint keyA)) return false;
            if (!TryParse(b, out uint modB, out uint keyB)) return false;
            return modA == modB && keyA == keyB;
        }
    }
}
