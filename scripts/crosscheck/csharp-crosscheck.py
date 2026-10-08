#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把 Windows 端 `DeskIsle/Services/LayoutEngine.cs` **逐行直译**成 Python，
与 mac 端 `DeskIsleLayout/LayoutEngine.swift` 的真实实现（**功能基线**）交叉对拍。

目的：两端布局一旦在语义上漂移（分组不同、列数策略不同、left/right 不再互为镜像），
各端的单测都抓不到 —— 单测各测各的实现，测不出「两端不一致」。
用「源码直译 + 对拍」把这件事兜住：只要有任意一行译错，坐标就会对不上。

用法：
  python3 csharp-crosscheck.py -o /tmp/cs.json     # 输出 C# 直译的结果（默认打到 stdout）
  python3 compare.py /tmp/mac.json /tmp/cs.json    # 与 mac 基线逐点比对
  bash run.sh                                       # 上面两步串起来

⚠️ **改动 Windows `DeskIsle/Services/LayoutEngine.cs` 后必须同步本文件**，
否则「对拍通过」只是幻觉 —— 对拍比的是**源码**，不是磁盘上的 C#。
"""
import json
import sys
from itertools import accumulate

# ─── Windows LayoutEngine.cs 常量 ────────────────────────────────────────────
DEFAULT_PARTITION_WIDTH = 280.0
MARGIN = 16.0
GAP = 16.0
COLLAPSED_HEIGHT = 44.0
FALLBACK_HEIGHT = 200.0
MIN_AVAIL_HEIGHT = 200.0

INF = float("inf")


class NonIncreasing:
    pass


# ColumnHeightOrder
ORDER_NON_INCREASING = "nonIncreasing"
ORDER_NON_DECREASING = "nonDecreasing"


def height_order_violation(order, prev, cur):
    # private static double HeightOrderViolation(order, prev, cur)
    return max(0.0, cur - prev) if order == ORDER_NON_INCREASING else max(0.0, prev - cur)


def key3(max_h, min_h, viol, sq):
    """(double,double,double) Key(...) => (maxH - minH, viol, sq)"""
    return (max_h - min_h, viol, sq)


def greedy_fill_column_ranges(count, gap, height_at, max_group_height):
    """public static List<(int Start,int End)> GreedyFillColumnRanges(...) 的直译

    逐列填满：除最后一列外，每列都是「再塞一条就会超出」的状态。
    ⚠️ 判空用 i == start 而非 cur == 0（高度为 0 会让后者漏加 gap）。
    """
    ranges = []
    if count <= 0:
        return ranges
    start = 0
    cur = 0.0
    for i in range(count):
        h = height_at(i)
        add = h if i == start else h + gap
        if i > start and cur + add > max_group_height + 1e-9:
            ranges.append((start, i))
            start = i
            cur = h
        else:
            cur += add
    ranges.append((start, count))
    return ranges


def balanced_column_ranges(count, columns, gap, height_at,
                           max_group_height=INF, order=ORDER_NON_INCREASING):
    """public static List<(int Start,int End)> BalancedColumnRanges(...) 的直译"""
    ranges = []
    if count <= 0:
        return ranges

    k = max(1, min(columns, count))
    if k == 1:
        return [(0, count)]
    if k == count:
        return [(i, i + 1) for i in range(count)]

    prefix = [0.0] * (count + 1)
    for i in range(count):
        prefix[i + 1] = prefix[i] + height_at(i)

    def group_height(i, j):
        return prefix[j] - prefix[i] + (j - i - 1) * gap

    def feasible(i, j):
        return j - i == 1 or group_height(i, j) <= max_group_height + 1e-9

    side = count + 2

    def slot(c, s, e):
        return (c * side + s) * side + e

    slots = (k + 2) * side * side
    best_max = [INF] * slots
    best_min = [INF] * slots
    best_viol = [INF] * slots
    best_sq = [INF] * slots
    prev_start = [-1] * slots

    # 1 组
    for e in range(1, count + 1):
        if not feasible(0, e):
            continue
        g = group_height(0, e)
        sl = slot(1, 0, e)
        best_max[sl] = g
        best_min[sl] = g
        best_viol[sl] = 0.0
        best_sq[sl] = g * g
        prev_start[sl] = -1

    if k > 1:
        for c in range(2, k + 1):
            for s in range(c - 1, count):
                last_end = count - (k - c)
                if s + 1 > last_end:
                    continue
                for e in range(s + 1, last_end + 1):
                    if not feasible(s, e):
                        continue
                    g = group_height(s, e)
                    chosen = -1
                    kk = (INF, INF, INF)
                    for ps in range(c - 2, s):
                        prev = slot(c - 1, ps, s)
                        if best_max[prev] == INF:
                            continue
                        viol = best_viol[prev] + height_order_violation(
                            order, group_height(ps, s), g)
                        cand = key3(max(best_max[prev], g), min(best_min[prev], g),
                                    viol, best_sq[prev] + g * g)
                        if cand < kk:                      # CompareTo < 0
                            kk = cand
                            chosen = ps
                    if chosen < 0:
                        continue
                    prev_sl = slot(c - 1, chosen, s)
                    sl = slot(c, s, e)
                    best_max[sl] = max(best_max[prev_sl], g)
                    best_min[sl] = min(best_min[prev_sl], g)
                    best_viol[sl] = best_viol[prev_sl] + height_order_violation(
                        order, group_height(chosen, s), g)
                    best_sq[sl] = best_sq[prev_sl] + g * g
                    prev_start[sl] = chosen

    best_start = -1
    best_key = (INF, INF, INF)
    for s in range(k - 1, count):
        sl = slot(k, s, count)
        if best_max[sl] == INF:
            continue
        cand = key3(best_max[sl], best_min[sl], best_viol[sl], best_sq[sl])
        if cand < best_key:
            best_key = cand
            best_start = s
    if best_start < 0:
        return [(0, count)]

    end = count
    start = best_start
    for c in range(k, 0, -1):
        ranges.append((start, end))
        ps = prev_start[slot(c, start, end)]
        end = start
        start = ps if ps >= 0 else 0
    ranges.reverse()
    return ranges


def minimum_feasible_column_count(count, gap, height_at, max_group_height):
    """public static int MinimumFeasibleColumnCount(...) 的直译"""
    if count <= 0:
        return 0
    cols = 1
    cur = 0.0
    for i in range(count):
        h = height_at(i)
        add = h if cur == 0 else h + gap
        if cur > 0 and cur + add > max_group_height + 1e-9:
            cols += 1
            cur = h
        else:
            cur += add
    return cols


def column_heights_of(cols, height_provider, gap):
    return [sum(height_provider(x) for x in c) + max(0, len(c) - 1) * gap for c in cols]


def sort_columns_by_height(cols, height_provider, gap):
    hs = column_heights_of(cols, height_provider, gap)
    # OrderByDescending(h).ThenBy(i)
    return [c for _, _, c in sorted(
        ((i, -hs[i], c) for i, c in enumerate(cols)), key=lambda t: (t[1], t[0]))]


def column_placements(sorted_ids, part_map, get_eff_h, get_w,
                      screen_width, avail_h, avail_w, top_margin,
                      from_right, count_mode, max_columns,
                      sort_by_height=False):
    """private static ColumnPlacements(...) 的直译

    ⚠️ 注意 C# 里 `sortedIds = flat` 会**原地改写被闭包捕获的变量**，
    Python 里 `HeightAt/WidthAt` 必须每次读最新的 `sorted_ids`（用 nonlocal 语义）。
    """
    if not sorted_ids:
        return {}

    def height_at(i):
        return get_eff_h(part_map[sorted_ids[i]])

    def width_at(i):
        return get_w(part_map[sorted_ids[i]])

    ranges = []
    if count_mode == "atMost":
        # ⚠️ 「尽量多列」与「每列不超出屏幕」的对策方向相反（列越多每列越矮）：
        # 高度超了要**加**列，宽度超了才减列。所以先把下限抬到 min_cols。
        target_cols = max(1, min(len(sorted_ids), max(1, max_columns)))
        min_cols = minimum_feasible_column_count(
            len(sorted_ids), GAP, height_at, avail_h)
        num_cols = min(len(sorted_ids), max(target_cols, min_cols))
        while True:
            candidate = balanced_column_ranges(
                len(sorted_ids), num_cols, GAP, height_at, max_group_height=avail_h)
            total_w = 0.0
            for r in candidate:
                m = 0.0
                for i in range(r[0], r[1]):
                    m = max(m, width_at(i))
                total_w += (m if m > 0 else DEFAULT_PARTITION_WIDTH) + GAP
            total_w -= GAP
            ranges = candidate
            if total_w <= avail_w or num_cols <= min_cols:
                break
            num_cols -= 1
    else:
        # 「左侧 / 右侧纵向对齐」= **逐列填满**（对齐 LayoutEngine.cs 的 GreedyFillColumnRanges）
        ranges = greedy_fill_column_ranges(
            len(sorted_ids), GAP, height_at, avail_h)

    if sort_by_height:
        grouped = [sorted_ids[r[0]:r[1]] for r in ranges]
        sorted_cols = sort_columns_by_height(grouped, lambda i: get_eff_h(part_map[i]), GAP)
        flat = [x for c in sorted_cols for x in c]
        new_ranges = []
        cursor = 0
        for c in sorted_cols:
            new_ranges.append((cursor, cursor + len(c)))
            cursor += len(c)
        sorted_ids = flat            # ← 闭包后续读到的就是新的
        ranges = new_ranges

    col_widths = []
    for r in ranges:
        m = 0.0
        for i in range(r[0], r[1]):
            m = max(m, width_at(i))
        col_widths.append(m if m > 0 else DEFAULT_PARTITION_WIDTH)

    col_x = [0.0] * len(ranges)
    if from_right:
        col_x[0] = (screen_width - MARGIN) - col_widths[0]
        for c in range(1, len(ranges)):
            col_x[c] = col_x[c - 1] - GAP - col_widths[c]
    else:
        col_x[0] = MARGIN
        for c in range(1, len(ranges)):
            col_x[c] = col_x[c - 1] + col_widths[c - 1] + GAP

    result = {}
    for c, r in enumerate(ranges):
        cur_y = top_margin
        for i in range(r[0], r[1]):
            _id = sorted_ids[i]
            w = width_at(i)
            x = col_x[c] + (col_widths[c] - w) if from_right else col_x[c]
            result[_id] = (x, cur_y)
            cur_y += height_at(i) + GAP
    return result


def calculate_layout(mode, partitions, screen_width, screen_height,
                     top_margin=76.0, bottom_margin=32.0,
                     max_columns=6, top_height_order="leftToRight"):
    """public static CalculateLayout(...) 的直译

    partitions: list of dict(id, x, y, w, h, isCollapsed)
    """
    if not partitions:
        return {}
    avail_w = screen_width - 2 * MARGIN
    avail_h = max(MIN_AVAIL_HEIGHT, screen_height - top_margin - bottom_margin)

    def get_eff_h(p):
        return COLLAPSED_HEIGHT if p.get("isCollapsed") else (p["h"] if p.get("h", 0) > 0 else FALLBACK_HEIGHT)

    def get_w(p):
        return p["w"] if p.get("w", 0) > 0 else DEFAULT_PARTITION_WIDTH

    part_map = {p["id"]: p for p in partitions}
    lower = mode.lower()

    is_column_mode = lower in ("left", "top", "right")
    if is_column_mode:
        if lower == "top":
            sorted_ids = [p["id"] for p in partitions]      # 配置顺序
        else:
            min_x = min(p["x"] for p in partitions)
            max_right = max(p["x"] + get_w(p) for p in partitions)
            read_from_right = (screen_width - MARGIN - max_right) < (min_x - MARGIN)
            index_of = {p["id"]: i for i, p in enumerate(partitions)}

            def cmp_key(p):
                # C# 的 Sort 用比较器，这里用「(X 方向序, Y, 原序)」等价表达
                return (-(p["x"]) if read_from_right else p["x"], p["y"], index_of[p["id"]])

            # ⚠️ C# 里 X 差 >60 才算不同列；用 key 直接排序会丢掉这个阈值，
            # 因此这里手工复刻比较器（同一列内按 Y，再按原序）
            def gt(a, b):
                if abs(a["x"] - b["x"]) > 60:
                    return (a["x"] > b["x"]) if read_from_right else (a["x"] < b["x"])
                if abs(a["y"] - b["y"]) > 1:
                    return a["y"] < b["y"]
                return index_of[a["id"]] < index_of[b["id"]]

            import functools
            sorted_ids = [p["id"] for p in sorted(
                partitions, key=functools.cmp_to_key(lambda a, b: -1 if gt(a, b) else (1 if gt(b, a) else 0)))]
    else:
        index_of = {p["id"]: i for i, p in enumerate(partitions)}
        sorted_ids = [p["id"] for p in sorted(
            partitions, key=lambda p: (round(p["y"]), round(p["x"]), index_of[p["id"]]))]

    result = {}
    if not is_column_mode:
        # grid
        num_cols = max(1, min(len(sorted_ids), max(4, min(8, max_columns))))
        while num_cols > 1:
            max_w = [0.0] * num_cols
            for idx, sid in enumerate(sorted_ids):
                max_w[idx % num_cols] = max(max_w[idx % num_cols], get_w(part_map[sid]))
            if sum(max_w) + (num_cols - 1) * GAP <= avail_w:
                break
            num_cols -= 1
        rows = [sorted_ids[i:i + num_cols] for i in range(0, len(sorted_ids), num_cols)]
        col_widths = []
        for c in range(num_cols):
            items = [r[c] for r in rows if c < len(r)]
            col_widths.append(max([get_w(part_map[i]) for i in items], default=DEFAULT_PARTITION_WIDTH))
        col_x = [MARGIN]
        for c in range(1, num_cols):
            col_x.append(col_x[c - 1] + col_widths[c - 1] + GAP)
        cur_y = top_margin
        for row in rows:
            row_max_h = max([get_eff_h(part_map[i]) for i in row], default=FALLBACK_HEIGHT)
            for c, sid in enumerate(row):
                result[sid] = (col_x[c], cur_y)
            cur_y += row_max_h + GAP
        return result

    is_top = lower == "top"
    count_mode = "atMost" if is_top else "minimumFeasible"
    column_limit = max(4, min(8, max_columns)) if is_top else max_columns
    from_right = (top_height_order.lower() == "righttoleft") if is_top else (lower == "right")

    result.update(column_placements(
        sorted_ids, part_map, get_eff_h, get_w,
        screen_width, avail_h, avail_w, top_margin,
        from_right, count_mode, column_limit, sort_by_height=is_top))
    return result


# ─── 固定搭配 ────────────────────────────────────────────────────────────────
def column_height_summary(result, ids, h_at):
    """按 x 分组 → 每列的总高度（含组内 gap），用于核对阶梯"""
    by_x = {}
    for i in ids:
        x, y = result[i]
        by_x.setdefault(round(x, 3), []).append((y, i))
    cols = []
    for x in sorted(by_x):
        members = sorted(by_x[x], key=lambda t: t[0])
        hs = [h_at(i) for _, i in members]
        cols.append((x, sum(hs) + (len(hs) - 1) * GAP, [i for _, i in members]))
    return cols


def SCENARIOS():
    """三组初始布局 —— left / right 的读序取决于「当前贴哪一边」，所以贴左、贴右都要覆盖；
    第三组「超高」是本轮修复的复现件。

    ⚠️ mac 侧（`Sources/CrosscheckDump/main.swift`）必须用**完全相同**的固件，
    否则对拍比对的是两份不同的输入。
    """
    HS = [316, 150, 150, 150, 314, 428, 610]
    # 场景 3「超高」：7 条里 5 条是 900 高，`availH = 1060`。
    # 旧的 top 分支不传 max_group_height、也只看宽度，于是 5 列 maxColumns 会被照单全收；
    # 无约束 DP 为了极差最小必然选 {500,900}/{500,900}/{900}/{900}/{900}
    # = 1416/1416/900/900/900，两条列超出屏幕底部 356pt。
    # 「每列不超过 availH」所需的最少列数是 6，加列之后才是合规的 1016/900/900/900/900/900。
    # ⚠️ 高度超了要**加**列（与宽度超了减列方向相反）—— 本轮最容易写反的一处。
    TALL = [500, 500, 900, 900, 900, 900, 900]
    W = 316

    def layout(hs, tag):
        return [
            {"id": f"{tag}{i}", "x": 16 + (i % 5) * (W + 16), "y": 100 + (i // 5) * 500,
             "w": W, "h": hs[i], "isCollapsed": False}
            for i in range(len(hs))
        ]

    base = layout(HS, "t")
    # 贴右版本：每个分区关于屏幕中线镜像（右边距 = 左边距）
    mirrored = [dict(p, x=1920 - (p["x"] - 16) - W) for p in base]
    return [("贴左初值", base), ("贴右初值", mirrored), ("超高初值", layout(TALL, "s"))]


def main():
    out = {}
    for scene, parts in SCENARIOS():
        ids = [p["id"] for p in parts]
        hmap = {p["id"]: p["h"] for p in parts}
        for mode in ("top", "left", "right", "grid"):
            for order in (("leftToRight", "rightToLeft") if mode == "top" else ("leftToRight",)):
                r = calculate_layout(mode, parts, 1920, 1200, top_margin=100,
                                     bottom_margin=40, max_columns=5, top_height_order=order)
                key = f"{scene}/{mode}" + (f"/{order}" if mode == "top" else "")
                cols = column_height_summary(r, ids, lambda i: hmap[i])
                out[key] = {
                    "coords": {i: [round(r[i][0], 6), round(r[i][1], 6)] for i in ids},
                    "colHeights": [round(c[1], 6) for c in cols],
                    "columns": [c[2] for c in cols],
                }

    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--out", help="写入 JSON 文件路径（默认打印到 stdout）")
    args = ap.parse_args()
    text = json.dumps(out, ensure_ascii=False, indent=1)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(text + "\n")
        print(f"已写入 {args.out}（{len(out)} 个场景）")
    else:
        print(text)


if __name__ == "__main__":
    main()
