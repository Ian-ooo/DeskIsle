#!/bin/bash
# 测量「Space 切换 / 进入全屏」到「探测器状态翻转」的延迟。
DET=/tmp/fd-v5
PY=/Users/yang/.workbuddy/binaries/python/versions/3.13.12/bin/python3
now() { $PY -c "import time;print(int(time.time()*1000)%1000000)"; }

: > /tmp/watch.log
$DET --self-pid 1 --ignore-owner-names WorkBuddy --watch --poll-ms 80 >> /tmp/watch.log 2>&1 &
WPID=$!
sleep 1.5

echo "=== 基线状态 ==="; cat /tmp/watch.log

echo "=== ① 进入 Chrome 全屏（⌃⌘F）==="
open -a "Google Chrome"; sleep 2
echo "动作时刻: $(now)"
/tmp/fx-fs > /dev/null
sleep 3

echo "=== ② 退出 Chrome 全屏（⌃⌘F）==="
echo "动作时刻: $(now)"
/tmp/fx-fs > /dev/null
sleep 3

kill $WPID 2>/dev/null
echo "=== 探测器输出（状态 毫秒时间戳）==="
cat /tmp/watch.log
