// 客观读出窗口状态：层级(layer) + 是否在当前可见空间上(onscreen)
//
// kCGWindowIsOnscreen 是关键：当某个全屏应用的空间成为活动空间时，
// 位于其它空间 / 未参与该空间的窗口会报告 onscreen=false。
// 这样就能用数据回答「哪些配置的窗口能浮在别的应用全屏空间之上」，
// 而不必靠肉眼判断。
//
// 这些字段（owner pid / window number / layer / onscreen / bounds）
// 不需要屏幕录制权限；只有窗口标题才需要。

import Foundation
import CoreGraphics

var wanted: Set<Int> = []
for arg in CommandLine.arguments.dropFirst() {
    if let v = Int(arg) { wanted.insert(v) }
}

let opts = CGWindowListOption(arrayLiteral: .optionAll)
guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write("probe: CGWindowListCopyWindowInfo failed\n".data(using: .utf8)!)
    exit(1)
}

print("PID\tWIN\tLAYER\tONSCREEN\tOWNER\tBOUNDS")

for w in raw {
    guard let pid = w[kCGWindowOwnerPID as String] as? Int else { continue }
    if !wanted.isEmpty && !wanted.contains(pid) { continue }

    let num = w[kCGWindowNumber as String] as? Int ?? -1
    let layer = w[kCGWindowLayer as String] as? Int ?? -999
    let onscreen = (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
    let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
    let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    let bounds = "\(Int(b["X"] ?? -1)),\(Int(b["Y"] ?? -1)) \(Int(b["Width"] ?? -1))x\(Int(b["Height"] ?? -1))"

    print("\(pid)\t\(num)\t\(layer)\t\(onscreen)\t\(owner)\t\(bounds)")
}
