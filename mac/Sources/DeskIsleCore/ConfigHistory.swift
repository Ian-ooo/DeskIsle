import Foundation

/// 配置历史快照的**生成判据** —— 纯逻辑，与具体的文件读写分离。
///
/// 拆出来的原因同 DeskIsleCore 的其它成员：executableTarget 无法被 testTarget 导入，
/// 而这里恰是「注释与 UI 都承诺了可回滚、实际应用却被闸门吃掉」的地方 ——
/// 这类错不会报错，只表现为「用户点了恢复、发现回不去了」。
public enum ConfigHistory {

    /// 这次保存要不要留下一份历史快照。
    ///
    /// - `force = false`（常规路径）：按 `minInterval` 节流。拖动分区、连续调设置都会
    ///   高频触发保存，没有闸门会把仅有的 20 份名额在几秒内用完。
    /// - `force = true`：**忽略**间隔闸门，必须留档。
    ///
    /// ## force 为什么存在（改之前请先读完）
    /// 「恢复历史快照」的流程是「先把当前状态存成快照，再用旧快照覆盖」。
    /// 而用户点恢复的时刻，往往**刚刚**才发生过一次普通保存（删分区、拖动都会立刻落盘），
    /// 于是这一步走了闸门会被判「距上次太近」而直接 return —— 快照没写成，
    /// 覆盖照样发生，UI 上承诺的「之后仍可再恢复回来」当场失效。
    /// 「覆盖别人的前一刻」必须无条件留底，这是 force 唯一的用途。
    public static func shouldSnapshot(now: Date,
                                      lastHistoryAt: Date,
                                      minInterval: TimeInterval,
                                      force: Bool) -> Bool {
        guard minInterval > 0 else { return true }      // 关掉节流时每次都留
        return force || now.timeIntervalSince(lastHistoryAt) >= minInterval
    }

    /// 快照文件名。同一秒内可能已经存在一份（forced 快照尤其容易撞 —— 它恰恰发生在
    /// 刚保存过之后），`copyItem` 到已存在的目标会**静默失败**（`try?`），快照就丢了，
    /// 而且丢得毫无痕迹：既覆盖了旧配置，又没有留下可回滚的那一版。
    ///
    /// - `collisionIndex = 0`：裸名（历史文件就是这个形态，保持向后兼容）。
    /// - `collisionIndex > 0`：追加 `_n`。
    ///
    /// ⚠️ 分隔符必须是 `_` 而不是 `-`：文件名本身就是时间轴，
    /// `availableHistory()` 靠**字符串倒序**取「最新的一份」。
    /// `_`(0x5F) > `.`(0x2E) > `-`(0x2D)，所以 `-20261009-081530_1.json` > `-20261009-081530.json`，
    /// 同一秒里**后**写的那份才会被排到最前 —— 取到的正是用户刚留的底。
    /// 换成 `-1` 就会反过来（`-` < `.`），倒序时会取到同秒内更早的那份。
    public static func snapshotFileName(base: String, collisionIndex: Int) -> String {
        let stamp = collisionIndex == 0 ? base : "\(base)_\(collisionIndex)"
        return "deskisle_config-\(stamp).json"
    }
}
