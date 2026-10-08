using System;
using System.Collections.Generic;
using System.Linq;

namespace DeskIsle.Services
{
    public enum TypeToSelectDirection
    {
        Up,
        Down,
        Left,
        Right
    }

    /// <summary>
    /// 映射文件夹键盘首字母即时跳转（Type-to-Select）与方向键导航逻辑。
    /// 纯函数设计，跨 macOS / Windows 双端同源共用。
    /// </summary>
    public static class TypeToSelect
    {
        public static (string newBuffer, string? matchedPath) Resolve(
            string ch,
            string currentBuffer,
            double lastInputTimeSeconds,
            double nowSeconds,
            IReadOnlyList<(string name, string path)> candidates,
            string? currentSelectedPath,
            double timeout = 0.85)
        {
            if (candidates == null || candidates.Count == 0 || string.IsNullOrEmpty(ch))
            {
                return (currentBuffer, null);
            }

            bool isExpired = (nowSeconds - lastInputTimeSeconds) > timeout;
            string trimmedChar = ch.ToLowerInvariant();

            bool isSingleCharRepeat;
            if (isExpired)
            {
                isSingleCharRepeat = false;
            }
            else
            {
                string combined = currentBuffer + trimmedChar;
                isSingleCharRepeat = combined.All(c => c.ToString().ToLowerInvariant() == trimmedChar);
            }

            if (isSingleCharRepeat)
            {
                var matching = candidates
                    .Where(c => c.name.ToLowerInvariant().StartsWith(trimmedChar, StringComparison.OrdinalIgnoreCase))
                    .ToList();
                if (matching.Count > 0)
                {
                    if (currentSelectedPath != null)
                    {
                        int curIdx = matching.FindIndex(m => m.path == currentSelectedPath);
                        if (curIdx >= 0)
                        {
                            int nextIdx = (curIdx + 1) % matching.Count;
                            return (trimmedChar, matching[nextIdx].path);
                        }
                    }
                    return (trimmedChar, matching[0].path);
                }
            }

            string newBuffer = isExpired ? trimmedChar : currentBuffer + trimmedChar;

            // 1. Prefix match
            var prefixMatch = candidates.FirstOrDefault(c => c.name.ToLowerInvariant().StartsWith(newBuffer, StringComparison.OrdinalIgnoreCase));
            if (!string.IsNullOrEmpty(prefixMatch.path))
            {
                return (newBuffer, prefixMatch.path);
            }

            // 2. Substring match
            var substringMatch = candidates.FirstOrDefault(c => c.name.ToLowerInvariant().Contains(newBuffer, StringComparison.OrdinalIgnoreCase));
            if (!string.IsNullOrEmpty(substringMatch.path))
            {
                return (newBuffer, substringMatch.path);
            }

            return (newBuffer, null);
        }

        public static int NextIndex(
            int? currentIndex,
            TypeToSelectDirection direction,
            int count,
            int columns = 1)
        {
            if (count <= 0) return -1;
            int cols = Math.Max(1, columns);

            if (!currentIndex.HasValue || currentIndex.Value < 0 || currentIndex.Value >= count)
            {
                return (direction == TypeToSelectDirection.Down || direction == TypeToSelectDirection.Right)
                    ? 0
                    : count - 1;
            }

            int cur = currentIndex.Value;
            return direction switch
            {
                TypeToSelectDirection.Up => Math.Max(0, cur - cols),
                TypeToSelectDirection.Down => Math.Min(count - 1, cur + cols),
                TypeToSelectDirection.Left => Math.Max(0, cur - 1),
                TypeToSelectDirection.Right => Math.Min(count - 1, cur + 1),
                _ => cur
            };
        }
    }
}
