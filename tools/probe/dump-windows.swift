import Cocoa
import CoreGraphics

let mainID = CGMainDisplayID()
let displayBounds = CGDisplayBounds(mainID)
print("main display bounds: \(displayBounds)")

let frontmostApp = NSWorkspace.shared.frontmostApplication
print("frontmost: \(frontmostApp?.localizedName ?? "?") pid=\(frontmostApp?.processIdentifier ?? 0)")

let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
print("total windows: \(list.count)")
for info in list {
    guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int32 else { continue }
    let wid = info[kCGWindowNumber as String] as? Int ?? -1
    let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
    let name = info[kCGWindowName as String] as? String ?? ""
    let layer = info[kCGWindowLayer as String] as? Int ?? -1
    let onscreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false
    let b = info[kCGWindowBounds as String] as? [String: Double] ?? [:]
    let rect = "\(Int(b["X"] ?? 0)),\(Int(b["Y"] ?? 0)) \(Int(b["Width"] ?? 0))x\(Int(b["Height"] ?? 0))"
    print("id=\(wid) pid=\(ownerPID) owner=\(owner) layer=\(layer) onscreen=\(onscreen) bounds=\(rect) name=\(name)")
}
