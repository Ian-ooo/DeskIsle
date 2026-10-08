using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Windows.Threading;
using DeskIsle.Native;

namespace DeskIsle.Services
{
    /// <summary>
    /// 「全屏应用前置时让位」—— 前台窗口占满整个显示器时，自动淡出该屏的分区，
    /// 退出全屏后自动恢复（只恢复**自己隐藏过的**屏，绝不覆盖用户的手动显隐）。
    ///
    /// <b>为什么 Windows 需要这一段而 mac 不需要</b>：mac 上分区跑在桌面层
    /// （<c>CGWindowLevel</c> 低于普通窗口），应用一进全屏 Space，系统自然把分区留在另一个 Space，
    /// 不用做任何事。Windows 没有 Space 概念，且我们的分区窗口是 <c>Topmost</c> 的 ——
    /// 不主动让位就会**盖在全屏视频 / PPT 放映 / 游戏上面**，这是很招人烦的。
    ///
    /// ⚠️ 判定口径刻意选「盖住<b>整个显示器</b>」而不是「盖住工作区」：
    /// 最大化窗口只盖住工作区（任务栏还在），那不算全屏，用户此时**正需要**看到分区。
    /// 真正会盖住整个显示器的是无边框全屏（视频播放器、游戏、PPT 放映），正是要让位的对象。
    /// </summary>
    public sealed class FullScreenGuard
    {
        private readonly Func<string, bool> _isScreenHidden;
        private readonly Action<string, bool> _setPartitionsVisible;

        /// <summary>由本守卫自动隐藏、尚未恢复的屏幕（用来区分「用户自己藏的」和「我们藏的」）。</summary>
        private readonly HashSet<string> _autoHidden = new();

        private readonly DispatcherTimer _timer;
        private string? _lastFullScreenId;

        /// <param name="isScreenHidden">查询某屏当前是否处于隐藏态（配置口径）。</param>
        /// <param name="setPartitionsVisible">显示 / 淡出某屏的分区。</param>
        public FullScreenGuard(Func<string, bool> isScreenHidden, Action<string, bool> setPartitionsVisible)
        {
            _isScreenHidden = isScreenHidden;
            _setPartitionsVisible = setPartitionsVisible;

            // 1s 节拍：比这更快纯属浪费（前台窗口切换没那么频繁），
            // 更慢则会出现「退出全屏后分区要等半天才回来」的迟滞感。
            _timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
            _timer.Tick += (_, _) => Tick();
        }

        public void Start() => _timer.Start();
        public void Stop() => _timer.Stop();

        private void Tick()
        {
            string? fullScreenId;
            try
            {
                fullScreenId = DetectFullScreenMonitorId();
            }
            catch
            {
                // 探测失败就当没有全屏：宁可多显示，也不要把用户的分区莫名其妙藏起来
                fullScreenId = null;
            }

            if (fullScreenId == _lastFullScreenId) return;

            // 上一屏退出全屏 → 恢复（仅当是我们自己藏的）
            if (_lastFullScreenId != null && _autoHidden.Remove(_lastFullScreenId))
            {
                _setPartitionsVisible(_lastFullScreenId, true);
            }
            if (fullScreenId != null && !_isScreenHidden(fullScreenId))
            {
                // 用户已经手动藏了的屏不要再记一笔，否则退出全屏时会把它强行显示出来
                _autoHidden.Add(fullScreenId);
                _setPartitionsVisible(fullScreenId, false);
            }
            _lastFullScreenId = fullScreenId;
        }

        /// <summary>
        /// 返回当前被全屏窗口占据的显示器 Id；没有则返回 null。
        /// </summary>
        public static string? DetectFullScreenMonitorId()
        {
            IntPtr hwnd = Win32.GetForegroundWindow();
            if (hwnd == IntPtr.Zero || !Win32.IsWindowVisible(hwnd)) return null;

            // 自己的窗口不算（顶栏 / 分区 / 弹窗都是 Topmost，很容易成为前台窗口）
            Win32.GetWindowThreadProcessId(hwnd, out uint pid);
            if (pid == Environment.ProcessId) return null;

            // 桌面 / 任务栏 / 壳窗口也不能算：它们的矩形往往就是整个屏
            string cls = Win32.GetWindowClassName(hwnd);
            if (cls == "Progman" || cls == "WorkerW" || cls == "Shell_TrayWnd" ||
                cls == "Shell_SecondaryTrayWnd" || cls == "DesktopWindowXamlSource")
            {
                return null;
            }

            if (!Win32.GetWindowRect(hwnd, out var r)) return null;
            IntPtr hMonitor = Win32.MonitorFromWindow(hwnd, Win32.MONITOR_DEFAULTTONEAREST);
            var mi = new Win32.MONITORINFOEX { cbSize = Marshal.SizeOf(typeof(Win32.MONITORINFOEX)) };
            if (!Win32.GetMonitorInfo(hMonitor, ref mi)) return null;

            // 容差 2px：部分窗口（尤其带 DPI 缩放的）会差 1px，卡太死会永远检测不到
            const int tol = 2;
            bool covers = r.Left <= mi.rcMonitor.Left + tol
                       && r.Top <= mi.rcMonitor.Top + tol
                       && r.Right >= mi.rcMonitor.Right - tol
                       && r.Bottom >= mi.rcMonitor.Bottom - tol;
            if (!covers) return null;

            // ⚠️ `szDevice`（`\\.\DISPLAY1`）必须与 `MonitorService.DeviceIdOf()` 同源，
            // 否则按屏显隐会找不到对应屏 —— 那正是 System.Windows.Forms.Screen.DeviceName 的值。
            return string.IsNullOrEmpty(mi.szDevice) ? null : mi.szDevice;
        }
    }
}
