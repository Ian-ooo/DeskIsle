import Cocoa
// 双击。用法：./fx-dblclick x y
let a = CommandLine.arguments
let x = CGFloat(Double(a[1]) ?? 0), y = CGFloat(Double(a[2]) ?? 0)
let pt = CGPoint(x: x, y: y)
let src = CGEventSource(stateID: .hidSystemState)
for phase in [true, false, true, false] {
    let e = CGEvent(mouseEventSource: src, mouseType: phase ? .leftMouseDown : .leftMouseUp,
                    mouseCursorPosition: pt, mouseButton: .left)!
    e.post(tap: .cghidEventTap)
    usleep(phase ? 40000 : 120000)  // down 40ms；up 后 120ms 内发起第二次
}
print("double-clicked")
