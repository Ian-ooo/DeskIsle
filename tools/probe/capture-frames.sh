#!/bin/bash
# 连续抓帧（小区域，约 0.2 秒/帧），用于量化「淡出/闪烁/是否同步」这类显示问题。
#
# 用法：
#   bash scratch/capture-frames.sh <输出目录> <帧数> <x> <y> <宽> <高>
#
# 示例（在后台抓 30 帧，前台同时做切换操作）：
#   bash scratch/capture-frames.sh /tmp/frames 30 24 84 660 120 > /tmp/frames.log &
#   ... 做操作 ...
#   wait; cat /tmp/frames.log
#
# 注意：整屏抓帧约 0.7~1.0s/帧，会错过 300ms 的过渡；**必须用小区域**（-R）。

OUT="$1"
N="${2:-30}"
X="${3:-0}"
Y="${4:-0}"
W="${5:-400}"
H="${6:-200}"

mkdir -p "$OUT"
rm -f "$OUT"/*.png 2>/dev/null

for i in $(seq 1 "$N"); do
  screencapture -x -R "$X","$Y","$W","$H" "$OUT/$i.png"
  echo "f$i $(stat -f%z "$OUT/$i.png" 2>/dev/null)"
done
