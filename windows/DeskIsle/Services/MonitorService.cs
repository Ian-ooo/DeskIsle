using System;
using System.Linq;
using System.Windows;
using System.Windows.Forms;
using System.Windows.Interop;
using System.Windows.Media;

namespace DeskIsle.Services
{
    /// <summary>
    /// 多显示器支持：把窗口/分区归属到具体显示器，并做「设备像素 ↔ WPF 逻辑单位」换算。
    ///
    /// 历史问题：全部布局都用 <c>SystemParameters.WorkArea</c>（恒等于**主屏**工作区），
    /// 于是多显示器下所有分区都堆在主屏，点副屏的按钮也会跑到主屏弹窗。
    /// 改造后每个分区以「自己窗口所在显示器」为坐标系，各屏独立排版与显隐。
    ///
    /// ⚠️ Screen.WorkingArea 是**设备像素**，而 WPF 的 Left/Top/Width/Height 是**逻辑单位**，
    /// PerMonitorV2 下不同显示器缩放不同，必须经 CompositionTarget.TransformFromDevice 换算。
    /// </summary>
    public static class MonitorService
    {
        /// <summary>窗口当前所在显示器。</summary>
        public static Screen ScreenOf(Window window)
        {
            var handle = new WindowInteropHelper(window).Handle;
            if (handle != IntPtr.Zero)
            {
                return Screen.FromHandle(handle);
            }
            return Screen.PrimaryScreen ?? Screen.AllScreens[0];
        }

        /// <summary>光标所在显示器 —— 用户交互发生的屏（弹窗/新建分区以此为准）。</summary>
        public static Screen ScreenUnderCursor()
        {
            return Screen.FromPoint(Cursor.Position);
        }

        /// <summary>所有已连接显示器。</summary>
        public static Screen[] AllScreens() => Screen.AllScreens;

        /// <summary>
        /// 指定显示器的工作区，换算成 WPF 逻辑单位。
        /// <paramref name="reference"/> 用于取得该屏的 DPI 换算矩阵，传该屏上的任意可视元素即可。
        /// </summary>
        public static Rect WorkingAreaDIP(Screen screen, Visual? reference = null)
        {
            var wa = screen.WorkingArea;   // 设备像素
            var matrix = Matrix.Identity;
            if (reference != null)
            {
                var src = PresentationSource.FromVisual(reference);
                if (src?.CompositionTarget != null)
                {
                    matrix = src.CompositionTarget.TransformFromDevice;
                }
            }
            var topLeft = matrix.Transform(new Point(wa.Left, wa.Top));
            var bottomRight = matrix.Transform(new Point(wa.Right, wa.Bottom));
            return new Rect(topLeft, bottomRight);
        }

        /// <summary>显示器标识：用 DeviceName（如 \\.\DISPLAY1），在同一次会话内稳定。</summary>
        public static string DeviceIdOf(Screen screen) => screen.DeviceName;

        /// <summary>所有显示器的 DeviceName 集合（用于清理失效的按屏状态）。</summary>
        public static string[] AliveDeviceIds() => Screen.AllScreens.Select(s => s.DeviceName).ToArray();

        /// <summary>主显示器。</summary>
        public static Screen PrimaryScreen() => Screen.PrimaryScreen ?? Screen.AllScreens[0];

        /// <summary>按 DeviceName 查显示器。</summary>
        public static Screen? ScreenFromDeviceId(string deviceId) =>
            Screen.AllScreens.FirstOrDefault(s => s.DeviceName.Equals(deviceId, StringComparison.OrdinalIgnoreCase));
    }
}
