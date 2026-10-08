#!/usr/bin/env bash
#
# 一键交叉对拍：mac `LayoutEngine.swift`（**真实实现** = 功能基线）
#   vs Windows `LayoutEngine.cs`（Python 逐行直译）。
#
# 两端布局一旦在语义上漂移（分组不同、列数策略不同、镜像不成立），
# 坐标就会对不上 —— 这是单测抓不到的：单测各测各的实现，测不出「两端不一致」。
#
# 用法：
#   bash scripts/crosscheck/run.sh
#
# ⚠️ 改动任一端后都要重新对拍：
#   · 改 mac   `Sources/DeskIsleLayout/LayoutEngine.swift`（或 AppDelegate 的对齐编排）
#     → 直接生效，本脚本调的就是真实代码；
#   · 改 Windows `DeskIsle/Services/LayoutEngine.cs`
#     → **必须同步 `csharp-crosscheck.py`**，否则「对拍通过」只是幻觉
#       （比的是那份直译，不是磁盘上的 C#）。
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PYTHON_BIN="${PYTHON_BIN:-python3}"

echo "── 1/3  mac 真实实现（SwiftPM target: CrosscheckDump）──"
# stderr 留给编译输出，stdout 才是 JSON
( cd "$ROOT/mac" && swift run --disable-sandbox CrosscheckDump ) > "$TMP/mac.json"
if [ ! -s "$TMP/mac.json" ]; then echo "✘ mac 侧跑失败（JSON 为空）"; exit 1; fi
echo "   已产出 $TMP/mac.json"

echo "── 2/3  Windows LayoutEngine.cs 的逐行直译 ──"
"$PYTHON_BIN" "$HERE/csharp-crosscheck.py" -o "$TMP/cs.json"
if [ $? -ne 0 ]; then echo "✘ C# 直译侧跑失败"; exit 1; fi

echo "── 3/3  逐点比对 ──"
"$PYTHON_BIN" "$HERE/compare.py" "$TMP/mac.json" "$TMP/cs.json"
