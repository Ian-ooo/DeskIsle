#!/bin/bash
# 端到端验证用户的操作流程：在「普通桌面」与「全屏应用的 Space」之间来回切换。
LOG=/tmp/deskisle-dev4.log
SW=/tmp/fx-switch
FS=/tmp/fx-fs

state() { grep "fullscreen state changed" "$LOG" | tail -1 | awk '{print $NF}'; }
count() { grep -c "fullscreen state changed" "$LOG"; }

echo "① 退出 WorkBuddy 全屏"
"$FS" > /dev/null; sleep 3
echo "   appState=$(state)"

echo "② 进入 Chrome 全屏（作为用户所说的『全屏应用的桌面』）"
open -a "Google Chrome"; sleep 2
b=$(count); "$FS" > /dev/null; sleep 3
echo "   appState=$(state)（期望 true）状态变化=$(( $(count) - b ))"
screencapture -x /tmp/e2e-in-fullscreen.png

echo "③ 用 ⌃← 切回普通桌面"
b=$(count); "$SW" left 1 > /dev/null; sleep 3
echo "   appState=$(state)（期望 false）状态变化=$(( $(count) - b ))"
screencapture -x /tmp/e2e-back-desktop.png

echo "④ 再 ⌃→ 切回全屏 Space"
b=$(count); "$SW" right 1 > /dev/null; sleep 3
echo "   appState=$(state)（期望 true）状态变化=$(( $(count) - b ))"

echo "⑤ 再 ⌃← 切回桌面"
b=$(count); "$SW" left 1 > /dev/null; sleep 3
echo "   appState=$(state)（期望 false）状态变化=$(( $(count) - b ))"

echo "⑥ 退出 Chrome 全屏，恢复原状"
open -a "Google Chrome"; sleep 1.5; "$FS" > /dev/null; sleep 3
echo "   appState=$(state)"
for f in e2e-in-fullscreen e2e-back-desktop; do
  sips -Z 720 "/tmp/$f.png" --out "/tmp/$f-small.png" > /dev/null 2>&1
done
