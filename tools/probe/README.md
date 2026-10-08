# tools/probe — 桌面行为实测探针（mac）

一批一次性的调试脚本，用于**拿地面真值**：macOS 窗口层级、全屏 Space 判定、合成点击/拖动的真实落点。
只服务 mac 端，不参与构建、不参与测试、不参与打包。

## 出处

2026-10-01 移除 Electron 端时，从 `electron/scratch/` 里抢救出来的——这些脚本研究的是 **mac 原生行为**，
与 Electron 无关，只是当初顺手放在了那个目录里。同名截图证据（`evidence*`，约 99M）未保留，可重新生成。

## 三类

| 前缀 | 语言 | 用途 |
|---|---|---|
| `fx-*.swift` | Swift | 合成输入（点击 / 双击 / 拖动 / 按键 / 键入）并读回窗口真实几何 |
| `fx-*.js` | Node | 走 CGS 私有 API 探窗口层级、Space 与显示器矩阵 |
| `dump-windows.swift` `fullscreen-detector.swift` `probe.swift` 等 | Swift | 枚举窗口 ID、判定当前是否处于他应用的原生全屏 Space |

## 跑之前

- Swift 脚本直接 `swiftc` 后执行；**别**用 `probe` 那个可执行文件——它是编译产物，已清掉，
  需要时从 `probe.swift` 重新编译。
- 合成输入会**真的动你的鼠标键盘**。跑之前确认没人在用这台机器，并先记录当前窗口坐标做基线。
- 截图要按窗口 ID 精确取：`CGWindowListCopyWindowInfo` → `kCGWindowNumber` → `screencapture -x -o -l <id>`。
  用 `-R` 会拍到别的窗口。

## 约定

这里的文件允许「用完即弃」，不属于任何端的交付物。新写的探针统一放这儿，别再塞进别的端目录。
