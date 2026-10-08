#!/bin/bash
# 监视 DeskIsle 全屏状态变化，每次变化立刻抓屏并记录探测器判定细节
LOG=/tmp/deskisle-dev4.log
OUT=/tmp/ds-monitor
mkdir -p "$OUT"
rm -f "$OUT"/*.png "$OUT"/index.txt
DET="/Users/yang/Library/Application Support/deskisle/fullscreen-detector"
LAST=$(grep -c "fullscreen state changed" "$LOG")
i=0
END=$((SECONDS + 360))
while [ $SECONDS -lt $END ]; do
  N=$(grep -c "fullscreen state changed" "$LOG")
  if [ "$N" -gt "$LAST" ]; then
    STATE=$(grep "fullscreen state changed" "$LOG" | tail -1 | awk '{print $NF}')
    i=$((i + 1))
    TS=$(date +%H%M%S)
    # 抓屏（含鼠标指针 -C，便于判断用户操作位置）
    screencapture -x -C "$OUT/${TS}_${i}_state-${STATE}.png"
    # 同一时刻的探测器判定（列出所有命中候选）
    DETOUT=$("$DET" --self-pid "$(lsof -nP -iTCP:5173 -sTCP:LISTEN -t 2>/dev/null | head -1)" --ignore-owner-names WorkBuddy --debug 2>&1 | grep -E "MATCH=true|^true|^false|^sliding" | tr '\n' ' ')
    echo "$(date +%H:%M:%S) state=$STATE file=${TS}_${i}_state-${STATE}.png det=[$DETOUT]" >> "$OUT/index.txt"
    LAST=$N
  fi
  sleep 0.3
done
echo "监视结束" >> "$OUT/index.txt"
