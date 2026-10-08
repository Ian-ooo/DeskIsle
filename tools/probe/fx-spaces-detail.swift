import Cocoa
import CoreGraphics

// 严格受控实验的辅助工具：打印所有 Space 的完整字段 + 当前活动 Space 的判定。
typealias CGSConnectionID = UInt32
guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW) else {
    print("FAIL SkyLight"); exit(1)
}
func sym<T>(_ n: String, as: T.Type) -> T? {
    guard let p = dlsym(h, n) else { return nil }
    return unsafeBitCast(p, to: T.self)
}
typealias MainConnFn = @convention(c) () -> CGSConnectionID
typealias CopySpacesFn = @convention(c) (CGSConnectionID) -> CFArray?

guard let mc = sym("CGSMainConnectionID", as: MainConnFn.self),
      let sf = sym("CGSCopyManagedDisplaySpaces", as: CopySpacesFn.self) else {
    print("FAIL symbols"); exit(1)
}
let cid = mc()

let label = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "?"
print("======= \(label) =======")

guard let displays = sf(cid) as? [[String: Any]] else { print("no displays"); exit(1) }
for d in displays {
    let spaces = d["Spaces"] as? [[String: Any]] ?? []
    let cur = d["Current Space"] as? [String: Any]
    let curID = cur?["ManagedSpaceID"] as? Int
    print("display \(d["Display Identifier"] ?? "?") | 共 \(spaces.count) 个 Space | 当前=\(String(describing: curID)) type=\(String(describing: cur?["type"])) fs_wid=\(String(describing: cur?["fs_wid"])) pid=\(String(describing: cur?["pid"]))")
    for s in spaces {
        let id = s["ManagedSpaceID"] as? Int ?? -1
        let type = s["type"] as? Int ?? -1
        let fsWid = s["fs_wid"] as? Int ?? -1
        let pid = s["pid"] as? Int ?? -1
        let hasTile = s["TileLayoutManager"] != nil
        let mark = (id == curID) ? "  ← 当前" : ""
        print("   id=\(id) type=\(type) fs_wid=\(fsWid) pid=\(pid) tile=\(hasTile)\(mark)")
    }
}
