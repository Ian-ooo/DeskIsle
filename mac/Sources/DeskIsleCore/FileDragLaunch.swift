import Foundation

// MARK: - 拖出：这一次鼠标移动到底该不该发起拖拽（纯逻辑，两端同源）

/// 一次「按住左键拖动」是否满足发起拖出的全部条件。
///
/// 为什么把这么小的判断也抽成纯函数：它看着只是「位移够不够阈值」，
/// 但**漏判一条就会拖错文件**，而拖错文件的后果是**用户以为自己在拖 A、实际搬走的是 B** ——
/// 分区是真实文件夹的视图，搬错位置等于文件凭空消失。这种毛病没法靠肉眼回归，只能靠断言钉住。
///
/// ⚠️⚠️ **最容易漏的一条是 `eventWindowID == ownWindowID`**（本次事故的根因）：
/// mac 端每个文件行都装了一个 `NSEvent.addLocalMonitorForEvents` —— 它是**应用级**的，
/// 任何窗口的鼠标事件都会送到每一个文件行上。原本的判据只有「按下点落在本行的矩形内」，
/// 而矩形是用**事件所在窗口**的坐标算的，于是：
/// 在 A 窗口按下，B 窗口里**恰好同坐标**的那一行也认为自己被按下了。
/// 两个分区窗口都是同一种列表布局，行高列宽一致 → 坐标撞车是**大概率**，不是偶发。
/// 监视器回调的执行顺序是「后安装的先跑」，所以抢到的是 B 窗口那行 ——
/// 用户拖的是 A 窗口的文件，被搬走的却是 B 窗口里同位置的那个。
///
/// Windows 端（`Services/FileDragLaunch.cs`）用路由事件，天然不会跨窗口，
/// 但判据**照抄同一套**，免得哪天谁给 Windows 也加个全局钩子时重新踩一遍。
public struct DragLaunchInput {
    /// 本次事件来自哪个窗口。
    public var eventWindowID: Int
    /// 本文件行所在窗口（`NSView.window?.windowNumber`）。**不在任何窗口里时为 nil**。
    public var ownWindowID: Int?
    /// 最近一次左键按下时记录的窗口。
    public var downWindowID: Int
    /// 最近一次按下点是否落在本行的矩形内。
    public var downInsideRow: Bool
    /// 本次按下是否已经发起过会话（一次按下只许发起一次）。
    public var alreadyBegan: Bool
    /// 是否已有别的文件行发起了会话（macOS 一次只能有一个拖拽会话）。
    public var anotherSessionActive: Bool
    /// 相对按下点的位移。
    public var dx: Double
    public var dy: Double

    public init(eventWindowID: Int,
                ownWindowID: Int?,
                downWindowID: Int,
                downInsideRow: Bool,
                alreadyBegan: Bool,
                anotherSessionActive: Bool,
                dx: Double,
                dy: Double) {
        self.eventWindowID = eventWindowID
        self.ownWindowID = ownWindowID
        self.downWindowID = downWindowID
        self.downInsideRow = downInsideRow
        self.alreadyBegan = alreadyBegan
        self.anotherSessionActive = anotherSessionActive
        self.dx = dx
        self.dy = dy
    }
}

public enum FileDragLaunch {

    /// 位移阈值的**平方**（4pt，与系统拖拽阈值同量级）：手抖一下不该变成拖拽。
    public static let threshold2: Double = 16

    /// 是否发起拖拽。
    ///
    /// 六条缺一不可，顺序即从「最便宜 / 最能排除误伤」到「最具体」：
    /// 1. 本行得挂在某个窗口上（已被移除的视图不该响应任何事件）；
    /// 2. 事件必须来自**本行所在窗口**（见类型注释里的事故）；
    /// 3. 事件窗口必须与按下时记录的窗口一致（按下与拖动不在同一窗口 = 跨窗口操作，不算）；
    /// 4. 按下点必须落在本行内（只有被按住的那一行能发起）；
    /// 5. 一次按下只发起一次，且全局同时只有一个会话；
    /// 6. 位移超过阈值。
    public static func shouldBegin(_ i: DragLaunchInput) -> Bool {
        guard let own = i.ownWindowID else { return false }
        guard i.eventWindowID == own else { return false }
        guard i.eventWindowID == i.downWindowID else { return false }
        guard i.downInsideRow else { return false }
        guard !i.alreadyBegan, !i.anotherSessionActive else { return false }
        return i.dx * i.dx + i.dy * i.dy > threshold2
    }
}
