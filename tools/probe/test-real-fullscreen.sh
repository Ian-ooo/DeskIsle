#!/bin/bash
# 受控测试：真实全屏（Chrome ⌃⌘F）下，带归属校验的新探测器是否仍能识别
DET="/Users/yang/Library/Application Support/deskisle/fullscreen-detector"
LOG=/tmp/deskisle-run1.log

echo "=== 1) 基线 ==="
"$DET" --self-pid 1
/tmp/fx-spaces "基线" 2>/dev/null | grep "← 当前"
BASE=$(wc -l < "$LOG" | tr -d ' ')
echo "日志基线行=$BASE"

echo
echo "=== 2) 激活 Chrome 并发送 ⌃⌘F ==="
open -a "Google Chrome"
sleep 2
/tmp/fx-fs >/dev/null
sleep 3.5

echo "--- Space 列表 ---"
/tmp/fx-spaces "全屏后" 2>/dev/null | grep -E "type=4|← 当前"
echo "--- 探测器读数 x5 ---"
for i in 1 2 3 4 5; do echo -n "$("$DET" --self-pid 1) "; sleep 0.3; done; echo
echo "--- 归属校验细节（fsPids / matched）---"
"$DET" --self-pid 1 --trace --poll-ms 40 2>&1 | head -1
echo "--- 应用日志 ---"
tail -n +$((BASE+1)) "$LOG" | grep "fullscreen state changed"

echo
echo "=== 3) 退出全屏 ==="
/tmp/fx-fs >/dev/null
sleep 3.5
echo -n "探测器: $("$DET" --self-pid 1)"; echo
tail -n +$((BASE+1)) "$LOG" | grep "fullscreen state changed" | tail -2
