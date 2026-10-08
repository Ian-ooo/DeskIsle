import Cocoa

// 合成鼠标点击（用于复现 UI 交互）。用法：./fx-click x y [x2 y2 ...]
// 坐标为主显示器逻辑坐标（左上角为原点，与 CGWindowList bounds 同一坐标系）。

func click(x: Double, y: Double) {
    let src = CGEventSource(stateID: .hidSystemState)
    let move = CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)
    let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)
    let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)
    move?.post(tap: .cghidEventTap)
    usleep(120_000)   // 先移动再按下，让 hover 状态生效
    down?.post(tap: .cghidEventTap)
    usleep(60_000)
    up?.post(tap: .cghidEventTap)
    print("clicked (\(Int(x)),\(Int(y)))")
}

let a = CommandLine.arguments
var i = 1
while i + 1 < a.count {
    click(x: Double(a[i]) ?? 0, y: Double(a[i + 1]) ?? 0)
    i += 2
    sleep(1)
}
