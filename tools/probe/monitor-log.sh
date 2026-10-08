#!/bin/bash
# 轻量监视（不截图，只记录判定结果）：每 2 秒记录一次探测器原始输出与 DeskIsle 内部状态。
# 用途：用户复现问题时，事后可判断「是检测没触发」还是「检测触发了但渲染不对」。
LOG=/tmp/deskisle-dev4.log
OUT=/tmp/ds-monitor
DET="/Users/yang/Library/Application Support/deskisle/fullscreen-detector"
mkdir -p "$OUT"
: > "$OUT/log-only.log"
PID=$(lsof -nP -iTCP:5173 -sTCP:LISTEN -t 2>/dev/null | head -1)
END=$((SECONDS + 3600))
while [ $SECONDS -lt $END ]; do
  RAW=$("$DET" --self-pid "$PID" --ignore-owner-names WorkBuddy 2>/dev/null | tail -1)
  APP=$(grep "fullscreen state changed" "$LOG" 2>/dev/null | tail -1 | awk '{print $NF}')
  echo "$(date +%H:%M:%S) detRaw=$RAW appState=${APP:-none}" >> "$OUT/log-only.log"
  sleep 2
done
