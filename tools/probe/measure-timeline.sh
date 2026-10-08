#!/bin/bash
# 时间线测量：进入/退出全屏时，几何信号（视觉过渡开始）与 CGS 信号（权威判定）各自的翻转时刻。
DET=/tmp/fd-v6
PY=/Users/yang/.workbuddy/binaries/python/versions/3.13.12/bin/python3
now() { $PY -c "import time;print(int(time.time()*1000)%1000000)"; }

: > /tmp/trace.log
$DET --self-pid 1 --ignore-owner-names WorkBuddy --trace --debug --poll-ms 40 > /dev/null 2>> /tmp/trace.log &
WPID=$!
sleep 1.5

echo "=== T1: 激活 Chrome（切到它的 Space）@ $(now) ==="
open -a "Google Chrome"
sleep 3

echo "=== T2: ⌃⌘F @ $(now) ==="
/tmp/fx-fs > /dev/null
sleep 3.5

echo "=== T3: ⌃⌘F @ $(now) ==="
/tmp/fx-fs > /dev/null
sleep 3.5

kill $WPID 2>/dev/null
echo
echo "=== 时间线（只看信号变化点）==="
grep -E "cgs=(FULLSCREEN|desktop)|geom=(MATCH|sliding)" /tmp/trace.log | awk '{
  for (i = 1; i <= NF; i++) {
    if ($i ~ /^t=/) t = substr($i, 3);
    if ($i ~ /^cgs=/) c = $i;
    if ($i ~ /^geom=/) g = $i;
  }
  key = c " " g;
  if (key != prev) { print t "  " c "  " g; prev = key }
}'
