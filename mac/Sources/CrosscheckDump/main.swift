import Foundation
import DeskIsleLayout

// ─────────────────────────────────────────────────────────────────────────────
// 跨端对拍的 **mac 侧**：直接调用真实 `LayoutEngine` 打出 JSON，
// 与 `scripts/crosscheck/csharp-crosscheck.py`（Windows `LayoutEngine.cs` 的逐行直译）
// 逐点比对。
//
// ⚠️ 本文件**不是**参考实现的复刻 —— 它调的就是线上跑的那份代码。
// 旧方案（`js-reference.mts`）是 Electron `useIsleStore.alignPartitions` 的手工复刻，
// 一改 store 忘了同步就会「假绿」；现在比的是 mac 基线本身，不存在同步问题。
//
// ⚠️⚠️ 固件（下面 HS / TALL / 坐标公式 / 常量）必须与 Python 侧的 `SCENARIOS()`
// **逐字一致**，否则两边比的是两份不同的输入，对拍毫无意义。
// ─────────────────────────────────────────────────────────────────────────────

let screenW = 1920.0
let screenH = 1200.0
let topMargin = 100.0
let fixtureW = 316.0
let defaultWidth = 316.0
let maxColumns = 5
let gap = Double(Layout.gap)

// 固件写死了 margin = 16；若哪天 mac 的排版常量变了，这里必须跟着改，
// 否则与 Windows 侧口径不同 —— 直接崩掉，好过静默给出「一致」的错觉。
assert(Double(Layout.margin) == 16.0, "排版常量变了：固件里的 margin=16 需同步")
assert(gap == 16.0, "排版常量变了：固件里的 gap=16 需同步")

let HS = [316.0, 150.0, 150.0, 150.0, 314.0, 428.0, 610.0]
// 「超高」复现件：7 条里 5 条 900 高，availH = 1060。
// 高度超了要**加**列（与「宽度超了才减列」方向相反），这是最容易写反的一处。
let TALL = [500.0, 500.0, 900.0, 900.0, 900.0, 900.0, 900.0]

func fixture(_ hs: [Double], _ tag: String) -> [LayoutEngine.AlignItem] {
    hs.enumerated().map { i, h in
        LayoutEngine.AlignItem(
            id: "\(tag)\(i)",
            x: 16.0 + Double(i % 5) * (fixtureW + 16.0),
            y: 100.0 + Double(i / 5) * 500.0,
            width: fixtureW, height: h, isCollapsed: false, index: i)
    }
}

func mirrored(_ items: [LayoutEngine.AlignItem]) -> [LayoutEngine.AlignItem] {
    // 关于屏幕中线镜像（右边距 = 左边距）
    items.map {
        LayoutEngine.AlignItem(id: $0.id, x: 1920.0 - ($0.x - 16.0) - fixtureW,
                               y: $0.y, width: $0.width, height: $0.height,
                               isCollapsed: $0.isCollapsed, index: $0.index)
    }
}

let scenarios: [(String, [LayoutEngine.AlignItem])] = [
    ("贴左初值", fixture(HS, "t")),
    ("贴右初值", mirrored(fixture(HS, "t"))),
    ("超高初值", fixture(TALL, "s")),
]

/// 与 Python 侧同为「保留 6 位小数」。
/// ⚠️ Python 的 `round()` 是银行家舍入，Swift 的 `rounded()` 是四舍五入，
/// 二者在 `.5` 边界上不同；固件里的坐标都是整数或 .0 结尾，实测不受影响。
func r6(_ v: Double) -> Double { (v * 1e6).rounded() / 1e6 }

func run(_ items: [LayoutEngine.AlignItem], mode: String, order: String) -> [String: Any] {
    let placements = LayoutEngine.alignPlacements(
        items: items, mode: mode,
        screenWidth: screenW, screenHeight: screenH, top: topMargin,
        maxColumns: maxColumns, defaultWidth: defaultWidth, topHeightOrder: order)

    var coordMap: [String: (x: Double, y: Double)] = [:]
    for p in placements { coordMap[p.id] = (p.x, p.y) }

    let ids = items.map { $0.id }
    // ⚠️ 列高汇总用**原始高度**（与 Python 侧 `hmap[i]` 同口径），不是 effH。
    // 固件里没有折叠项、高度也都 > 0，两种口径当前等价；但口径必须写死成同一边，
    // 否则将来加一个折叠分区就会冒出「假不一致」。
    let hmap = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.height) })

    // 按 x 分组（与 Python 侧同为 round(x, 3)），组内按 y 升序 —— 还原「列」
    var byX: [Double: [(y: Double, id: String)]] = [:]
    for id in ids {
        guard let c = coordMap[id] else { continue }
        let xr = (c.x * 1000).rounded() / 1000
        byX[xr, default: []].append((c.y, id))
    }
    var cols: [(h: Double, members: [String])] = []
    for x in byX.keys.sorted() {
        let members = byX[x]!.sorted { $0.y < $1.y }
        let hs = members.map { hmap[$0.id] ?? 0 }
        cols.append((hs.reduce(0, +) + Double(members.count - 1) * gap,
                     members.map { $0.id }))
    }

    return [
        "coords": Dictionary(uniqueKeysWithValues: ids.compactMap { id -> (String, [Double])? in
            guard let c = coordMap[id] else { return nil }
            return (id, [r6(c.x), r6(c.y)])
        }),
        "colHeights": cols.map { r6($0.h) },
        "columns": cols.map { $0.members },
    ]
}

var out: [String: Any] = [:]
for (scene, items) in scenarios {
    for mode in ["top", "left", "right", "grid"] {
        // 只有 top 区分横排方向（贴左 / 贴右）；其余模式的 order 被忽略，
        // 但 Python 侧同样传了 "leftToRight"，保持一致。
        for order in (mode == "top" ? ["leftToRight", "rightToLeft"] : ["leftToRight"]) {
            let key = "\(scene)/\(mode)" + (mode == "top" ? "/\(order)" : "")
            out[key] = run(items, mode: mode, order: order)
        }
    }
}

let data = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
print(String(data: data, encoding: .utf8) ?? "")
