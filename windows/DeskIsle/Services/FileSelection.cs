using System;
using System.Collections.Generic;
using System.Linq;

namespace DeskIsle.Services
{
    /// <summary>
    /// ⭐ 文件夹类分区（portal）内条目「点击 → 选中」的判据 —— 纯逻辑（不碰 WPF），三端同源。
    ///
    /// 为什么单独抽出来：选中看着只是「画个高亮」，但四条边界**很容易写歪且必须三端一致**：
    /// 一旦写歪，用户会遇到「点了没反应」「多选了一堆却只高亮一个」这类极难复述的毛病。
    ///
    /// 1. <b>⇧ 区间选中锚在「上一次点过的那条」上</b>，不是「上一次选中的那条」——
    ///    否则 ⇧ 连点两次会把自己也算进去，区间越缩越小。
    /// 2. <b>锚点失效时 ⇧ 退化为单击</b>（不能什么都不做）：换目录、锚点被过滤掉都会发生。
    /// 3. <b>Ctrl 点是切换</b>（toggle），不是「加进来」—— 再点一次要能取消。
    /// 4. <b>刷新后只保留还活着的条目</b>：文件在别处被删掉后，选中集里留着幽灵路径。
    ///
    /// 对应实现：mac <c>DeskIsleCore/FileSelection.swift</c>、Electron <c>utils/fileSelection.ts</c>。
    /// </summary>
    public class FileSelection
    {
        // 路径比较大小写敏感：Windows 上同一个目录里不会只靠大小写区分两个文件，
        // 而 Ordinal 比 OrdinalIgnoreCase 更快也更可预测（与另两端的行为一致）。
        private readonly HashSet<string> _selected = new(StringComparer.Ordinal);
        private string? _anchor;

        /// <summary>当前选中的**路径**（不是条目 id：目录每次刷新都会重建条目）。</summary>
        public IReadOnlyCollection<string> Selected => _selected;

        public int Count => _selected.Count;

        public bool Contains(string path) => _selected.Contains(path);

        public void Clear()
        {
            _selected.Clear();
            _anchor = null;
        }

        /// <summary>
        /// 只保留仍然存在的条目（目录刷新后调用）。
        ///
        /// ⚠️ 传**未过滤**的完整列表：搜索框里打字的瞬间，被过滤掉的文件不该被取消选中，
        /// 否则一退格选区就空了。
        /// </summary>
        public void Retain(IEnumerable<string> alive)
        {
            var aliveSet = new HashSet<string>(alive, StringComparer.Ordinal);
            _selected.RemoveWhere(p => !aliveSet.Contains(p));
            if (_anchor != null && !aliveSet.Contains(_anchor)) _anchor = null;
        }

        /// <summary>
        /// 点击某一条。
        /// </summary>
        /// <param name="path">被点的条目路径。</param>
        /// <param name="visible">当前**可见且有序**的路径列表（过滤 + 排序之后）；
        /// ⇧ 区间就是按这个顺序取的 —— 传错顺序会得到反的区间。</param>
        /// <param name="ctrl">是否按住 Ctrl（切换选中）。mac 上是 ⌘。</param>
        /// <param name="shift">是否按住 Shift（区间选中）。</param>
        public void Click(string path, IReadOnlyList<string> visible, bool ctrl = false, bool shift = false)
        {
            // ⇧ 区间：锚点必须**还在这个列表里**，否则退化为单击。
            if (shift && _anchor != null)
            {
                int ai = IndexOf(visible, _anchor);
                int ci = IndexOf(visible, path);
                if (ai >= 0 && ci >= 0)
                {
                    int lo = Math.Min(ai, ci), hi = Math.Max(ai, ci);
                    _selected.Clear();
                    for (int i = lo; i <= hi; i++) _selected.Add(visible[i]);
                    // 锚点不动：连续 ⇧ 点可以从同一个起点反复调整区间
                    return;
                }
            }

            if (ctrl)
            {
                if (!_selected.Add(path)) _selected.Remove(path);
                _anchor = path;
                return;
            }

            _selected.Clear();
            _selected.Add(path);
            _anchor = path;
        }

        // MARK: - 选区顺序与右键目标（三端同源）

        /// <summary>
        /// 把选区按<strong>当前显示顺序</strong>重排。
        /// <para>
        /// <c>Selected</c> 是无序集合 —— 批量操作的先后、提示里列出的文件名
        /// 不能跟着集合的内部顺序乱跳，一律按显示顺序归一。
        /// </para>
        /// </summary>
        public List<string> OrderedSelection(IReadOnlyList<string> visible)
        {
            var result = new List<string>();
            foreach (var p in visible)
            {
                if (_selected.Contains(p)) result.Add(p);
            }
            return result;
        }

        /// <summary>
        /// <strong>右键菜单的作用目标</strong> —— 对齐资源管理器：点在已选中的条目上时
        /// 菜单作用于<strong>整个选区</strong>，否则只作用于右键戳到的那一个。
        /// <para>
        /// ⚠️ 后者不能省：「右键别的文件顺手删一下」不该连坐一堆不相干的东西。
        /// </para>
        /// </summary>
        public List<string> MenuTargets(string clicked, IReadOnlyList<string> visible)
        {
            if (!_selected.Contains(clicked)) return new List<string> { clicked };
            var ordered = OrderedSelection(visible);
            // 极端情况（选区里的东西全被过滤掉了）：退回只操作点到的那一个，不要返回空。
            return ordered.Count > 0 ? ordered : new List<string> { clicked };
        }

        private static int IndexOf(IReadOnlyList<string> list, string value)
        {
            for (int i = 0; i < list.Count; i++)
            {
                if (string.Equals(list[i], value, StringComparison.Ordinal)) return i;
            }
            return -1;
        }
    }
}
