import Cocoa

// 发送 ⌃⌘F（切换前台窗口的全屏状态），用于受控实验。
// keyCode 3 = F
let src = CGEventSource(stateID: .hidSystemState)
guard let down = CGEvent(keyboardEventSource: src, virtualKey: 3, keyDown: true),
      let up = CGEvent(keyboardEventSource: src, virtualKey: 3, keyDown: false) else {
    print("event create failed"); exit(1)
}
down.flags = [.maskControl, .maskCommand]
up.flags = [.maskControl, .maskCommand]
down.post(tap: .cghidEventTap)
usleep(40000)
up.post(tap: .cghidEventTap)
print("posted ⌃⌘F")
