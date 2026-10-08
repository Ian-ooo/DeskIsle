import Foundation
import CoreGraphics

/// 一套「分区布局」快照。
///
/// 用途：把某块屏上所有分区的位置/尺寸，连同该屏的对齐模式，存成一条**命名**记录，
/// 之后一键回到该布局（例如「工作模式」= 收件箱在左、代码在右；「阅读模式」= 全部平铺）。
///
/// 三个刻意的设计决定：
/// - **按屏保存**：分区坐标是**屏幕相对**的，跨屏套用会把分区搬到不相干的显示器上，
///   因此 `screenID` 是预设的一部分，应用时也把它们搬回该屏。
/// - **按分区 id 记条目**：id 稳定不变（重命名、换映射目录都不改），比「第 N 个分区」可靠得多 ——
///   后者在中间插入/删除一个分区就会整体错位。
/// - **存展开高度**：折叠是临时的查看状态，不该被写进布局；否则从折叠状态保存的预设
///   会让所有分区以 44pt 高恢复。
struct LayoutPreset: Equatable {
    /// 单个分区在**所属屏相对坐标系**下的位置与尺寸。
    struct Entry: Equatable {
        let id: String
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    let name: String
    let screenID: CGDirectDisplayID
    /// 保存时该屏的对齐模式。应用后顶栏的 align 高亮态要跟着它走，否则界面显示「网格平铺」
    /// 而实际布局是「右侧纵向」，用户下次点对齐会突然跳变，像是布局被改坏了。
    let alignMode: String
    let entries: [Entry]
    let savedAt: Date

    /// 同名预设在同一块屏上唯一 —— 唯一的判定键。
    static func key(name: String, screenID: CGDirectDisplayID) -> String {
        "\(screenID)|\(name)"
    }
    var key: String { Self.key(name: name, screenID: screenID) }

    /// 名称规范化：去首尾空白 + 限长，避免空名或超长名把设置面板撑坏。
    static func normalize(name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20))
    }
}

// MARK: - 与配置字典的互转

extension LayoutPreset {
    /// 从配置字典解析。**坏数据只丢自己、不炸整个列表** —— 手改配置或跨端同步出问题时，
    /// 其余预设仍要能用。
    init?(dict: [String: Any]) {
        guard let name = dict["name"] as? String, !name.isEmpty else { return nil }
        let sid: CGDirectDisplayID?
        if let v = dict["screenId"] as? Int { sid = CGDirectDisplayID(truncatingIfNeeded: v) }
        else if let v = dict["screenId"] as? NSNumber { sid = CGDirectDisplayID(truncating: v) }
        else if let v = dict["screenId"] as? Double { sid = CGDirectDisplayID(v) }
        // 另两端写的是**字符串**形式的屏标识（Windows 是 `\.\DISPLAY1`，Electron 恒 `primary`）。
        // 这些值在 mac 上本来就对不上任何显示器；能解析成数字就认，否则整条预设作废
        // —— 预设的 entries 是**屏内坐标**，没有归属屏就没法应用（列到别的屏上会跑到屏幕外）。
        else if let v = dict["screenId"] as? String { sid = CGDirectDisplayID(v) }
        else { sid = nil }
        guard let screenID = sid else { return nil }

        let rawEntries = dict["entries"] as? [[String: Any]] ?? []
        let entries: [Entry] = rawEntries.compactMap { e in
            guard let id = e["id"] as? String else { return nil }
            return Entry(id: id,
                         x: Config.num(e["x"]), y: Config.num(e["y"]),
                         width: Config.num(e["width"]), height: Config.num(e["height"]))
        }
        self.init(name: name,
                  screenID: screenID,
                  alignMode: (dict["alignMode"] as? String) ?? "top",
                  entries: entries,
                  savedAt: Self.savedAt(from: dict))
    }

    /// 读「保存时间」。规范键是 `savedAt`（**秒**，mac 的写法）；
    /// 兼容 Windows / Electron 的 `createdAt`，而它存的是**毫秒**。
    /// ⚠️ 不折算的话时间戳会差 1000 倍（跑到 1970 年或 5 万年以后），预设排序彻底错乱。
    private static func savedAt(from dict: [String: Any]) -> Date {
        if let s = dict["savedAt"] as? Double { return Date(timeIntervalSince1970: s) }
        if let s = dict["savedAt"] as? Int { return Date(timeIntervalSince1970: Double(s)) }
        if let ms = dict["createdAt"] as? Double { return Date(timeIntervalSince1970: ms / 1000) }
        if let ms = dict["createdAt"] as? Int { return Date(timeIntervalSince1970: Double(ms) / 1000) }
        return Date(timeIntervalSince1970: 0)
    }

    var dict: [String: Any] {
        [
            "name": name,
            "screenId": Int(screenID),
            "alignMode": alignMode,
            "savedAt": savedAt.timeIntervalSince1970,
            "entries": entries.map { e -> [String: Any] in
                ["id": e.id, "x": Int(e.x.rounded()), "y": Int(e.y.rounded()),
                 "width": Int(e.width.rounded()), "height": Int(e.height.rounded())]
            }
        ]
    }
}
