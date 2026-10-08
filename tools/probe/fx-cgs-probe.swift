import Cocoa
import CoreGraphics

// 探测 macOS 私有 SkyLight/CGS API 是否可用：
// 若能拿到「当前活动 Space ID」与「某个窗口所在的 Space ID」，就可以用
// 「窗口是否位于当前活动 Space」来替代不可靠的 kCGWindowIsOnscreen 标志位。

typealias CGSConnectionID = UInt32
typealias CGSSpaceID = UInt64

guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW) else {
    print("FAIL: SkyLight 打不开")
    exit(1)
}

func sym<T>(_ name: String, as: T.Type) -> T? {
    guard let p = dlsym(h, name) else { return nil }
    return unsafeBitCast(p, to: T.self)
}

typealias MainConnFn = @convention(c) () -> CGSConnectionID
typealias GetActiveSpaceFn = @convention(c) (CGSConnectionID, UnsafeMutablePointer<CGSSpaceID>) -> Int32
typealias CopySpacesForWindowsFn = @convention(c) (CGSConnectionID, UInt32, CFArray) -> CFArray?

guard let mainConnFn = sym("CGSMainConnectionID", as: MainConnFn.self) else {
    print("FAIL: 找不到 CGSMainConnectionID"); exit(1)
}
let cid = mainConnFn()
print("connection id = \(cid)")

var activeSpace: CGSSpaceID = 0
if let fn = sym("CGSGetActiveSpace", as: GetActiveSpaceFn.self) {
    let err = fn(cid, &activeSpace)
    print("CGSGetActiveSpace err=\(err) activeSpace=\(activeSpace)")
} else {
    print("MISS: CGSGetActiveSpace")
}

var displaySpace: CGSSpaceID = 0
if let fn = sym("CGSGetActiveSpaceForDisplay", as: GetActiveSpaceFn.self) {
    let err = fn(cid, &displaySpace)
    print("CGSGetActiveSpaceForDisplay err=\(err) space=\(displaySpace)")
}

let winList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
let ids: [NSNumber] = winList.compactMap { $0[kCGWindowNumber as String] as? NSNumber }
print("窗口总数 \(ids.count)")

if let fn = sym("CGSCopySpacesForWindows", as: CopySpacesForWindowsFn.self) {
    // mask 0x7 = kCGSAllSpacesMask
    if let result = fn(cid, 0x7, ids as CFArray) as? [NSNumber] {
        // 结果与输入等长：第 i 个元素是第 i 个窗口的所有 space（位或）
        print("spaces(位掩码) 前 12 个: \(result.prefix(12).map { "\($0)" }.joined(separator: ","))")
        var matched = 0
        for (i, info) in winList.enumerated() where i < result.count {
            let pid = info[kCGWindowOwnerPID as String] as? Int32 ?? -1
            let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
            let b = info[kCGWindowBounds as String] as? [String: Double] ?? [:]
            let x = Int(b["X"] ?? 0), y = Int(b["Y"] ?? 0), w = Int(b["Width"] ?? 0), h = Int(b["Height"] ?? 0)
            let onscreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false
            if y == 0 && h > 100 && w > 900 {
                print("  顶层窗口 pid=\(pid) owner=\(owner) bounds=\(x),\(y) \(w)x\(h) onscreen=\(onscreen) spaces=\(result[i])")
                matched += 1
            }
        }
        print("候选窗口数 \(matched)")
    } else {
        print("MISS: CGSCopySpacesForWindows 返回异常")
    }
} else {
    print("MISS: CGSCopySpacesForWindows")
}

// 列出所有 space 及其类型（若可用）
typealias CopyManagedDisplaySpacesFn = @convention(c) (CGSConnectionID) -> CFArray?
if let fn = sym("CGSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpacesFn.self),
   let arr = fn(cid) as? [[String: Any]] {
    for display in arr {
        let spaces = display["Spaces"] as? [[String: Any]] ?? []
        let current = display["Current Space"] as? [String: Any]
        let curID = current?["ManagedSpaceID"] as? Int
        print("display '\(display["Display Identifier"] ?? "?")' 当前 space id=\(String(describing: curID)) type=\(String(describing: current?["type"]))")
        for s in spaces {
            let id = s["ManagedSpaceID"] as? Int ?? -1
            let type = s["type"] as? Int ?? -1
            let mark = (id == curID) ? "   ← 当前活动" : ""
            print("   space id=\(id) type=\(type)\(mark)")
        }
        print("   display keys = \(display.keys.sorted())")
        if let c = current { print("   currentSpace keys = \(c.keys.sorted())") }
    }
} else {
    print("MISS: CGSCopyManagedDisplaySpaces")
}
