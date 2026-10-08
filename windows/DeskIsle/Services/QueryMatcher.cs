using System;

namespace DeskIsle.Services
{
    /// <summary>
    /// 全局搜索的模糊匹配打分 —— 与 mac 端 <c>DeskIsleCore/QueryMatcher.swift</c>
    /// 和 Electron 端 <c>src/utils/queryMatcher.ts</c> 使用<b>同一套档位</b>，
    /// 保证三端「搜同一个词，排出同一个顺序」。
    ///
    /// 抽成独立纯函数是为了**可断言**：匹配规则属于「看起来对、实际很别扭」的一类逻辑 ——
    /// 大小写没归一化、空查询匹配全部、子序列太宽松导致搜一个字符就命中一大堆，
    /// 这些问题在界面上只表现为「搜索结果怪怪的」，很难反推到代码。
    ///
    /// 分档（越靠前得分越高，同级按命中位置靠前优先）：
    ///   1. 完全相等        —— 1000
    ///   2. 前缀命中        —— 800
    ///   3. 包含子串        —— 600 − 起始位置
    ///   4. 子序列命中      —— 300 − 跨度 − 起始位置（如 <c>bg</c> 命中 <c>报告-backup</c>）
    ///
    /// 一律**大小写不敏感**（<c>pdf</c> 应命中 <c>Report.PDF</c>）。
    /// 空查询**不匹配任何东西** —— 返回全部会让「搜索框还是空的」看起来像卡住了。
    /// </summary>
    public static class QueryMatcher
    {
        public const int MatchExact = 1000;
        public const int MatchPrefix = 800;
        public const int MatchSubstring = 600;
        public const int MatchSubsequence = 300;

        /// <summary>候选串对查询串的匹配得分；返回 null 表示不匹配。</summary>
        public static int? MatchScore(string? query, string? candidate)
        {
            // ToLowerInvariant 而非 ToLower：搜索是纯比较，不该受系统区域设置影响
            // （土耳其语区域下 ToLower('I') 会得到 'ı'，同一个查询在两种系统语言下结果不同）。
            string q = (query ?? string.Empty).Trim().ToLowerInvariant();
            if (q.Length == 0) return null;

            string c = (candidate ?? string.Empty).ToLowerInvariant();
            if (c.Length == 0) return null;

            if (string.Equals(c, q, StringComparison.Ordinal)) return MatchExact;
            if (c.StartsWith(q, StringComparison.Ordinal)) return MatchPrefix;

            int at = c.IndexOf(q, StringComparison.Ordinal);
            if (at >= 0) return MatchSubstring - at;

            // 子序列匹配：逐字符在候选串中找「下一个」出现位置。
            // 必须按顺序找（cursor 只前进不后退），否则 `报季` 也会命中 `季度报告`。
            int cursor = 0;
            int firstHit = -1;
            int lastHit = 0;
            foreach (char ch in q)
            {
                int found = c.IndexOf(ch, cursor);
                if (found < 0) return null;
                if (firstHit < 0) firstHit = found;
                lastHit = found;
                cursor = found + 1;
            }
            if (firstHit < 0) return null;

            int span = lastHit - firstHit;
            return MatchSubsequence - span - firstHit;
        }

        /// <summary>是否匹配（不关心得分时的便捷入口）。</summary>
        public static bool Matches(string? query, string? candidate) => MatchScore(query, candidate).HasValue;
    }
}
