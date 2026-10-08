import Cocoa
import CoreGraphics

// 比较三个信号的翻转时机与可信度：
//   A) CGSCopyManagedDisplaySpaces 里主屏的 "Current Space"（现在探测器用的权威判据）
//   B) SLSGetActiveSpace（系统认为的活跃 space id）
//   C) 几何判据：是否存在「位于主屏原点、够大、且 owner 拥有 type=4 Space」的窗口，
//      并额外报告该窗口的 window id 与它所属的 space（CGSCopySpacesForWindows），
//      以及该 space 的 type。
//
// 用法：./fx-space-timing <轮数> <间隔ms>

typealias CGSConnectionID = UInt32
let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
func sym<T>(_ n: String, as: T.Type) -> T? {
    guard let h = skyLight, let p = dlsym(h, n) else { return nil }
    return unsafeBitCast(p, to: T.self)
}
func cid() -> CGSConnectionID? {
    sym("CGSMainConnectionID", as: (@convention(c) () -> CGSConnectionID).self)?()
}
func displays() -> [[String: Any]] {
    guard let c = cid(),
          let f = sym("CGSCopyManagedDisplaySpaces", as: (@convention(c) (CGSConnectionID) -> CFArray?).self),
          let a = f(c) as? [[String: Any]] else { return [] }
    return a
}
func mainDisplay() -> [String: Any]? {
    let ds = displays()
    guard !ds.isEmpty else { return nil }
    let uuid = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID())
        .flatMap { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String? }
    return uuid.flatMap { u in ds.first { ($0["Display Identifier"] as? String) == u } } ?? ds[0]
}
func activeSpace() -> Int {
    guard let c = cid(),
          let f = sym("SLSGetActiveSpace", as: (@convention(c) (CGSConnectionID) -> UInt64).self) else { return -1 }
    return Int(f(c))
}
/// 给定窗口 id 求出它所属的 space id 集合。
func spacesForWindows(_ wids: [Int]) -> [Int] {
    guard let c = cid(), !wids.isEmpty,
          let f = sym("CGSCopySpacesForWindows", as: (@convention(c) (CGSConnectionID, Int, CFArray) -> CFArray?).self) else { return [] }
    let arr = wids.map { NSNumber(value: $0) } as CFArray
    guard let out = f(c, 0x7, arr) as? [Int] else { return [] }
    return out
}

let args = CommandLine.arguments
let rounds = Int(args.count > 1 ? args[1] : "200") ?? 200
let gap = Int(args.count > 2 ? args[2] : "40") ?? 40
let selfPID = pid_t(-1)

let db = CGDisplayBounds(CGMainDisplayID())
// 每次循环重新取，保证 Space 列表变化被看到
var printed = 0
let t0 = Date().timeIntervalSince1970

for _ in 0..<rounds {
    let md = mainDisplay()
    let cur = md?["Current Space"] as? [String: Any] ?? [:]
    let curID = cur["ManagedSpaceID"] as? Int ?? -1
    let curType = cur["type"] as? Int ?? -1
    let spaces = md?["Spaces"] as? [[String: Any]] ?? []
    let fsWids = spaces.filter { ($0["type"] as? Int ?? -1) == 4 }.map { $0["fs_wid"] as? Int ?? -1 }
    let fsPids = Set(spaces.filter { ($0["type"] as? Int ?? -1) == 4 }.compactMap { $0["pid"] as? Int })

    // 几何：找贴原点、够大、属主拥有全屏 space 的窗口
    let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    var hits: [String] = []
    for info in list {
        guard let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != selfPID else { continue }
        guard (info[kCGWindowLayer as String] as? Int) == 0 else { continue }
        guard fsPids.contains(Int(pid)) else { continue }
        guard let b = info[kCGWindowBounds as String] as? [String: Double],
              let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"] else { continue }
        guard abs(x - Double(db.origin.x)) < 2, abs(y - Double(db.origin.y)) < 2,
              h > 100, w >= db.width * 0.5 else { continue }
        let wid = info[kCGWindowNumber as String] as? Int ?? -1
        let on = (info[kCGWindowIsOnscreen as String] as? Bool) ?? false
        let owner = info[kCGWindowOwnerName as String] as? String ?? ""
        let ws = spacesForWindows([wid])
        hits.append("\(owner)#\(wid) onscreen=\(on) isFsWid=\(fsWids.contains(wid)) inSpaces=\(ws)")
    }
    let t = Int((Date().timeIntervalSince1970 - t0) * 1000)
    // 只在「有命中」或「活跃/当前 space 变化」时打印，避免刷屏
    let line = "t=\(t) managedCur=\(curID)(type=\(curType)) active=\(activeSpace()) fsWids=\(fsWids.sorted()) hits=[\(hits.joined(separator: " | "))]"
    print(line)
    fflush(stdout)
    printed += 1
    usleep(useconds_t(gap * 1000))
}
