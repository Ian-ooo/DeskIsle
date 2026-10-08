#!/bin/bash
# 端到端延迟测量：按键 → 探测器信号 → DeskIsle 状态翻转（应用日志现在带毫秒时间戳）。
BIN="/Users/yang/Library/Application Support/deskisle/fullscreen-detector"
LOG=/tmp/deskisle-dev4.log
PY=/Users/yang/.workbuddy/binaries/python/versions/3.13.12/bin/python3
# 与应用 ts() 同格式（UTC HH:MM:SS.mmm）
ts() { $PY -c "import time;t=time.gmtime();print('%02d:%02d:%02d.%03d'%(t.tm_hour,t.tm_min,t.tm_sec,int(time.time()*1000)%1000))"; }

cp /tmp/fd-v10 "$BIN"
/usr/bin/shasum -a 256 /Users/yang/Documents/myself/DeskIsle/electron/assets/fullscreen-detector.swift | awk '{print $1}' > "$BIN.src-hash"
cd /Users/yang/Documents/myself/DeskIsle && touch electron/main.ts
sleep 14

MARK=$(wc -l < "$LOG" | tr -d " ")
echo "=== 基线（新实例日志）==="
tail -n +$MARK "$LOG" | grep -E "watcher|fullscreen state" | tail -4

echo
echo "=== 激活 Chrome（切到它的桌面 Space）@ $(ts) ==="
open -a "Google Chrome"; sleep 2.5

echo "=== T_ENTER: ⌃⌘F 进入全屏 @ $(ts) ==="
/tmp/fx-fs > /dev/null; sleep 4

echo "=== T_EXIT:  ⌃⌘F 退出全屏 @ $(ts) ==="
/tmp/fx-fs > /dev/null; sleep 4

echo
echo "=== DeskIsle 状态翻转时间戳 ==="
tail -n +$MARK "$LOG" | grep "fullscreen state changed"
