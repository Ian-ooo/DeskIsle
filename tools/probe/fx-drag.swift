import Cocoa

// 合成鼠标拖拽：按下 → 分步移动 → 抬起。用于验证分区拖动在新架构下是否跟手。
// 用法：fx-drag <x1> <y1> <x2> <y2> [steps]
let a = CommandLine.arguments
guard a.count >= 5, let x1 = Double(a[1]), let y1 = Double(a[2]),
      let x2 = Double(a[3]), let y2 = Double(a[4]) else {
    print("usage: fx-drag <x1> <y1> <x2> <y2> [steps]")
    exit(1)
}
let steps = a.count >= 6 ? (Int(a[5]) ?? 20) : 20
let src = CGEventSource(stateID: .hidSystemState)

func post(_ type: CGEventType, _ p: CGPoint, button: CGMouseButton = .left) {
    let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: button)
    e?.post(tap: .cghidEventTap)
}

post(.mouseMoved, CGPoint(x: x1, y: y1))
usleep(150_000)
post(.leftMouseDown, CGPoint(x: x1, y: y1))
usleep(120_000)

for i in 1...steps {
    let t = Double(i) / Double(steps)
    let p = CGPoint(x: x1 + (x2 - x1) * t, y: y1 + (y2 - y1) * t)
    post(.leftMouseDragged, p)
    usleep(25_000)   // 约 40fps，模拟真实拖动
}

usleep(80_000)
post(.leftMouseUp, CGPoint(x: x2, y: y2))
print("dragged (\(Int(x1)),\(Int(y1))) → (\(Int(x2)),\(Int(y2))) in \(steps) steps")
