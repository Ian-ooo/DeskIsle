#!/bin/bash
# 测量：Space 列表签名 / 几何信号 / CGS 权威信号，三者在「进入全屏」时的翻转时刻。
DET=/tmp/fd-v7
PY=/Users/yang/.workbuddy/binaries/python/versions/3.13.12/bin/python3
now() { $PY -c "import time;print(int(time.time()*1000)%1000000)"; }

: > /tmp/trace2.log
$DET --self-pid 1 --ignore-owner-names WorkBuddy --trace --debug --poll-ms 40 > /dev/null 2>> /tmp/trace2.log &
WPID=$!
sleep 1.5

echo "=== 先切到普通桌面 @ $(now) ==="
open -a "Google Chrome"; sleep 3
echo "=== T_ENTER: 对 Chrome 发 ⌃⌘F @ $(now) ==="
/tmp/fx-fs > /dev/null; sleep 3.5
echo "=== T_EXIT: 再发 ⌃⌘F 退出 @ $(now) ==="
/tmp/fx-fs > /dev/null; sleep 3.5
kill $WPID 2>/dev/null

echo
echo "=== 时间线：仅在「三个信号任一变化」时打印 ==="
$PY - <<'EOF'
import re
prev=None
for line in open('/tmp/trace2.log'):
    m=re.search(r't=(\d+).*?cgs=(\S+(?:\[[^\]]*\])?).*?geom=(\w+).*?spaces=(n=\d+ cur=-?\d+ \[[^\]]*\])', line)
    if not m: continue
    t, cgs, geom, spaces = m.groups()
    cgs_short = cgs.split('[')[0]
    key=(cgs_short, geom, spaces)
    if key!=prev:
        print(f"{t:>7}  cgs={cgs_short:<12} geom={geom:<8} {spaces}")
        prev=key
EOF
