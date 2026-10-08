#!/bin/bash
# 复现「切换桌面时的 pre 假阳性」：走遍所有 Space，同时紧密采样探测器
DET="/Users/yang/Library/Application Support/deskisle/fullscreen-detector"
LOG=/tmp/deskisle-run1.log
OUT=/tmp/ss2.txt
: > "$OUT"

echo "=== 起始 Space ==="
/tmp/fx-spaces "起始" 2>/dev/null | grep "← 当前"

# 后台紧密采样（80ms，含 --debug 以打印命中窗口）
(
  END=$((SECONDS + 45))
  while [ $SECONDS -lt $END ]; do
    echo "--- $(date +%S.%N | cut -c1-5)" >> "$OUT"
    "$DET" --self-pid 1 --debug >> "$OUT" 2>&1
    sleep 0.08
  done
) &
SAMPLER=$!

sleep 0.5
BASE=$(grep -c "fullscreen state changed" "$LOG")

# 向右走 4 个 Space
for i in 1 2 3 4; do
  /tmp/fx-switch right 1 >/dev/null
  sleep 2.2
  echo ">>> 右 $i : $(/tmp/fx-spaces "x" 2>/dev/null | grep '← 当前' | tr -d ' ' | head -1)"
done
# 向左走回 4 个 Space
for i in 1 2 3 4; do
  /tmp/fx-switch left 1 >/dev/null
  sleep 2.2
  echo ">>> 左 $i : $(/tmp/fx-spaces "x" 2>/dev/null | grep '← 当前' | tr -d ' ' | head -1)"
done

wait $SAMPLER

echo
echo "=== 采样期间 MATCH=true 的窗口 ==="
grep -c "MATCH=true" "$OUT"
grep -B2 "MATCH=true" "$OUT" | grep -v "^--- " | grep "candidate" | sort -u | head -12
echo
echo "=== 应用日志新增的全屏状态变化 ==="
tail -n +$((BASE+1)) "$LOG" | grep "fullscreen state changed"
