import Cocoa
import CoreGraphics

// 交叉诊断：对「当前活动 Space」同时给出
//   (a) 私有 CGS API 给出的类型（4 = 全屏 Space）与全屏窗口 ID / 所属 pid
//   (b) 该全屏窗口在 CGWindowList 里的几何与 onscreen 标志
//   (c) 现有几何判据（菜单栏区域侵入）的结论
// 用法：./fx-cross-check           一次
//      ./fx-cross-check loop 6     每 1.5 秒一次，共 6 次（配合 Ctrl+←/→ 切 Space）

typealias CGSConnectionID = UInt32
typealias CGSSpaceID = UInt64

guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW) else {
    print("FAIL: SkyLight"); exit(1)
}
func sym<T>(_ name: String, as: T.Type) -> T? {
    guard let p = dlsym(h, name) else { return nil }
    return unsafeBitCast(p, to: T.self)
}
typealias MainConnFn = @convention(c) () -> CGSConnectionID
typealias CopyManagedDisplaySpacesFn = @convention(c) (CGSConnectionID) -> CFArray?

guard let mainConnFn = sym("CGSMainConnectionID", as: MainConnFn.self),
      let spacesFn = sym("CGSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpacesFn.self) else {
    print("FAIL: 关键符号缺失"); exit(1)
}
let cid = mainConnFn()

let mainDisplay = CGDisplayBounds(CGMainDisplayID())

func currentSpaceInfo() -> (type: Int, fsWid: Int, pid: Int)? {
    guard let arr = spacesFn(cid) as? [[String: Any]],
          let first = arr.first,
          let cur = first["Current Space"] as? [String: Any] else { return nil }
    return (
        cur["type"] as? Int ?? -1,
        cur["fs_wid"] as? Int ?? -1,
        cur["pid"] as? Int ?? -1
    )
}

func geometryVerdict() -> String {
    let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    var hit = ""
    for info in list {
        let layer = info[kCGWindowLayer as String] as? Int ?? -1
        guard layer == 0 else { continue }
        guard let on = info[kCGWindowIsOnscreen as String] as? Bool, on else { continue }
        let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
        guard !["Dock", "Window Server", "Finder", "访达", "WorkBuddy"].contains(owner) else { continue }
        let b = info[kCGWindowBounds as String] as? [String: Double] ?? [:]
        let x = b["X"] ?? 0, y = b["Y"] ?? 0, w = b["Width"] ?? 0, hgt = b["Height"] ?? 0
        if abs(x) < 2 && abs(y) < 2 && hgt > 100 && w > mainDisplay.width * 0.5 {
            hit = "\(owner) \(Int(w))x\(Int(hgt))"
        }
    }
    return hit.isEmpty ? "false" : "true(\(hit))"
}

func report(_ tag: String) {
    let sid = currentSpaceInfo()
    let typeStr = sid.map { $0.type == 4 ? "4(全屏Space)" : "\($0.type)" } ?? "?"
    var fsDesc = "无"
    if let s = sid, s.fsWid > 0 {
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        if let w = list.first(where: { ($0[kCGWindowNumber as String] as? Int) == s.fsWid }) {
            let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
            let layer = w[kCGWindowLayer as String] as? Int ?? -1
            let on = w[kCGWindowIsOnscreen as String] as? Bool ?? false
            let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
            fsDesc = "id=\(s.fsWid) owner=\(owner) layer=\(layer) onscreen=\(on) bounds=\(Int(b["X"] ?? 0)),\(Int(b["Y"] ?? 0)) \(Int(b["Width"] ?? 0))x\(Int(b["Height"] ?? 0))"
        } else {
            fsDesc = "id=\(s.fsWid) (窗口未在列表中)"
        }
    }
    print("[\(tag)] 活动Space type=\(typeStr) | 全屏窗口: \(fsDesc) | 几何判据=\(geometryVerdict())")
}

if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "loop" {
    let n = CommandLine.arguments.count > 2 ? (Int(CommandLine.arguments[2]) ?? 6) : 6
    for i in 1...n {
        report("样本\(i)")
        if i < n { sleep(1) }
    }
} else {
    report("当前")
}
