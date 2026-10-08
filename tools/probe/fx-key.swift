import Cocoa
// 发送按键。用法：./fx-key <keyCode> [cmd] [ctrl] [opt]
let a = CommandLine.arguments
let code = CGKeyCode(Int(a[1]) ?? 0)
var flags: CGEventFlags = []
if a.count > 2 && a[2] == "cmd" { flags.insert(.maskCommand) }
if a.count > 3 && a[3] == "ctrl" { flags.insert(.maskControl) }
if a.count > 4 && a[4] == "opt" { flags.insert(.maskAlternate) }
let src = CGEventSource(stateID: .hidSystemState)
let d = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)!
let u = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)!
d.flags = flags; u.flags = flags
d.post(tap: .cghidEventTap); usleep(40000); u.post(tap: .cghidEventTap)
print("sent key \(code)")
