import Cocoa

// 尝试模拟 macOS 的「切换桌面 Space」操作：Control + 方向键。
// 若进程没有辅助功能权限，事件会被系统丢弃（不报错），因此需要外部用探测器判定是否真的切了 Space。
// 用法：./fx-switch-space right 3   （向右切 3 次，间隔 2 秒）

let args = CommandLine.arguments
let dir = args.count > 1 ? args[1] : "right"
let times = args.count > 2 ? (Int(args[2]) ?? 1) : 1

// keyCode: 123 = Left, 124 = Right
let keyCode: CGKeyCode = (dir == "left") ? 123 : 124

func postCtrlKey(_ code: CGKeyCode) {
    let src = CGEventSource(stateID: .hidSystemState)
    guard let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true),
          let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false) else {
        print("event create failed")
        return
    }
    down.flags = .maskControl
    up.flags = .maskControl
    down.post(tap: .cghidEventTap)
    usleep(30000)
    up.post(tap: .cghidEventTap)
}

print("posting Ctrl+\(dir) x\(times)")
for i in 1...times {
    postCtrlKey(keyCode)
    print("posted #\(i)")
    sleep(2)
}
print("done")
