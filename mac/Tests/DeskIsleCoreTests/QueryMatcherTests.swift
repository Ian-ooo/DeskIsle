import XCTest
@testable import DeskIsleCore

/// 搜索匹配规则测试。
///
/// 打分档位（相等 > 前缀 > 子串 > 子序列）是**排序**的依据，必须稳定：
/// 用户搜「报告」时，名叫「报告」的分区文件应当排在「季度报告备份」前面。
final class QueryMatcherTests: XCTestCase {

    // MARK: - 空查询

    func testEmptyQueryMatchesNothing() {
        XCTAssertNil(QueryMatcher.score(query: "", candidate: "报告.pdf"))
        XCTAssertNil(QueryMatcher.score(query: "   ", candidate: "报告.pdf"))
        XCTAssertNil(QueryMatcher.score(query: "a", candidate: ""))
    }

    // MARK: - 档位优先级

    func testExactBeatsPrefixBeatsSubstring() {
        let exact = QueryMatcher.score(query: "报告", candidate: "报告")!
        let prefix = QueryMatcher.score(query: "报告", candidate: "报告终稿")!
        let substring = QueryMatcher.score(query: "报告", candidate: "季度报告")!
        XCTAssertGreaterThan(exact, prefix)
        XCTAssertGreaterThan(prefix, substring)
    }

    func testSubstringBeatsSubsequence() {
        let substring = QueryMatcher.score(query: "abc", candidate: "xxabcxx")!
        let subsequence = QueryMatcher.score(query: "abc", candidate: "axbxc")!
        XCTAssertGreaterThan(substring, subsequence)
    }

    func testEarlierHitScoresHigher() {
        let early = QueryMatcher.score(query: "报", candidate: "报告备份")!
        let late = QueryMatcher.score(query: "报", candidate: "备份报告")!
        XCTAssertGreaterThan(early, late)
    }

    func testTighterSubsequenceScoresHigher() {
        // "abc" 在 "abcx" 里跨度 2，在 "axbxc" 里跨度 4 —— 越紧凑越像用户想要的
        let tight = QueryMatcher.score(query: "abc", candidate: "abcx")!
        let loose = QueryMatcher.score(query: "abc", candidate: "axbxc")!
        XCTAssertGreaterThan(tight, loose)
    }

    // MARK: - 大小写

    func testCaseInsensitiveBothDirections() {
        XCTAssertNotNil(QueryMatcher.score(query: "pdf", candidate: "Report.PDF"))
        XCTAssertNotNil(QueryMatcher.score(query: "PDF", candidate: "report.pdf"))
        XCTAssertNotNil(QueryMatcher.score(query: "Desk", candidate: "deskisle.md"))
    }

    // MARK: - 子序列

    func testSubsequenceMatchesAcrossSeparators() {
        // 英文字母跨过破折号/点号："bt" 命中 "报告-backup.txt"（b 在 backup，t 在 .txt）
        XCTAssertNotNil(QueryMatcher.score(query: "bt", candidate: "报告-backup.txt"))
        XCTAssertNotNil(QueryMatcher.score(query: "dsl", candidate: "DeskIsle"))
        // 中文同理：「季报」命中「季度报告」
        XCTAssertNotNil(QueryMatcher.score(query: "季报", candidate: "季度报告"))
        // 但字符顺序不能反
        XCTAssertNil(QueryMatcher.score(query: "报季", candidate: "季度报告"))
    }

    func testSubsequenceRespectsOrder() {
        // 字符顺序反了就不是匹配 —— 否则「搜索」会退化成「随便打几个字都有结果」
        XCTAssertNil(QueryMatcher.score(query: "ba", candidate: "ab"))
        XCTAssertNil(QueryMatcher.score(query: "报告", candidate: "告报"))
    }

    func testMissingCharacterDoesNotMatch() {
        XCTAssertNil(QueryMatcher.score(query: "abc", candidate: "abd"))
        XCTAssertNil(QueryMatcher.score(query: "报告x", candidate: "季度报告"))
    }

    // MARK: - 边界

    func testSingleCharacterQueryMatchesManyButNeverCrashes() {
        // 单字查询语义上确实该命中很多，这里只保证不崩、且能给出得分
        XCTAssertNotNil(QueryMatcher.score(query: "a", candidate: "banana"))
        XCTAssertNotNil(QueryMatcher.score(query: "报", candidate: "报告"))
    }

    func testQueryLongerThanCandidateNeverMatches() {
        XCTAssertNil(QueryMatcher.score(query: "abcdef", candidate: "abc"))
    }

    func testQueryWithSurroundingWhitespaceIsTrimmed() {
        XCTAssertNotNil(QueryMatcher.score(query: "  报告  ", candidate: "报告"))
    }
}
