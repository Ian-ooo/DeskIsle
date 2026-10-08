using System;
using System.Collections.Generic;
using System.Windows.Interop;

namespace DeskIsle.Native
{
    /// <summary>
    /// 全局热键管理（Win32 <c>RegisterHotKey</c>）。
    ///
    /// **按槽位 id 分派** —— 与 mac 端 <c>EventHotKeyID.id</c> 的思路一致：
    /// 每个槽位有固定 id 与独立回调，新增热键必须用新 id 并在分派处加分支，
    /// 否则两个热键会互相顶掉（同一个 id 只有一个注册生效）。
    ///
    /// 修复的历史缺陷：此前整个应用只支持**一个**热键，且初始化时**硬编码** Alt+D，
    /// 用户在设置里录制的自定义热键保存了却不生效。现在改为按槽位注册，
    /// 「注册成什么组合」由调用方按配置传进来。
    /// </summary>
    public sealed class HotKeyManager : IDisposable
    {
        /// <summary>显隐分区（对应 mac 端的 id=1）</summary>
        public const int SlotToggleHide = 9001;

        /// <summary>全局搜索（对应 mac 端的 id=2）</summary>
        public const int SlotGlobalSearch = 9002;

        private HwndSource? _source;
        private IntPtr _hwnd;
        private readonly Dictionary<int, Action> _callbacks = new();
        private readonly HashSet<int> _registered = new();

        public void Initialize(HwndSource source)
        {
            _source = source;
            _hwnd = source.Handle;
            _source.AddHook(HwndHook);
        }

        /// <summary>为某个槽位设置回调（可在注册之前随时设置）。</summary>
        public void SetCallback(int slotId, Action callback)
        {
            _callbacks[slotId] = callback;
        }

        /// <summary>
        /// 注册（或改写）某个槽位的热键。
        /// </summary>
        /// <returns>false 表示注册失败 —— 最常见的原因是组合已被系统或其他应用独占。</returns>
        public bool Register(int slotId, uint modifiers, uint key)
        {
            if (_hwnd == IntPtr.Zero) return false;
            Unregister(slotId);

            bool ok = Win32.RegisterHotKey(_hwnd, slotId, modifiers | Win32.MOD_NOREPEAT, key);
            if (ok) _registered.Add(slotId);
            return ok;
        }

        public void Unregister(int slotId)
        {
            if (_hwnd != IntPtr.Zero && _registered.Contains(slotId))
            {
                Win32.UnregisterHotKey(_hwnd, slotId);
                _registered.Remove(slotId);
            }
        }

        /// <summary>注销全部（退出时调用）。</summary>
        public void UnregisterAll()
        {
            foreach (var id in new List<int>(_registered))
            {
                Unregister(id);
            }
        }

        private IntPtr HwndHook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
        {
            if (msg == Win32.WM_HOTKEY)
            {
                int id = wParam.ToInt32();
                if (_callbacks.TryGetValue(id, out var cb))
                {
                    cb?.Invoke();
                    handled = true;
                }
            }
            return IntPtr.Zero;
        }

        public void Dispose()
        {
            UnregisterAll();
            _callbacks.Clear();
            if (_source != null)
            {
                _source.RemoveHook(HwndHook);
                _source = null;
            }
        }
    }
}
