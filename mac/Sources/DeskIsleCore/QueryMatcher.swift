import Foundation

/// 搜索查询的匹配与打分。
///
/// 抽成独立纯函数是为了**能被断言**：匹配规则是最容易「看起来对、实际很别扭」的一类逻辑 ——
/// 大小写没归一化、空查询匹配全部、子序列太宽松导致搜 `a` 就命中一大堆，
/// 这些问题在界面上只会表现为「搜索结果怪怪的」，很难反推到代码。
public enum QueryMatcher {

    /// 候选串对查询串的匹配得分；返回 `nil` 表示不匹配。
    ///
    /// 规则（越靠前的档位得分越高，同级按命中位置靠前优先）：
    /// 1. **完全相等** —— 1000
    /// 2. **前缀命中** —— 800
    /// 3. **包含子串** —— 600 − 起始位置
    /// 4. **子序列命中** —— 300 − 跨度 − 起始位置（如 `bg` 命中 `报告-backup`）
    ///
    /// 一律大小写不敏感（`pdf` 应命中 `Report.PDF`）。
    /// 空查询**不匹配任何东西** —— 返回全部会让「搜索框还是空的」看起来像卡住了。
    public static func score(query: String, candidate: String) -> Int? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }
        let c = candidate.lowercased()
        guard !c.isEmpty else { return nil }

        if c == q { return 1000 }
        if c.hasPrefix(q) { return 800 }

        if let r = c.range(of: q) {
            let offset = c.distance(from: c.startIndex, to: r.lowerBound)
            return 600 - offset
        }

        // 子序列匹配：逐字符在候选串中找下一个出现位置
        var idx = c.startIndex
        var firstHit: Int?
        var lastHit = 0
        for ch in q {
            guard let found = c[idx...].firstIndex(of: ch) else { return nil }
            let pos = c.distance(from: c.startIndex, to: found)
            if firstHit == nil { firstHit = pos }
            lastHit = pos
            idx = c.index(after: found)
        }
        guard let start = firstHit else { return nil }
        let span = lastHit - start
        return 300 - span - start
    }

    /// 是否匹配（不关心得分时的便捷入口）。
    public static func matches(query: String, candidate: String) -> Bool {
        score(query: query, candidate: candidate) != nil
    }
}
