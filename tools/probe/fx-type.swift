import Cocoa

// 向前台应用输入文本（逐字符设置 Unicode 字符串）。
//
// 为什么不用 fx-key 的虚拟键码：CGEvent 只带 keycode 时，事件没有 characters 载荷，
// NSTextView 收到 keyDown 却无字符可插入（表现就是「打了字但没出现」）。
// 正确做法：keyboardSetUnicodeString。
//
// 用法：./fx-type "你好 native"

let args = CommandLine.arguments
let text = args.count > 1 ? args[1] : "test"
let src = CGEventSource(stateID: .hidSystemState)

for ch in text.unicodeScalars {
    let str = String(ch)
    let arr = Array(str.utf16)
    guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
          let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { continue }
    down.keyboardSetUnicodeString(stringLength: arr.count, unicodeString: arr)
    up.keyboardSetUnicodeString(stringLength: arr.count, unicodeString: arr)
    down.post(tap: .cghidEventTap)
    usleep(20000)
    up.post(tap: .cghidEventTap)
    usleep(20000)
}
print("typed: \(text)")
