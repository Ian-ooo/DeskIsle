import Cocoa
import CoreGraphics

// 通过私有 SkyLight API 读取/切换某个显示器的当前 Space。
//
// 用途：合成 ⌃←/→ 在多显示器 + 「显示器各有独立 Space」下不可靠（系统会忽略合成事件），
// 这个工具可以直接指定 space id 切换，用于自动化复现与回归测试。
//
// 用法：
//   ./fx-setspace list                 列出所有显示器的 Space（含 id / type / 是否当前）
//   ./fx-setspace set <spaceID>        把包含该 space 的显示器切到它

typealias CGSConnectionID = UInt32
let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
func sym<T>(_ n: String, as: T.Type) -> T? {
    guard let h = skyLight, let p = dlsym(h, n) else { return nil }
    return unsafeBitCast(p, to: T.self)
}

func mainConn() -> CGSConnectionID? {
    guard let f = sym("CGSMainConnectionID", as: (@convention(c) () -> CGSConnectionID).self) else { return nil }
    return f()
}

func displays() -> [[String: Any]] {
    guard let cid = mainConn(),
          let f = sym("CGSCopyManagedDisplaySpaces", as: (@convention(c) (CGSConnectionID) -> CFArray?).self),
          let arr = f(cid) as? [[String: Any]] else { return [] }
    return arr
}

let args = CommandLine.arguments
let cmd = args.count > 1 ? args[1] : "list"

if cmd == "list" {
    for d in displays() {
        let uuid = d["Display Identifier"] as? String ?? "?"
        let cur = d["Current Space"] as? [String: Any] ?? [:]
        print("display \(uuid) current=\(cur["ManagedSpaceID"] as? Int ?? -1)")
        for sp in (d["Spaces"] as? [[String: Any]] ?? []) {
            let id = sp["ManagedSpaceID"] as? Int ?? -1
            let type = sp["type"] as? Int ?? -1
            let pid = sp["pid"] as? Int ?? -1
            let mark = (id == (cur["ManagedSpaceID"] as? Int ?? -1)) ? "  ← 当前" : ""
            print("   space \(id) type=\(type) pid=\(pid)\(mark)")
        }
    }
    // 顺带探测可用符号
    for name in ["SLSManagedDisplaySetCurrentSpace", "CGSSetCurrentSpace", "SLSGetActiveSpace", "SLSCopyManagedDisplaySpaces"] {
        print("symbol \(name): \(sym(name, as: UnsafeRawPointer.self) != nil ? "OK" : "MISS")")
    }
    exit(0)
}

if cmd == "set", args.count > 2, let target = Int(args[2]) {
    typealias SetFn = @convention(c) (CGSConnectionID, CFString, UInt64) -> Int32
    guard let cid = mainConn(),
          let f = sym("SLSManagedDisplaySetCurrentSpace", as: SetFn.self) else {
        print("MISS: SLSManagedDisplaySetCurrentSpace")
        exit(1)
    }
    for d in displays() {
        let spaces = d["Spaces"] as? [[String: Any]] ?? []
        guard spaces.contains(where: { ($0["ManagedSpaceID"] as? Int) == target }),
              let uuid = d["Display Identifier"] as? String else { continue }
        let r = f(cid, uuid as CFString, UInt64(target))
        print("set display \(uuid) → space \(target), ret=\(r)")
        exit(0)
    }
    print("找不到包含 space \(target) 的显示器")
    exit(1)
}

print("用法: fx-setspace list | set <spaceID>")
