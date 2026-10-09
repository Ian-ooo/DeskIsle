import Foundation
import Combine
import CoreGraphics
import DeskIsleCore

/// 配置的唯一真值：以字典持有原始 JSON，读写全程保留未知字段，
/// 避免用 Codable 子集重编码时把 Electron 版的字段丢掉。
///
/// 注意：`raw` 不是 @Published。UI 关心的变化（置顶/待办/便签/分区增删）通过
/// `updateUI` 递增 `revision` 触发重渲染；纯位置变化走 `updateQuiet`，不触发重渲染
/// （拖动时窗口每帧都会 didMove，若每次都重渲染整棵树会卡）。
final class Config: ObservableObject {
    @Published private(set) var revision = 0
    private(set) var raw: [String: Any] = [:]
    let url: URL
    /// 最近一次本应用落盘的时间。配置热重载用它区分「自己写的」和「外部改的」：
    /// 自己保存会触发文件 watcher，若不区分就会 save → watcher → rebuild 的自触发死循环。
    private(set) var lastSaveTime = Date.distantPast
    /// 「显示/隐藏分区」（幽灵模式）—— 临时内存态，不落盘（重启默认全部显示）。
    /// 多显示器下**按屏独立**：每台显示器各自控制自己屏内分区的显隐，
    /// 因此存的是「已隐藏的显示器 ID 集合」而不是一个全局布尔。
    /// 需可观察，以便顶栏眼睛按钮的高亮态随切换刷新。
    @Published private(set) var hiddenScreens: Set<CGDirectDisplayID> = []

    /// 指定显示器上的分区当前是否处于隐藏态。
    func isScreenHidden(_ screenID: CGDirectDisplayID) -> Bool {
        hiddenScreens.contains(screenID)
    }

    /// 设置指定显示器上分区的显隐。
    func setScreenHidden(_ screenID: CGDirectDisplayID, _ hidden: Bool) {
        if hidden { hiddenScreens.insert(screenID) } else { hiddenScreens.remove(screenID) }
    }

    /// 切换指定显示器上分区的显隐。
    func toggleScreenHidden(_ screenID: CGDirectDisplayID) {
        setScreenHidden(screenID, !isScreenHidden(screenID))
    }

    /// 显示器被拔掉后清理其隐藏态，避免 ID 复用导致误判。
    func pruneHiddenScreens(keeping ids: Set<CGDirectDisplayID>) {
        let next = hiddenScreens.intersection(ids)
        if next != hiddenScreens { hiddenScreens = next }
    }

    init(url: URL) { self.url = url }

