#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
比对两份 JSON：C# 直译（`csharp-crosscheck.py`）与 mac 真实实现（`CrosscheckDump`）。

mac 是功能基线，所以这一比就是「Windows 有没有跟上基线」。

用法：
  python3 compare.py mac.json cs.json

退出码 0 = 全部场景逐点一致；1 = 存在不一致（会把差异逐条打印出来）。
"""
import json
import sys


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    mac = load(sys.argv[1])
    cs = load(sys.argv[2])

    keys = sorted(set(mac) | set(cs))
    all_ok = True
    print(f"共 {len(keys)} 个场景")
    print("-" * 78)
    for k in keys:
        if k not in mac or k not in cs:
            print(f"XX {k:<40} 缺失（mac={'有' if k in mac else '无'} cs={'有' if k in cs else '无'}）")
            all_ok = False
            continue
        a, b = cs[k], mac[k]
        same_c = a["coords"] == b["coords"]
        same_h = a["colHeights"] == b["colHeights"]
        same_g = a["columns"] == b["columns"]
        ok = same_c and same_h and same_g
        all_ok &= ok
        print(f"{'OK' if ok else 'XX'} {k:<40} 坐标={same_c} 列高={same_h} 分组={same_g}"
              f"  列高={a['colHeights']}")
        if not same_c:
            for i in sorted(set(a["coords"]) | set(b["coords"])):
                if a["coords"].get(i) != b["coords"].get(i):
                    print(f"      坐标差异 {i}: C#={a['coords'].get(i)}  mac={b['coords'].get(i)}")
        if not same_g:
            print(f"      分组差异: C#={a['columns']}")
            print(f"                mac={b['columns']}")
    print("-" * 78)
    print("判定:", "两端逐点一致 ✔" if all_ok else "存在不一致 ✘（上面已列出差异）")
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
