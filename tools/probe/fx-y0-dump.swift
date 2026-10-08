import Cocoa
import CoreGraphics

// 诊断工具：列出所有「可能命中全屏几何判据」的窗口，并逐项标注判定结果。
//
// 用法：./fx-y0-dump <selfPID> [循环次数] [间隔毫秒]
// 输出每轮一行摘要 + 每轮的窗口明细（只打印 yOK=true 或 big 的候选，避免刷屏）。

typealias CGSConnectionID = UInt32
let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
func sym<T>(_ n: String, as: T.Type) -> T? {
    guard let h = skyLight, let p = dlsym(h, n) else { return nil }
    return unsafeBitCast(p, to: T.self)
}

let args = CommandLine.arguments
let selfPID = pid_t(Int(args.count > 1 ? args[1] : "-1") ?? -1)
let loops = Int(args.count > 2 ? args[2] : "1") ?? 1
let gapMs = Int(args.count > 3 ? args[3] : "100") ?? 100

let ignoredOwners: Set<String> = [
    "Dock", "Window Server", "Finder", "访达", "systemuiserver", "SystemUIServer",
    "loginwindow", "墙纸", "控制中心", "通知中心", "功能栏", "聚焦",
    "TextInputSwitcher", "TextInputMenuAgent", "简体中文输入方式",
]

/// 只报告**主显示器**（与探测器一致）：当前 space id/type + 全部 space 列表。
func state() -> String {
    guard let mainConnFn = sym("CGSMainConnectionID", as: (@convention(c) () -> CGSConnectionID).self),
          let copyFn = sym("CGSCopyManagedDisplaySpaces", as: (@convention(c) (CGSConnectionID) -> CFArray?).self),
          let displays = copyFn(mainConnFn()) as? [[String: Any]], !displays.isEmpty else { return "cgs=na" }
    let mainUUID = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID())
        .flatMap { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String? }
    let d = mainUUID.flatMap { u in displays.first { ($0["Display Identifier"] as? String) == u } } ?? displays[0]
    let cur = d["Current Space"] as? [String: Any] ?? [:]
    let ids = (d["Spaces"] as? [[String: Any]] ?? []).map { "\($0["ManagedSpaceID"] as? Int ?? -1):\($0["type"] as? Int ?? -1)" }.joined(separator: ",")
    return "main cur=(id=\(cur["ManagedSpaceID"] as? Int ?? -1) type=\(cur["type"] as? Int ?? -1)) all=[\(ids)]"
}

func ownerPIDs() -> Set<Int> {
    guard let mainConnFn = sym("CGSMainConnectionID", as: (@convention(c) () -> CGSConnectionID).self),
          let copyFn = sym("CGSCopyManagedDisplaySpaces", as: (@convention(c) (CGSConnectionID) -> CFArray?).self),
          let displays = copyFn(mainConnFn()) as? [[String: Any]],
          let mainUUID = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID())
            .flatMap({ CFUUIDCreateString(nil, $0.takeRetainedValue()) as String? }) else { return [] }
    let display = displays.first { ($0["Display Identifier"] as? String) == mainUUID } ?? displays[0]
    var pids: Set<Int> = []
    for sp in (display["Spaces"] as? [[String: Any]] ?? []) where (sp["type"] as? Int ?? -1) == 4 {
        if let p = sp["pid"] as? Int, p > 0 { pids.insert(p) }
    }
    return pids
}

let db = CGDisplayBounds(CGMainDisplayID())
let fsPids = ownerPIDs()

for round in 1...max(1, loops) {
    let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    var lines: [String] = []
    var verdict = "none"
    var shapeOnly = 0
    for info in list {
        guard let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != selfPID else { continue }
        guard (info[kCGWindowLayer as String] as? Int) == 0 else { continue }
        let owner = info[kCGWindowOwnerName as String] as? String ?? ""
        if ignoredOwners.contains(owner) { continue }
        guard let b = info[kCGWindowBounds as String] as? [String: Double],
              let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"] else { continue }
        let onscreen = (info[kCGWindowIsOnscreen as String] as? Bool) ?? false
        let xOK = abs(x - Double(db.origin.x)) < 2
        let yOK = abs(y - Double(db.origin.y)) < 2
        let big = h > 100 && w >= db.width * 0.5
        let fsOwned = fsPids.contains(Int(pid))
        // 只打印「有嫌疑」的：贴顶且够大（其余明显无关）
        guard yOK && big else { continue }
        lines.append("    \(owner)(pid=\(pid)) \(Int(x)),\(Int(y)) \(Int(w))x\(Int(h)) onscreen=\(onscreen) xOK=\(xOK) yOK=\(yOK) big=\(big) fsOwned=\(fsOwned)")
        // 与探测器完全一致的判定：必须 onscreen
        if onscreen && xOK && yOK && big && fsOwned { verdict = "MATCH" }
        else if onscreen && yOK && big && fsOwned && verdict == "none" { verdict = "sliding" }
        // 形状命中但被 onscreen 拦下 —— 这类窗口是潜在的「假阳性来源」
        if !onscreen && xOK && yOK && big && fsOwned { shapeOnly += 1 }
    }
    print("#\(round) t=\(Int(Date().timeIntervalSince1970 * 1000) % 100000) verdict=\(verdict) shapeOnlyOffscreen=\(shapeOnly) fsPids=\(fsPids.sorted()) db=\(Int(db.origin.x)),\(Int(db.origin.y)) \(Int(db.width))x\(Int(db.height))")
    print("   spaces: \(state())")
    for l in lines { print(l) }
    fflush(stdout)
    if round < loops { usleep(useconds_t(gapMs * 1000)) }
}
