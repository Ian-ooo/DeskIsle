using System;
using System.Linq;
using System.Runtime.InteropServices;
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
    /// ⚠️ Screen.WorkingArea 是**设备像素**，而 WPF 的 Left/Top/Width/Height 是**逻辑单位**。
    /// 换算以「这块屏上的窗口」为锚点（它的 Left 与 GetWindowRect 是同一矩形的两种单位）。
    /// TransformFromDevice 只是缩放、没有平移，只在锚点不可用时兜底。
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
            // 用「这块屏上的窗口」做锚点：它的 Left/Top 已经是 WPF 逻辑坐标，
            // GetWindowRect 是同一窗口的设备像素。两者相除得到的比例，能把工作区
            // 换到和 Window.Left/Top 相同的坐标系。
            //
            // ⚠️ 不能拿 TransformFromDevice 去乘工作区的绝对原点。那条矩阵只是
            // 「本屏 DPI 的缩放」，没有平移。主屏在 (0,0) 时碰巧正确；副屏、或者
            // 两块屏缩放不一样时，原点会被缩到错误的位置，对齐结果整块叠到另一块屏上。
            if (reference is Window anchor
                && anchor.ActualWidth > 1 && anchor.ActualHeight > 1
                && TryMapWorkAreaFromAnchor(anchor, wa, out var mapped))
            {
                return mapped;
            }

            var matrix = Matrix.Identity;
            if (reference != null)
            {
                var src = PresentationSource.FromVisual(reference);
                if (src?.CompositionTarget != null)
                    matrix = src.CompositionTarget.TransformFromDevice;
            }
            var topLeft = matrix.Transform(new Point(wa.Left, wa.Top));
            var size = matrix.Transform(new Vector(wa.Width, wa.Height));
            return new Rect(topLeft, size);
        }

        /// <summary>
        /// 用锚点窗口把设备像素工作区换成 WPF 逻辑坐标。
        /// 锚点必须就在目标屏上，比例才是这块屏自己的 DPI。
        /// </summary>
        private static bool TryMapWorkAreaFromAnchor(Window anchor, System.Drawing.Rectangle wa, out Rect dip)
        {
            dip = Rect.Empty;
            var hwnd = new WindowInteropHelper(anchor).Handle;
            if (hwnd == IntPtr.Zero || !GetWindowRect(hwnd, out var wr)) return false;
            if (!LayoutEngine.TryMapRectFromAnchor(
                    anchor.Left, anchor.Top, anchor.ActualWidth, anchor.ActualHeight,
                    wr.Left, wr.Top, wr.Right, wr.Bottom,
                    wa.Left, wa.Top, wa.Right, wa.Bottom,
                    out double x, out double y, out double w, out double h))
                return false;
            dip = new Rect(x, y, w, h);
            return true;
        }

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

        [StructLayout(LayoutKind.Sequential)]
        private struct RECT
        {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
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
