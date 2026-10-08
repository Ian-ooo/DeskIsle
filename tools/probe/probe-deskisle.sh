#!/bin/bash
# 聚焦观测：DeskIsle 自己的两个窗口在「别的应用全屏空间」活动时的状态
#
# 上一次实验的教训：时间线探针忘了带 DeskIsle 的 PID，导致最关键的数据缺失。

cd /Users/yang/Documents/myself/DeskIsle || exit 1
unset ELECTRON_RUN_AS_NODE NODE_OPTIONS

ELECTRON=./node_modules/.bin/electron
PROBE=scratch/probe
OUT=scratch/out
mkdir -p "$OUT"

DS=$(pgrep -f 'DeskIsle/node_modules/electron/dist/Electron.app/Contents/MacOS/Electron' 2>/dev/null | head -1)
if [ -z "$DS" ]; then
  echo "DeskIsle 未运行，先启动它"
  exit 1
fi
echo "DeskIsle pid=$DS"

echo ""
echo "=== 基线（无全屏空间） ==="
$PROBE $DS | tee "$OUT/ds-baseline.txt"

echo ""
echo "=== 启动全屏应用 ==="
"$ELECTRON" scratch/fx-fullscreen.js --no-sandbox > "$OUT/ds-log-fullscreen.txt" 2>&1 &
FS_WRAPPER=$!
sleep 2
FS_PID=$(grep -o 'pid=[0-9]*' "$OUT/ds-log-fullscreen.txt" 2>/dev/null | head -1 | cut -d= -f2)
echo "fullscreen pid=$FS_PID"

echo ""
echo "=== 时间线（每 2 秒，含 DeskIsle） ==="
: > "$OUT/ds-timeline.txt"
for i in $(seq 1 10); do
  sleep 2
  echo "----- +$((i*2))s -----" >> "$OUT/ds-timeline.txt"
  $PROBE $DS $FS_PID >> "$OUT/ds-timeline.txt"
done

echo "已写入 $OUT/ds-timeline.txt"

echo ""
echo "=== 清理全屏应用 ==="
kill "$FS_PID" 2>/dev/null; kill "$FS_WRAPPER" 2>/dev/null
sleep 1
echo "=== 完成 ==="
