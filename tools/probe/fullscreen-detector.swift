import Cocoa
import CoreGraphics

// 检测「主显示器当前是否处于另一个应用的全屏 Space」。
//
// 策略：
//   1. 取当前 frontmost application（全局最前置应用）。
//   2. 如果 frontmost 是自己，或者在被排除的宿主/系统应用列表里，直接返回 false。
//   3. 否则检查该 frontmost 应用是否存在一个 onscreen、layer==0、铺满主显示器的窗口。
//      有 → 说明该应用正以原生全屏方式占用了当前 Space。
//
// 参数：
//   --self-pid <pid>          调用者自己的 PID（必须）
//   --ignore-owner-names <n1,n2,...>  额外忽略的 owner 名称（例如开发宿主的窗口）
//   --debug                   打印匹配到的候选窗口，方便调试

let mainID = CGMainDisplayID()
let displayBounds = CGDisplayBounds(mainID)
let displayArea = displayBounds.width * displayBounds.height

var args = CommandLine.arguments
var selfPID: pid_t = -1
var ignoredOwners: Set<String> = ["Dock", "Window Server", "Finder", "systemuiserver", "loginwindow"]
var debug = false

var i = 1
while i < args.count {
    switch args[i] {
    case "--self-pid":
        i += 1
        if i < args.count { selfPID = pid_t(args[i]) ?? -1 }
    case "--ignore-owner-names":
        i += 1
        if i < args.count {
            for name in args[i].split(separator: ",").map(String.init) {
                ignoredOwners.insert(name.trimmingCharacters(in: .whitespaces))
            }
        }
    case "--debug":
        debug = true
    default:
        break
    }
    i += 1
}

if debug {
    print("selfPID=\(selfPID) display=\(displayBounds)")
}

let frontmostApp = NSWorkspace.shared.frontmostApplication
let frontmostPID = frontmostApp?.processIdentifier ?? 0
let frontmostOwner = frontmostApp?.localizedName ?? frontmostApp?.bundleIdentifier ?? ""

if debug {
    print("frontmost app: \(frontmostOwner) pid=\(frontmostPID)")
}

if frontmostPID == selfPID {
    print("false")
    exit(0)
}

if ignoredOwners.contains(frontmostOwner) {
    print("false")
    exit(0)
}

let windowListInfo = CGWindowListCopyWindowInfo(
    [.optionAll],
    kCGNullWindowID
) as? [[String: Any]] ?? []

var detected = false

for info in windowListInfo {
    guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int32,
          ownerPID == frontmostPID else { continue }
    guard let layer = info[kCGWindowLayer as String] as? Int,
          layer == 0 else { continue }
    guard let onscreen = info[kCGWindowIsOnscreen as String] as? Bool,
          onscreen else { continue }
    guard let boundsDict = info[kCGWindowBounds as String] as? [String: Double],
          let x = boundsDict["X"],
          let y = boundsDict["Y"],
          let w = boundsDict["Width"],
          let h = boundsDict["Height"] else { continue }

    let area = w * h
    let coversEnough = area / displayArea > 0.95
    let alignedTopLeft =
        abs(x - Double(displayBounds.origin.x)) < 2 &&
        abs(y - Double(displayBounds.origin.y)) < 2

    if debug {
        let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
        let name = info[kCGWindowName as String] as? String ?? "?"
        print("candidate owner=\(owner) name=\(name) layer=\(layer) bounds=\(Int(x)),\(Int(y)) \(Int(w))x\(Int(h)) covers=\(coversEnough && alignedTopLeft)")
    }

    if alignedTopLeft && coversEnough {
        detected = true
        break
    }
}

print(detected ? "true" : "false")
