import Cocoa

// 模拟触控板「双指左右滑动」来切换 Space（带相位，和真实手势一致）。
//
// 为什么需要它：合成 ⌃←/→ 在多显示器下会被系统忽略；而私有 API 切 Space 是无动画的，
// 无法复现「动画期间」的行为（动画期间 macOS 会把相邻 Space 的窗口也标记为 onscreen）。
//
// 用法：./fx-swipe <left|right> [总位移] [步数]

let args = CommandLine.arguments
let dir = args.count > 1 ? args[1] : "right"
let total = Double(args.count > 2 ? args[2] : "600") ?? 600
let steps = Int(args.count > 3 ? args[3] : "24") ?? 24

// 手势方向与「下一个 Space」的关系：为了切到相邻 Space，手指需要往相反方向滑。
let sign: Double = (dir == "left") ? -1 : 1

let src = CGEventSource(stateID: .hidSystemState)

func post(phase: Int64, deltaX: Double) {
    guard let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel,
                          wheelCount: 2, wheel1: 0, wheel2: Int32(deltaX), wheel3: 0) else { return }
    e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
    e.post(tap: .cghidEventTap)
}

// phase: 1=began 2=changed 4=ended
post(phase: 1, deltaX: 0)
usleep(20000)
let per = total / Double(steps)
for i in 0..<steps {
    post(phase: 2, deltaX: per * sign)
    // 前半程加速、后半程减速，模仿真实手势
    let t = Double(i) / Double(max(1, steps - 1))
    let dur = 6000.0 + 4000.0 * (1.0 - t)
    usleep(useconds_t(dur))
}
post(phase: 4, deltaX: 0)
print("swipe \(dir) total=\(Int(total)) steps=\(steps) posted")
