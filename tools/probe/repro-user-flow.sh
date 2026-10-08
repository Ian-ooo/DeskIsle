#!/bin/bash
# 精确复现用户测试方式：在「普通桌面」与「全屏应用所在桌面」之间来回切 Space。
DET="/Users/yang/Library/Application Support/deskisle/fullscreen-detector"
LOG=/tmp/deskisle-dev4.log
SW=/tmp/fx-switch

DSID=$(/tmp/dump-windows | grep "DeskIsle" | head -1 | sed 's/^id=[0-9]* pid=\([0-9]*\).*/\1/')
echo "DeskIsle pid=$DSID"

det() { "$DET" --self-pid "$DSID" --ignore-owner-names WorkBuddy 2>/dev/null | tail -1; }
state_now() { grep "fullscreen state changed" "$LOG" | tail -1 | awk '{print $NF}'; }
changes() { grep -c "fullscreen state changed" "$LOG"; }
samples() { # $1 = 采样次数
  local out=""
  for _ in $(seq 1 "$1"); do out="$out$(det) "; sleep 0.45; done
  echo "$out"
}

echo "起始 raw=$(det) appState=$(state_now) 变化总数=$(changes)"

# 1) 先切到「非全屏」的桌面 Space（最多 6 次）
for i in $(seq 1 6); do
  [ "$(det)" = "false" ] && break
  "$SW" left 1 > /dev/null; sleep 1.3
done
echo "=== 已到桌面: raw=$(det) appState=$(state_now) ==="

# 2) 来回切换 3 轮
for round in 1 2 3; do
  b=$(changes)
  echo "--- 第 $round 轮 → 切到全屏 Space ---"
  "$SW" right 1 > /dev/null
  echo "    raw: $(samples 6)"
  echo "    appState=$(state_now) 本步状态变化=$(( $(changes) - b ))"

  b=$(changes)
  echo "--- 第 $round 轮 → 切回桌面 ---"
  "$SW" left 1 > /dev/null
  echo "    raw: $(samples 6)"
  echo "    appState=$(state_now) 本步状态变化=$(( $(changes) - b ))"
done
echo "结束 raw=$(det) appState=$(state_now)"