    /// 确保配置所在目录存在。
    /// ⚠️ 必须显式创建：`~/Library/Application Support/deskisle/` 在首次运行时并不存在，
    /// 而 `Data.write(to:)` 不会自动建目录 —— 缺了这一步保存会**静默失败**，
    /// 表现为「分区能用、重启后全部消失」。
    private func ensureDirectory() {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                NSLog("[DeskIsle] 配置目录创建失败: %@", error.localizedDescription)
            }
        }
    }

    @discardableResult
    func load() -> Bool {
        ensureDirectory()
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // 首次运行（文件尚不存在）属正常情况，不是错误
            NSLog("[DeskIsle] 未找到配置文件，按空配置启动: %@", url.path)
            return false
        }
        raw = obj
        // 顶层字段被另两端写进 settings 时搬回来（幂等）；搬动了也算一次迁移，需要落盘
        let moved = normalizeKeyLocations()
        // 已下线类型的分区直接剔掉（当前是 `collection` 文件收集箱）
        let dropped = dropRemovedPartitionTypes()
        // 整份配置换掉了：视图侧缓存（徽标计数等）必须全部作废，
        // 否则热重载、恢复历史快照之后界面还显示换掉之前的内容。
        invalidateAllViewCaches()
        didMigrate = migrate() || moved || dropped
        return true
    }

    /// 原子写回：临时文件 + rename，并把上一份复制成 .bak（与 Electron 一致）。
    ///
    /// ⚠️ rename 会替换 inode：任何**监听本文件 fd** 的 watcher 在第一次 save 后就会
    /// 失效（fd 指向已删除的旧 inode，永远不再收到事件）。热重载必须监听**所在目录**
    /// 并比较 mtime（见 AppDelegate.startConfigWatching），不能监听文件本身。
    /// - Parameter forceSnapshot: **忽略历史快照的节流闸门**，无条件给即将被覆盖的这一份留底。
    ///   只在「马上要用旧快照覆盖当前配置」之前传 true（见 `ConfigHistory.shouldSnapshot` 的注释）：
    ///   那一刻往往刚刚才保存过，走闸门会被判「距上次太近」而跳过，于是步子迈出去了、
    ///   底却没留 —— UI 承诺的「之后仍可恢复回来」当场失效。
    func save(forceSnapshot: Bool = false) {
        let fm = FileManager.default
        lastSaveTime = Date()
        ensureDirectory()   // 兜底：目录被清理后仍能恢复写入
        pushHistorySnapshot(force: forceSnapshot)   // 先给「即将被覆盖的这一份」留快照
        let bak = url.appendingPathExtension("bak")
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: bak)
            try? fm.copyItem(at: url, to: bak)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: raw,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            if fm.fileExists(atPath: url.path) {
                // ⚠️ 必须是**单步**原子替换。原先这里写的是 `removeItem(url)` + `moveItem(tmp→url)`
                // 两步，而两步之间存在一个真实的窗口：进程在这中间被杀（或断电），
                // 配置文件就**真的不在了** ——只剩 .bak 兜底，而 .bak 是上一次保存的内容，
                // 最近一次改动照样丢。`replaceItemAt` 的结果只有「旧文件」或「新文件」两种可能。
                //
                // 顺带保留那条老经验：它同样会替换 inode，所以「热重载必须监听所在目录、
                // 不能监听文件本身」的结论对这里依然成立（见本节开头的注释）。
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
        } catch {
            NSLog("[DeskIsle] 配置保存失败: %@", error.localizedDescription)
        }
    }

    // MARK: - 配置结构版本与迁移

    /// 当前配置结构版本。
    ///
    /// **每次改动配置结构（新增必填字段、改变字段语义、字段搬家）都要 +1**，
    /// 并在 `migrate()` 里补一条 `from < N` 的升级分支。
    /// 在此之前只能靠「某字段是否存在」猜版本，加一个字段就要重新猜一次。
    ///
    /// 版本历史：
    /// - **1**（隐式，无字段）：早期版本。分区坐标是全局坐标、无 `screenId`、
    ///   多显示器相关设置是单一全局键。
    /// - **2**：把「配置版本号」本身写进文件；按屏字段（`screenId`、
    ///   `topBarByScreen` / `alignModeByScreen` / `lockedByScreen`）作为**新增可选字段**引入，
    ///   读取器统一走「表为空则回退旧全局键」，因此无需搬运历史数据。
    /// - **3**：新增 `layoutPresets`（布局预设，可选字段，缺省即无预设）。
    ///   同样无需搬运数据，版本号用于标记结构演进 + 让「坏了能定位到是哪个版本改的」。
    static let currentSchemaVersion = 3

    /// 文件里记录的版本号；没有该字段即视为 v1。
    ///
    /// ⚠️ **两个位置都要读**：mac 写在顶层 `raw["schemaVersion"]`，
    /// 而 Windows / Electron 历史上写在 `settings["schemaVersion"]`。
    /// 只读顶层的话，会把一份「其实已经是 v3」的配置当成 v1 重新迁移一遍 ——
    /// 版本语义失真，后续排查会完全对不上。
    var schemaVersion: Int {
        (raw["schemaVersion"] as? Int) ?? (settings["schemaVersion"] as? Int) ?? 1
    }

    /// 剔除配置里**已下线分区类型**的条目（当前只有 `collection` 文件收集箱）。
    ///
    /// 为什么必须在读盘时做、而不是等用户手动删：这类分区在代码里已经没有对应视图，
    /// 留着会被 `PartitionView` 落到 `default` 分支 —— 渲染出一个只有类型名的空壳；
    /// 而设置面板拿不到它的元信息，用户**自己也删不掉**。跨端互导配置时更会一路带过去。
    ///
    /// ⚠️ 这里是「从街上永久移除」而非隐藏：判断失误就等于删了用户的分区。
    /// 所以入榜前必须确认该类型的实现已在两端全部移除。
    ///
    /// **幂等**：没有可剔除项就不动手。返回是否发生了改动。
    private func dropRemovedPartitionTypes() -> Bool {
        guard let parts = raw["partitions"] as? [[String: Any]] else { return false }
        let r = RemovedPartition.droppingRemovedTypes(parts)
        guard r.dropped > 0 else { return false }
        raw["partitions"] = r.kept
        NSLog("[DeskIsle] 已剔除 %d 个已下线类型的分区（%@）",
              r.dropped, RemovedPartition.removedTypes.joined(separator: " / "))
        return true
    }

    /// 把「被另两端放进 `settings` 的顶层字段」搬回顶层，并清掉已被取代的旧键名别名。
    ///
    /// 为什么需要：`schemaVersion` / `layoutPresets` 在 mac 是**顶层**字段，
    /// 而 Windows / Electron 把它们写在 `settings` 里。两个位置长期并存，
    /// 文件里就等于有「两个版本的真相」—— 每次互导都会触发一次假迁移，极难排查。
    ///
    /// **幂等**：搬完就把 `settings` 里那份删掉，再跑一次什么都不做。
    /// 返回是否发生了改动（调用方据此决定是否立刻落盘）。
    private func normalizeKeyLocations() -> Bool {
        var r = raw
        var st = (r["settings"] as? [String: Any]) ?? [:]
        var changed = false

        // 1) schemaVersion / layoutPresets：settings → 顶层
        for key in ["schemaVersion", "layoutPresets"] {
            if r[key] == nil, let v = st[key] {
                r[key] = v              // 顶层还没有 → 搬上去
                st.removeValue(forKey: key)
                changed = true
            } else if r[key] != nil, st[key] != nil {
                st.removeValue(forKey: key)   // 顶层已有权威值 → 丢掉 settings 里的副本
                changed = true
            }
        }

        // 2) 旧热键键名：规范键存在时清掉别名，避免文件里留下两份互相矛盾的设置
        //    （读取侧本来就是「规范键优先」，这里只是把冗余清干净）
        for (canonical, legacy) in [("globalShortcut", "globalHotkey"),
                                    ("searchShortcut", "searchHotkey")] {
            if st[canonical] != nil, st[legacy] != nil {
                st.removeValue(forKey: legacy)
                changed = true
            }
        }

        if changed {
            r["settings"] = st
            raw = r
        }
        return changed
    }


    /// 全局「显示/隐藏」热键的持久化值。
    /// **兼容旧键名** `globalHotkey` —— Windows 历史上用的就是它。
    /// 不兼容的话，「在 Windows 上自定义的热键」导入 mac 后会被静默忽略、退回默认键。
    var globalShortcutPersisted: String? {
        (settings["globalShortcut"] as? String) ?? (settings["globalHotkey"] as? String)
    }

    /// 全局搜索热键的持久化值（同上，兼容 `searchHotkey`）。
    var searchShortcutPersisted: String? {
        (settings["searchShortcut"] as? String) ?? (settings["searchHotkey"] as? String)
    }

    /// 本次加载是否发生过结构迁移（调用方据此决定是否立刻落盘一次）。
    private(set) var didMigrate = false

    /// 把旧版本配置补齐到当前版本。返回是否发生了改动。
    @discardableResult
    private func migrate() -> Bool {
        let from = schemaVersion
        guard from < Self.currentSchemaVersion else { return false }

        var r = raw
        var notes: [String] = []

        if from < 2 {
            // v1 → v2：只是登记版本号。
            // 这一版引入的按屏字段全部是**可选**的，各自的读取器在「按屏表为空」时
            // 自动回退到旧全局键（见 `screenFlag(_:legacyKey:_:default:)`），
            // 因此这里不搬运数据 —— 迁移必须是幂等且不丢字段的。
            notes.append("登记 schemaVersion；按屏字段交由读取器兼容回退")
        }

        if from < 3 {
            // v2 → v3：`layoutPresets` 是可选的新字段，没有预设时保持「字段不存在」
            // （而不是写一个空数组进文件），避免给不用该功能的用户凭空加噪音。
            notes.append("布局预设字段就绪（无预置数据）")
        }

        r["schemaVersion"] = Self.currentSchemaVersion
        raw = r
        NSLog("[DeskIsle] 配置结构迁移 v%d → v%d：%@", from, Self.currentSchemaVersion, notes.joined(separator: "；"))
        return true
    }

    // MARK: - 历史快照（滚动备份）

    /// 历史快照保留份数
    private let historyKeepCount = 20
    /// 相邻两次快照的最小间隔（秒）：拖动分区、连续调设置会高频保存，
    /// 没有这个闸门会把 20 份名额瞬间用完。
    private let historyMinInterval: TimeInterval = 60
    private var lastHistoryAt = Date.distantPast

    /// 快照目录（与配置同级的 `history/`）
    var historyDirectory: URL {
        url.deletingLastPathComponent().appendingPathComponent("history", isDirectory: true)
    }

    /// 把当前磁盘上的配置复制一份进历史目录。写新内容**之前**调用，
    /// 因此快照内容永远是「上一次已知可用的状态」。
    private func pushHistorySnapshot(force: Bool = false) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let now = Date()
        guard ConfigHistory.shouldSnapshot(now: now,
                                           lastHistoryAt: lastHistoryAt,
                                           minInterval: historyMinInterval,
                                           force: force) else { return }
        lastHistoryAt = now

        try? fm.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let base = fmt.string(from: now)
        // 同一秒内撞名时逐层加后缀：直接 `copyItem` 到已存在的目标会走 `try?` 静默失败，
        // 结果是「旧配置已经被覆盖、可回滚的那一版却没写成」，且没有任何报错。
        var index = 0
        var dest = historyDirectory.appendingPathComponent(
            ConfigHistory.snapshotFileName(base: base, collisionIndex: index))
        while fm.fileExists(atPath: dest.path) {
            index += 1
            dest = historyDirectory.appendingPathComponent(
                ConfigHistory.snapshotFileName(base: base, collisionIndex: index))
        }
        try? fm.copyItem(at: url, to: dest)
        pruneHistory()
    }

    /// 只保留最近 `historyKeepCount` 份（按文件名倒序，文件名是零填充时间戳，可直接比较）。
    private func pruneHistory() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: historyDirectory,
                                                      includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "json" })
            .sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) else { return }
        for stale in files.dropFirst(historyKeepCount) {
            try? fm.removeItem(at: stale)
        }
    }

    /// 可用的历史快照，按时间**倒序**（最新的在前）。
    func availableHistory() -> [URL] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(at: historyDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// UI 关心的变更：会触发 SwiftUI 重渲染。
    func updateUI(_ mutate: (inout [String: Any]) -> Void) {
        var r = raw
        mutate(&r)
        raw = r
        revision += 1
    }

    /// 静默变更（如拖动位置）：不触发重渲染。
    func updateQuiet(_ mutate: (inout [String: Any]) -> Void) {
        var r = raw
        mutate(&r)
        raw = r
    }

    // MARK: - 访问器

    var partitions: [[String: Any]] { raw["partitions"] as? [[String: Any]] ?? [] }
    var settings: [String: Any] { raw["settings"] as? [String: Any] ?? [:] }

    var showTopBar: Bool { (settings["showTopBar"] as? Bool) ?? true }
    var maxColumns: Int { min(6, max(4, (settings["maxColumns"] as? Int) ?? 5)) }

    /// 横排列高方向 —— **只影响「顶部横向排序」（top）**：
    /// `leftToRight` = 左侧最高、向右依次递减或相等；`rightToLeft` = 右侧最高、向左依次递减或相等。
    ///
    /// 默认 `leftToRight`。读取时对未知值回退到默认，老配置无需迁移。
    var topHeightOrder: String {
        let v = (settings["topHeightOrder"] as? String) ?? "leftToRight"
        return v == "rightToLeft" ? "rightToLeft" : "leftToRight"
    }

    var partitionWidthMode: String { (settings["partitionWidthMode"] as? String) ?? "auto" }
    var customPartitionWidth: CGFloat { CGFloat((settings["customPartitionWidth"] as? Double) ?? Double((settings["customPartitionWidth"] as? Int) ?? 280)) }
    var defaultPartitionHeight: CGFloat {
        let val = CGFloat((settings["defaultPartitionHeight"] as? Double) ?? Double((settings["defaultPartitionHeight"] as? Int) ?? 200))
        return max(140.0, val)
    }

    /// 分区最小高度（全局）：**新建分区**的初始高度、**自适应宽高**算出的高度都不会低于它。
    ///
    /// 未显式设置时**跟随 `defaultPartitionHeight`**（默认 200）：
    /// 一是老配置无需迁移、升级后行为不变，二是符合「默认与分区默认高度一致」的预期 ——
    /// 用户改「默认高度」而从未碰过这一项时，下限跟着走。
    /// 一旦用户显式设定过，就以设定值为准，不再随默认高度变化。
    /// 硬下限同样取 140（与默认高度的可输入下限一致），避免把分区压得只剩标题栏。
    var minPartitionHeight: CGFloat {
        if let d = settings["minPartitionHeight"] as? Double { return max(140.0, CGFloat(d)) }
        if let i = settings["minPartitionHeight"] as? Int { return max(140.0, CGFloat(i)) }
        return defaultPartitionHeight
    }

    /// 分区背景不透明度（全局，滑动可调）：
    /// 0 = 最通透（仅保留系统毛玻璃层），1 = 深色实底。
    /// 默认 0.10 —— 与历史上写死的遮罩值一致，老配置升级后视觉不变。
    var partitionBgOpacity: Double {
        guard let v = settings["partitionBgOpacity"] as? Double else { return 0.10 }
        return min(1.0, max(0.0, v))
    }
    var hasPinned: Bool { partitions.contains { ($0["isAlwaysOnTop"] as? Bool) == true } }

    func index(of id: String) -> Int? { partitions.firstIndex { ($0["id"] as? String) == id } }
    func partition(_ id: String) -> [String: Any]? { index(of: id).flatMap { partitions[$0] } }

    // MARK: - 按显示器的状态（多显示器）

    /// 分区所属显示器（`CGDirectDisplayID`）。
    /// 配置里的 x/y 是**相对这块屏幕**左上原点的坐标；旧配置无此字段时返回 nil（调用方回退到参考屏）。
    func screenId(of id: String) -> CGDirectDisplayID? {
        guard let p = partition(id) else { return nil }
        if let v = p["screenId"] as? Int { return CGDirectDisplayID(truncatingIfNeeded: v) }
        if let v = p["screenId"] as? NSNumber { return CGDirectDisplayID(truncating: v) }
        if let v = p["screenId"] as? Double { return CGDirectDisplayID(v) }
        return nil
    }

    /// 指定显示器的对齐模式。
    /// 优先读「按屏表」`alignModeByScreen`；未设置时回退到全局 `alignMode`（兼容旧配置），默认 `top`。
    func alignMode(forScreen sid: CGDirectDisplayID) -> String {
        if let table = settings["alignModeByScreen"] as? [String: Any],
           let v = table[String(sid)] as? String, !v.isEmpty {
            return v
        }
        return (settings["alignMode"] as? String) ?? "top"
    }

    /// 通用：读「按屏布尔表」。
    /// 表为空时回退到旧版全局开关（自然完成旧配置迁移）；表非空后逐屏独立，未设置的屏取 `defaultValue`。
    private func screenFlag(_ key: String, legacyKey: String, _ sid: CGDirectDisplayID,
                           default defaultValue: Bool) -> Bool {
        if let table = settings[key] as? [String: Any], !table.isEmpty {
            return (table[String(sid)] as? Bool) ?? defaultValue
        }
        return (settings[legacyKey] as? Bool) ?? defaultValue
    }

    /// 通用：写「按屏布尔表」（同时更新旧版全局键，供降级使用）。
    private func setScreenFlag(_ key: String, legacyKey: String, _ sid: CGDirectDisplayID, _ on: Bool) {
        updateUI { raw in
            var s = raw["settings"] as? [String: Any] ?? [:]
            s[legacyKey] = on
            var table = s[key] as? [String: Any] ?? [:]
            table[String(sid)] = on
            s[key] = table
            raw["settings"] = s
        }
    }

    /// 指定显示器上的分区是否被「锁定分区位置」（全局锁按屏独立）。
    func isScreenLocked(_ sid: CGDirectDisplayID) -> Bool {
        screenFlag("lockedByScreen", legacyKey: "isLayoutLocked", sid, default: false)
    }

    /// 切换指定显示器上分区的全局锁定。
    func setScreenLocked(_ sid: CGDirectDisplayID, _ locked: Bool) {
        setScreenFlag("lockedByScreen", legacyKey: "isLayoutLocked", sid, locked)
    }

    /// 指定显示器是否显示顶部导航栏。
    func showTopBar(forScreen sid: CGDirectDisplayID) -> Bool {
        screenFlag("topBarByScreen", legacyKey: "showTopBar", sid, default: true)
    }

    /// 设置指定显示器是否显示顶部导航栏。
    func setShowTopBar(_ on: Bool, forScreen sid: CGDirectDisplayID) {
        setScreenFlag("topBarByScreen", legacyKey: "showTopBar", sid, on)
    }

    /// 记录某显示器的对齐模式。
    /// 同时更新全局 `alignMode`：新接入的显示器、以及旧版本读写时都能拿到一个合理默认值。
    func setAlignMode(_ mode: String, forScreen sid: CGDirectDisplayID) {
        updateUI { raw in
            var s = raw["settings"] as? [String: Any] ?? [:]
            s["alignMode"] = mode
            var table = s["alignModeByScreen"] as? [String: Any] ?? [:]
            table[String(sid)] = mode
            s["alignModeByScreen"] = table
            raw["settings"] = s
        }
    }

    /// 清理已拔掉显示器的按屏状态（对齐模式 / 锁定 / 顶栏显隐三张表），避免 ID 复用导致误判。
    func pruneScreenSettings(keeping ids: Set<CGDirectDisplayID>) {
        let alive = Set(ids.map { String($0) })
        updateQuiet { raw in
            var s = raw["settings"] as? [String: Any] ?? [:]
            var changed = false
            for key in ["alignModeByScreen", "lockedByScreen", "topBarByScreen"] {
                guard let table = s[key] as? [String: Any] else { continue }
                let next = table.filter { alive.contains($0.key) }
                if next.count != table.count {
                    s[key] = next
                    changed = true
                }
            }
            if changed { raw["settings"] = s }
        }
    }

    // MARK: - 布局预设

    /// 全部布局预设（跨所有显示器）。
    /// 解析失败的条目（字段缺失、手改配置改坏）静默跳过，不影响其余预设。
    var allLayoutPresets: [LayoutPreset] {
        (raw["layoutPresets"] as? [[String: Any]] ?? []).compactMap { LayoutPreset(dict: $0) }
    }

    /// 指定显示器上的布局预设，按保存时间倒序（最近存的排最前）。
    func layoutPresets(forScreen sid: CGDirectDisplayID) -> [LayoutPreset] {
        allLayoutPresets.filter { $0.screenID == sid }.sorted { $0.savedAt > $1.savedAt }
    }

    func layoutPreset(named name: String, onScreen sid: CGDirectDisplayID) -> LayoutPreset? {
        let key = LayoutPreset.key(name: name, screenID: sid)
        return allLayoutPresets.first { $0.key == key }
    }

    /// 新增或覆盖一条预设（同名同屏视为覆盖 —— 「用当前布局更新」走的就是这条）。
    func saveLayoutPreset(_ preset: LayoutPreset) {
        updateUI { raw in
            var list = (raw["layoutPresets"] as? [[String: Any]] ?? [])
                .filter { ($0["name"] as? String) != preset.name
                          || Self.num($0["screenId"]) != Double(preset.screenID) }
            list.append(preset.dict)
            raw["layoutPresets"] = list
        }
    }

    func deleteLayoutPreset(named name: String, onScreen sid: CGDirectDisplayID) {
        updateUI { raw in
            var list = raw["layoutPresets"] as? [[String: Any]] ?? []
            list.removeAll { ($0["name"] as? String) == name
                             && Self.num($0["screenId"]) == Double(sid) }
            if list.isEmpty { raw.removeValue(forKey: "layoutPresets") }
            else { raw["layoutPresets"] = list }
        }
    }

    /// 显示器被拔掉后，其布局预设失去意义（坐标相对那块屏）→ 一并清掉，避免插回同 ID 的
    /// 另一块屏时套用出一堆跑到屏幕外的分区。
    func pruneLayoutPresets(keeping ids: Set<CGDirectDisplayID>) {
        updateQuiet { raw in
            guard let list = raw["layoutPresets"] as? [[String: Any]] else { return }
            let alive = Set(ids.map { Double($0) })
            let next = list.filter { alive.contains(Self.num($0["screenId"])) }
            if next.count != list.count {
                if next.isEmpty { raw.removeValue(forKey: "layoutPresets") }
                else { raw["layoutPresets"] = next }
            }
        }
    }

    // MARK: - 字段取值辅助

    static func num(_ v: Any?) -> Double {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        return 0
    }
    static func str(_ v: Any?) -> String? { v as? String }
    static func bool(_ v: Any?) -> Bool { (v as? Bool) ?? false }

    func num(_ key: String, of id: String) -> Double {
        guard let p = partition(id) else { return 0 }
        return Self.num(p[key])
    }
    func str(_ key: String, of id: String) -> String? {
        guard let p = partition(id) else { return nil }
        return Self.str(p[key])
    }
    func bool(_ key: String, of id: String) -> Bool {
        guard let p = partition(id) else { return false }
        return Self.bool(p[key])
    }
    func style(_ key: String, of id: String, default d: Double) -> Double {
        guard let p = partition(id), let st = p["style"] as? [String: Any], let v = st[key] else { return d }
        return Self.num(v)
    }
    func styleStr(_ key: String, of id: String, default d: String) -> String {
        guard let p = partition(id), let st = p["style"] as? [String: Any], let v = Self.str(st[key]) else { return d }
        return v
    }

    /// 分区里可写进 `style` 的样式键（其余键写在分区根层）。
    static let styleKeys: Set<String> = ["blurAmount", "borderRadius", "bgColor", "bgOpacity", "headerColor", "textColor"]

    // MARK: - 视图侧缓存（徽标计数）

    /// 标题栏徽标计数的缓存。
    ///
    /// **为什么必须缓存**：`badgeCount` 是在 **SwiftUI body 里**求值的
    /// （`PartitionView.header` 属于 `body`，且折叠态也照样渲染 header），
    /// 而 `config` 是全局 `@ObservedObject` —— 任何 `updateUI` 都会让**所有**分区重算 body。
    /// 不缓存的话，「在便签里敲一个字」就等于「每个 portal 分区各列一次目录」，
    /// 映射到大目录（数千条）时输入会立刻发黏。
    ///
    /// 失效走两路：
    /// 1. **主动**：`FolderWatcher` 报某分区目录变化时调 `invalidateBadge(_:)` —— 及时；
    /// 2. **兜底 TTL**：防止 watcher 没覆盖到的路径（例如所在屏幕隐藏时整轮跳过）
    ///    永远显示旧数字。
    private var badgeCounts: [String: Int] = [:]
    private var badgeCountedAt: [String: Date] = [:]
    private static let badgeFallbackTTL: TimeInterval = 5

    /// 目录变化后立刻作废该分区的徽标缓存（由 `FolderWatcher` 回调驱动）。
    ///
    /// ⚠️ **必须连带递增 `revision`**：只清缓存是没用的 ——
    /// `badgeCount` 是在 `body` 里求值的，而 `PartitionView` 只在 `revision` 变化时
    /// 才重算 body。缓存清了却不重画，界面上的数字就永远停在旧值上。
    /// 实测症状：`work` 分区磁盘上只有 10 项，徽标一直显示 11（几分钟都不动），
    /// 一直到用户碰了什么会触发 `updateUI` 的操作才自己纠正过来。
    func invalidateBadge(_ id: String) {
        badgeCounts.removeValue(forKey: id)
        badgeCountedAt.removeValue(forKey: id)
        revision += 1
    }

    /// portal 徽标该去数**哪个目录**：由 AppDelegate 注入（正在浏览子目录时 = 那个子目录）。
    ///
    /// 徽标压在列表正上方，两者必须是同一个数。数「配置里的根目录」时，
    /// 用户一进子目录就会出现「上面写 10、下面列 3 个」。
    /// 未注入时回退到根目录（单测 / 早期启动阶段）。
    var portalCountPath: ((_ id: String) -> String)?

    /// 整份配置被替换后作废**全部**视图侧缓存（并清掉已删分区的残留）。
    ///
    /// 必须显式调用，因为这类替换会一次性换掉全部数据：
    /// 启动加载、外部改写后的热重载、**导入配置备份**、**恢复历史快照**、删除分区。
    /// 漏掉的话界面会继续显示替换之前的旧数字（缓存键没变 → 命中旧缓存）。
    func invalidateAllViewCaches() {
        badgeCounts.removeAll()
        badgeCountedAt.removeAll()
    }

    /// 标题栏徽标展示模型
    struct BadgeInfo {
        let text: String
        let isAllDone: Bool
    }

    /// 标题栏文件数徽标（notes 不显示）。
    ///
    /// portal 走缓存（原因见上）；todo 直接数内存里的数组，没有 IO。
    func badgeCount(of id: String) -> Int? {
        switch str("type", of: id) ?? "" {
        case "portal":
            if let cached = badgeCounts[id], let at = badgeCountedAt[id],
               Date().timeIntervalSince(at) < Self.badgeFallbackTTL {
                return cached
            }
            let n = countDirectoryEntries(of: id)
            badgeCounts[id] = n
            badgeCountedAt[id] = Date()
            return n
        case "todo":
            return todos(of: id).filter { !$0.completed }.count
        default:
            return nil
        }
    }

    /// 标题栏徽标完整展示信息（支持 todo 的「已完成/总数」及全完成标记）
    func badgeInfo(of id: String) -> BadgeInfo? {
        switch str("type", of: id) ?? "" {
        case "portal":
            if let count = badgeCount(of: id) {
                return BadgeInfo(text: "\(count)", isAllDone: false)
            }
            return nil
        case "todo":
            let list = todos(of: id)
            guard !list.isEmpty else { return nil }
            let done = list.filter(\.completed).count
            let total = list.count
            return BadgeInfo(text: "\(done)/\(total)", isAllDone: done == total && total > 0)
        default:
            return nil
        }
    }

    /// 真正去列目录的那一步。
    /// ⚠️ 只应被 `badgeCount` 调用 —— 千万别在 body 路径上直接调它，那正是要消灭的开销。
    ///
    /// 口径走 `DirectoryScan`（与网格列表、自适应高度同一份），
    /// 别在这里再写一遍 `.filter { !$0.hasPrefix(".") }` —— 那就是分叉的开始。
    private func countDirectoryEntries(of id: String) -> Int {
        guard str("type", of: id) == "portal" else { return 0 }
        let path = portalCountPath?(id) ?? (str("folderPath", of: id) ?? "")
        return DirectoryScan.visibleCount(in: path)
    }

}

/// 待办条目视图模型。
struct TodoVM: Identifiable {
    let id: String
    let text: String
    let completed: Bool
    let priority: String
}

extension Config {
    func todos(of id: String) -> [TodoVM] {
        guard let p = partition(id), let arr = p["todos"] as? [[String: Any]] else { return [] }
        return arr.map {
            TodoVM(id: ($0["id"] as? String) ?? UUID().uuidString,
                   text: ($0["text"] as? String) ?? "",
                   completed: ($0["completed"] as? Bool) ?? false,
                   priority: ($0["priority"] as? String) ?? "medium")
        }
    }
}
