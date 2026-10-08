#!/bin/bash
# 全屏空间可见性实验驱动脚本
#
# 时间线：
#   t=0    启动 6 个单窗口进程（A..F，各持一种窗口配置）
#   t=4    采集基线
#   t=5    启动 fx-fullscreen（进入另一个应用的全屏空间）
#   t=5..25  每 2 秒采集一次，形成时间线  ← 关键数据
#   t=27   清理（只清理实验进程，不动 DeskIsle）
#
# 注意：本环境必须带 --no-sandbox，否则渲染进程沙箱初始化失败、窗口不会出现。

cd /Users/yang/Documents/myself/DeskIsle || exit 1
unset ELECTRON_RUN_AS_NODE NODE_OPTIONS

ELECTRON=./node_modules/.bin/electron
PROBE=scratch/probe
OUT=scratch/out
rm -rf "$OUT"
mkdir -p "$OUT"

echo "=== t=0 启动 6 个测试窗口进程 ==="
for K in A B C D E F; do
  "$ELECTRON" scratch/fx-window.js "$K" --no-sandbox > "$OUT/log-$K.txt" 2>&1 &
  echo "$!" > "$OUT/wrapper-$K.pid"
done

sleep 4

echo "=== 收集各进程 PID ==="
TEST_PIDS=""
for K in A B C D E F; do
  P=$(grep -o 'pid=[0-9]*' "$OUT/log-$K.txt" 2>/dev/null | head -1 | cut -d= -f2)
  echo "  $K -> pid=${P:-未启动}" | tee -a "$OUT/pids.txt"
  [ -n "$P" ] && TEST_PIDS="$TEST_PIDS $P"
done

# DeskIsle 开发实例只观测、不清理
DS=$(pgrep -f 'DeskIsle/node_modules/electron/dist/Electron.app/Contents/MacOS/Electron' 2>/dev/null | head -1)
echo "  DeskIsle(dev) -> pid=${DS:-未运行}" | tee -a "$OUT/pids.txt"

echo ""
echo "=== t=4 基线采集（无全屏空间） ==="
$PROBE $TEST_PIDS $DS | tee "$OUT/measure-baseline.txt"

echo ""
echo "=== t=5 启动全屏应用 ==="
"$ELECTRON" scratch/fx-fullscreen.js --no-sandbox > "$OUT/log-fullscreen.txt" 2>&1 &
FS_WRAPPER=$!
sleep 2
FS_PID=$(grep -o 'pid=[0-9]*' "$OUT/log-fullscreen.txt" 2>/dev/null | head -1 | cut -d= -f2)
echo "  fullscreen wrapper=$FS_WRAPPER pid=${FS_PID:-?}"
echo "$FS_WRAPPER" > "$OUT/wrapper-fullscreen.pid"

echo ""
echo "=== 时间线采集（每 2 秒一次） ==="
: > "$OUT/timeline.txt"
for i in $(seq 1 11); do
  sleep 2
  echo "----- +$((i*2))s (t=$((5+i*2))) -----" >> "$OUT/timeline.txt"
  $PROBE $TEST_PIDS $FS_PID >> "$OUT/timeline.txt"
done

echo ""
echo "=== 全屏进程自身状态 ==="
grep -E 'display bounds|STATUS|READY' "$OUT/log-fullscreen.txt" | head -20

echo ""
echo "=== 清理实验进程 ==="
for P in $TEST_PIDS $FS_PID; do
  [ -n "$P" ] && kill "$P" 2>/dev/null && echo "  killed $P"
done
for K in A B C D E F fullscreen; do
  W=$(cat "$OUT/wrapper-$K.pid" 2>/dev/null)
  [ -n "$W" ] && kill "$W" 2>/dev/null
done
sleep 1
echo "=== 实验结束 ==="
