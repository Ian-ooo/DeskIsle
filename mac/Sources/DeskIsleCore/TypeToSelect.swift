import Foundation

/// 映射文件夹的键盘首字母即时跳转（Type-to-Select）与方向键导航逻辑。
///
/// 纯函数设计，无平台 UI 依赖，跨 macOS / Windows 双端同源共用。
public struct TypeToSelect {
    public enum Direction: Sendable, Equatable {
        case up
        case down
        case left
        case right
    }

    /// 根据按键、当前缓冲区和候选列表，计算新的匹配项与更新后的缓冲区。
    ///
    /// - Parameters:
    ///   - char: 本次输入的字符（如 "a"、"2"、"文"）
    ///   - currentBuffer: 当前累积的搜索字符
    ///   - lastInputTime: 上一次字符输入的时间戳（秒）
    ///   - now: 当前时间戳（秒）
    ///   - timeout: 超时时间（默认 0.85 秒，超时后重新作为首字符累积）
    ///   - candidates: 候选项列表 [(name: 文件名, path: 完整路径)]
    ///   - currentSelectedPath: 当前选中的文件路径
    /// - Returns: `(newBuffer: String, matchedPath: String?)`
    public static func resolve(
        char: String,
        currentBuffer: String,
        lastInputTime: TimeInterval,
        now: TimeInterval,
        timeout: TimeInterval = 0.85,
        candidates: [(name: String, path: String)],
        currentSelectedPath: String?
    ) -> (newBuffer: String, matchedPath: String?) {
        guard !candidates.isEmpty, !char.isEmpty else {
            return (currentBuffer, nil)
        }

        let isExpired = (now - lastInputTime) > timeout
        let trimmedChar = char.lowercased()

        // 判定是否是「重复同一个单字符」：例如连续按 'a'，或者缓冲区全部是该字符且再按同一字符
        let isSingleCharRepeat: Bool
        if isExpired {
            isSingleCharRepeat = false
        } else {
            let combined = currentBuffer + trimmedChar
            isSingleCharRepeat = combined.allSatisfy { String($0) == trimmedChar }
        }

        if isSingleCharRepeat {
            // 单字符循环：在所有以该字符开头的项中，跳到下一项
            let matching = candidates.filter { $0.name.lowercased().hasPrefix(trimmedChar) }
            if !matching.isEmpty {
                if let cur = currentSelectedPath, let curIdx = matching.firstIndex(where: { $0.path == cur }) {
                    let nextIdx = (curIdx + 1) % matching.count
                    return (trimmedChar, matching[nextIdx].path)
                } else {
                    return (trimmedChar, matching[0].path)
                }
            }
        }

        let newBuffer: String
        if isExpired {
            newBuffer = trimmedChar
        } else {
            newBuffer = currentBuffer + trimmedChar
        }

        // 1. 优先前缀完全匹配（Prefix Match）
        if let prefixMatch = candidates.first(where: { $0.name.lowercased().hasPrefix(newBuffer) }) {
            return (newBuffer, prefixMatch.path)
        }

        // 2. 其次包含匹配（Substring Match）
        if let substringMatch = candidates.first(where: { $0.name.lowercased().contains(newBuffer) }) {
            return (newBuffer, substringMatch.path)
        }

        // 没有匹配项时，保留当前输入缓冲区但无命中
        return (newBuffer, nil)
    }

    /// 方向键导航索引计算。
    ///
    /// - Parameters:
    ///   - currentIndex: 当前选中项下标（若未选中则为 nil）
    ///   - direction: 方向（.up, .down, .left, .right）
    ///   - count: 总条目数
    ///   - columns: 网格列数（列表模式下传 1）
    /// - Returns: 目标索引
    public static func nextIndex(
        currentIndex: Int?,
        direction: Direction,
        count: Int,
        columns: Int = 1
    ) -> Int {
        guard count > 0 else { return -1 }
        let cols = max(1, columns)

        guard let cur = currentIndex, cur >= 0, cur < count else {
            switch direction {
            case .down, .right:
                return 0
            case .up, .left:
                return count - 1
            }
        }

        switch direction {
        case .up:
            return max(0, cur - cols)
        case .down:
            return min(count - 1, cur + cols)
        case .left:
            return max(0, cur - 1)
        case .right:
            return min(count - 1, cur + 1)
        }
    }
}
