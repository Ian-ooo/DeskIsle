namespace DeskIsle.Services
{
    /// <summary>
    /// 一次「按住左键拖动」是否满足发起拖出的全部条件 —— 与 mac
    /// <c>Sources/DeskIsleCore/FileDragLaunch.swift</c> <b>逐条同源</b>。
    /// </summary>
    ///
    /// <remarks>
    /// <para>
    /// 为什么把这么小的判断也抽成纯函数：它看着只是「位移够不够阈值」，
    /// 但<b>漏判一条就会拖错文件</b>，而拖错文件的后果是
    /// 用户以为自己在拖 A、实际搬走的是 B —— 分区是真实文件夹的视图，
    /// 搬错位置等于文件凭空消失。这种毛病没法靠肉眼回归，只能靠断言钉住。
    /// </para>
    ///
    /// <para>
    /// ⚠️⚠️ 最容易漏的一条是 <c>EventWindowID == OwnWindowID</c>：
    /// mac 端每个文件行都装一个<b>应用级</b>鼠标监视器，任何窗口的事件都会送到每一行上，
    /// 原本只判「按下点落在本行矩形内」，而矩形是用<b>事件所在窗口</b>的坐标算的 ——
    /// 于是 A 窗口按下时，B 窗口里恰好同坐标的那一行也认为自己被按住了。
    /// 两个分区窗口的行高列宽一致，坐标撞车是<b>大概率</b>。
    /// 结果是用户拖 A 窗口的文件，被搬走的却是 B 窗口里同位置的另一个（2026-10-01 事故）。
    /// </para>
    ///
    /// <para>
    /// Windows 用路由事件，天然不会跨窗口，这两条窗口判据在这里恒真 ——
    /// 但<b>照抄同一套</b>，免得哪天给 Windows 也加个全局钩子时重新踩一遍。
    /// 真正会在 Windows 上生效的是「按下点必须落在<b>本条目</b>上」：
    /// 按下条目 A 后横向划到条目 B，B 也会收到 <c>PreviewMouseMove</c>，
    /// 不放这条就会把 B 拖出去。
    /// </para>
    /// </remarks>
    public struct DragLaunchInput
    {
        /// <summary>本次事件来自哪个窗口。</summary>
        public int EventWindowID;

        /// <summary>本条目所在窗口。<b>不在任何窗口里时为 null</b>。</summary>
        public int? OwnWindowID;

        /// <summary>最近一次左键按下时记录的窗口。</summary>
        public int DownWindowID;

        /// <summary>最近一次按下时，鼠标是否落在本条目上。</summary>
        public bool DownInsideRow;

        /// <summary>本次按下是否已经发起过会话（一次按下只许发起一次）。</summary>
        public bool AlreadyBegan;

        /// <summary>是否已有别的条目发起了会话（一次只允许一个拖拽会话）。</summary>
        public bool AnotherSessionActive;

        /// <summary>相对按下点的位移。</summary>
        public double Dx;

        /// <summary>相对按下点的位移。</summary>
        public double Dy;
    }

    /// <summary>拖出发起判据（两端同源，见 <see cref="DragLaunchInput"/> 的说明）。</summary>
    public static class FileDragLaunch
    {
        /// <summary>位移阈值的<b>平方</b>（4pt，与系统拖拽阈值同量级）：手抖一下不该变成拖拽。</summary>
        public const double Threshold2 = 16.0;

        /// <summary>
        /// 是否发起拖拽。六条缺一不可，顺序即从「最便宜 / 最能排除误伤」到「最具体」。
        /// </summary>
        public static bool ShouldBegin(DragLaunchInput i)
        {
            if (i.OwnWindowID == null) return false;                 // 1. 本行得挂在某个窗口上
            if (i.EventWindowID != i.OwnWindowID.Value) return false; // 2. 事件必须来自本行所在窗口
            if (i.EventWindowID != i.DownWindowID) return false;      // 3. 按下与拖动要在同一窗口
            if (!i.DownInsideRow) return false;                      // 4. 只有被按住的那一行能发起
            if (i.AlreadyBegan || i.AnotherSessionActive) return false; // 5. 一次按下一次，全局一个
            return i.Dx * i.Dx + i.Dy * i.Dy > Threshold2;           // 6. 位移超过阈值
        }
    }
}
