import Cocoa

// 只移动光标、不点击。用于安全地探测命中检测结果（不会误触任何按钮）。
// 关键：必须用 CGWarpMouseCursorPosition 真正挪动硬件光标，
// 单发一个 .mouseMoved 事件并不会改变 screen.getCursorScreenPoint() 的读数。
// 用法：fx-move <x> <y>
let a = CommandLine.arguments
guard a.count >= 3, let x = Double(a[1]), let y = Double(a[2]) else {
    print("usage: fx-move <x> <y>")
    exit(1)
}
let pt = CGPoint(x: x, y: y)
CGAssociateMouseAndMouseCursorPosition(1)
CGWarpMouseCursorPosition(pt)
// 再把位置补发一个移动事件，让应用侧也收到通知
let src = CGEventSource(stateID: .hidSystemState)
let move = CGEvent(mouseEventSource: src, mouseType: .mouseMoved,
                   mouseCursorPosition: pt, mouseButton: .left)
move?.post(tap: .cghidEventTap)
print("warped to \(Int(x)),\(Int(y))")
