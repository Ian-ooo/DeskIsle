#!/bin/bash
# 全屏行为监视器 v2：
#   - 每 4 秒抓一张当前屏幕到 live.png（覆盖），并记录探测器原始判定（带时间戳）
#   - 每次 DeskIsle 全屏状态变化，立刻另存一张带时间戳的截图 + 探测器 debug 明细
# 用途：用户复现问题时，事后可精确对齐「当时屏幕画面」与「当时的判定结果」。

LOG=/tmp/deskisle-dev4.log
OUT=/tmp/ds-monitor
DET="/Users/yang/Library/Application Support/deskisle/fullscreen-detector"
mkdir -p "$OUT"
: > "$OUT/monitor.log"

PID=$(lsof -nP -iTCP:5173 -sTCP:LISTEN -t 2>/dev/null | head -1)
LAST=$(grep -c "fullscreen state changed" "$LOG" 2>/dev/null || echo 0)
i=0
END=$((SECONDS + 1800))

while [ $SECONDS -lt $END ]; do
  TS=$(date +%H%M%S)
  screencapture -x "$OUT/live.png" 2>/dev/null
  RAW=$("$DET" --self-pid "$PID" --ignore-owner-names WorkBuddy 2>/dev/null | tail -1)
  DSTATE=$(grep "fullscreen state changed" "$LOG" 2>/dev/null | tail -1 | awk '{print $NF}')

  N=$(grep -c "fullscreen state changed" "$LOG" 2>/dev/null || echo 0)
  if [ "$N" -gt "$LAST" ]; then
    i=$((i + 1))
    screencapture -x "$OUT/${TS}_change${i}_app-${DSTATE}.png" 2>/dev/null
    cp "$OUT/live.png" "$OUT/${TS}_change${i}_live.png" 2>/dev/null
    DETAIL=$("$DET" --self-pid "$PID" --ignore-owner-names WorkBuddy --debug 2>/dev/null | tr '\n' '|')
    echo "$(date +%H:%M:%S) CHANGE#$i appState=$DSTATE detRaw=$RAW detail=[$DETAIL]" >> "$OUT/monitor.log"
    LAST=$N
  else
    echo "$(date +%H:%M:%S) detRaw=$RAW appState=$DSTATE" >> "$OUT/monitor.log"
  fi
  sleep 4
done
echo "monitor ended at $(date +%H:%M:%S)" >> "$OUT/monitor.log"
