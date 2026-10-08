# DeskIsle · mac 原生版（AppKit）重搭计划

> 目标：仅针对 macOS，用 **AppKit 做壳（窗口/层级/事件）+ SwiftUI 做内容** 重写，
> 直接复用现有 `deskisle_config.json`（`~/Library/Application Support/deskisle/`）。
> Electron 版暂存 `src/ + electron/`，作为对照与兜底，直到原生版 feature parity 后切换。

## 里程碑（步骤）

### M0 — 脚手架（已完成）
- [x] 建 `mac/`（Swift Package）与 `windows/`（预留）。
- [x] 可启动的 accessory 应用（无 Dock 图标）+ `NSStatusItem`（托盘，含退出）。

### M1 — 窗口骨架（已完成）
- [x] 读配置 JSON → 每分区一个透明 `NSPanel`，按配置坐标/尺寸摆放。
- [x] 层级语义：置顶 → `.floating` + `[.canJoinAllSpaces, .fullScreenAuxiliary]`；
      未置顶 → 桌面层（见 M6）。
- [x] 顶栏 overlay 窗口：`.floating`，`fullScreenAuxiliary` 仅在「存在置顶分区」时启用。
- [x] SwiftUI 内容：圆角毛玻璃（`.ultraThinMaterial`）+ 标题。
- [x] 验证：桌面显示、切全屏 Space 后未置顶消失/置顶保留、圆角毛玻璃贴边。
      （全屏让位**零检测代码**，纯 `collectionBehavior` 语义；这同时反证了 Electron
      时代依赖的 `onscreen` 标志不可靠。）

### M2 — 分区内容（已完成 + 功能补齐）
- [x] portal：实时读 `folderPath`（FileManager），网格/列表双模式、图标 + 名称、空状态、双击打开。
- [x] portal 工具栏：排序切换（名称/时间/大小/类型 + 升降序，实测循环切换+落盘 ✓）、
      新建文件夹（alert 输入，实测弹出+取消 ✓）、子文件夹浏览（双击进入/返回上一级/返回根，
      实测进入后返回按钮出现、点击后消失 ✓）、视图切换按钮。
- [x] 文件类型图标（图片/pdf/音乐/视频/压缩包/文档/表格按扩展名区分）。
- [x] smart 智能归类箱：smartRule.sourcePath + extensions 过滤（复用 portal 网格）。
- [x] collection 收集箱：files[] 列表 + SwiftUI onDrop 拖拽添加 + 右键移出/废纸篓。
- [x] notes：`noteContent` 展示 + 编辑（TextEditor，输入即写回，含中文输入实测）。
- [x] todo：`todos[]` 条目 + 可点击勾选/划线态、空状态。
- [x] 标题栏（折叠 + 置顶 + 删除按钮）+ 类型分发（`PartitionView` 按 `type` 渲染
      portal/smart/collection/notes/todo 五种类型全支持）。
- [x] 标题 10 字限制 + portal 选文件夹后自动用文件夹名作标题。
- [x] 拖动：`isMovableByWindowBackground`（实测合成拖拽后窗口位置随光标移动）。
- [x] hover 展开（hoverPeekCollapsed）：折叠分区悬停临时展开预览，不改 config.isCollapsed；
      折叠/展开切换时 onChange 重置 hoverExpanded（防残留错位）。

### M3 — 交互（已完成）
- [x] 鼠标穿透 + 命中：全局/本地鼠标监视器 + 圆角形状判定，逐窗口切换 `ignoresMouseEvents`
      （被遮挡分区点击正确穿透到前窗，实测验证）。
- [x] 点击聚焦：accessory + nonactivatingPanel 需在点击时显式 `NSApp.activate` + `makeKey`。
- [x] 拖动落盘（didMove → 静默更新 + 节流保存）。
- [x] 缩放：右下角 resize 手柄（SwiftUI DragGesture → setSize，缩放期间临时关闭
      `isMovableByWindowBackground` 防止两套手势打架；实测 +60x60 落盘 ✓）。
- [x] 吸附对齐：拖动停止 250ms 后吸附屏幕边缘/邻分区（阈值 16，按住 Alt 跳过；
      **margin 必须与 realign 一致（24）**，否则对齐过的位置一拖就被吸歪）。
- [x] 分区右键菜单（置顶/设置/视图切换/折叠/删除）、空白画布右键菜单
      （新建/顶部排序/左侧纵向/右侧纵向/网格平铺/对齐/锁定/退出）、
      文件右键菜单（打开/访达显示/展开浏览/废纸篓）。
- [x] 四种对齐模式：top/left/right/grid（通用 align(mode:) 实现）。

### M4 — 行为（已完成）
- [x] 置顶/取消置顶（实测层级切换 + 落盘，零闪烁）。
- [x] 显隐（幽灵模式）：顶栏眼睛 / 托盘 / ⌘⌥D。
- [x] 全屏跟随：`collectionBehavior` 语义（M1 已实测）。
- [x] 文件夹监听（DispatchSourceFileSystemObject → 通知 → portal 自动刷新，实测增/删文件均刷新）。
- [x] 全局快捷键（Carbon `RegisterEventHotKey`，默认 ⌘⌥D；合成按键无法自测，需手动验证）。
- [x] 托盘菜单（显示隐藏 / 重新对齐 / 新建分区 / 全局设置 / 退出）。
- [x] 新建分区模态框（类型选择 portal/notes/todo + portal 选文件夹 + 默认内容；
      实测「选 todo → 创建」→ 分区数 +1、2 条默认待办落盘 ✓）。
- [x] 删除分区（实测：配置与窗口同步清理）。

### M5 — 配置读写（已完成）
- [x] 字典式读写：保留 Electron 配置的全部未知字段；原子写 + `.bak` 滚动备份。
- [x] 置顶 / 拖动 / 便签 / 新建 / 删除 全部落盘（实测）。
- [x] 外部配置变更热重载：**监听配置所在目录**（不能监听文件 fd——save 的 rename
      会替换 inode，文件 watcher 在第一次保存后就永久失效），目录事件防抖 300ms
      后比对 mtime；距自己上次落盘 <1.5s 的变更忽略（防 save→watcher→rebuild 死循环）。
      实测：应用内保存过后外部改配置，窗口自动重建 ✓。

### M6 — 打磨（已完成）
- [x] 未置顶分区「桌面层」层级：`kCGDesktopIconWindowLevel + 1`（贴壁纸之上、
      桌面图标之上、所有普通窗口之下；实测 WorkBuddy 窗口正确压在未置顶分区上）。
- [x] 分区设置完整字段：标题 / folderPath（portal 选文件夹）/ 置顶 / 折叠 / 宽高 / 模糊 / 圆角。
- [x] 全局设置完整字段：顶栏 / 吸附 / hoverPeek / 锁定 / 拦截壁纸点击 / 开机自启
      （SMAppService，需打包 .app）/ 默认分区宽度。
- [x] 模态框层级修复：`.modalPanel`（否则置顶分区会盖住模态框、按钮点不到——实测抓到）。
- [x] 打包 `DeskIsle.app`（`mac/build-app.sh`：release 构建 + Info.plist（LSUIElement）
      + ad-hoc 签名 → `mac/dist/DeskIsle.app`）。
- [x] 排查 500x500 / 56x18 隐藏窗口：**SwiftUI `.help()` 的 tooltip 窗口**及 AppKit
      内部辅助窗口，无害，无需处理。
- [x] **多显示器支持**（实测双屏内建 1680×1050 + 外接 1920×1080）：
      配置坐标是「屏幕相对坐标（左上原点）」，渲染时加所在屏幕 origin；
      拖动落盘/吸附/对齐/自适应/缩放/越界纠正全部按 `panel.screen` 换算；
      `referenceScreen()` = 光标所在屏幕（NSScreen.main 会随焦点漂移）。

### M7 — 对比 Electron 补齐（已完成，全部实测或等价实现）
- [x] **删除分区原生确认框**（明示「不删除本地源文件」，Esc/取消均验证）。
- [x] **自定义全局快捷键**（`Shortcut.swift`：解析 Electron 格式 `CommandOrControl+Alt+D`
      + SwiftUI 录制器 + Carbon 重注册 + 失败回滚旧键；托盘菜单显示当前键）。
- [x] **配置备份导出/导入**（`deskisle_backup_YYYY-MM-DD.json`，导入校验 + 提示）。
- [x] **自动适应内容高度**（标题栏按钮 + 右键 + 画布「所有分区自适应高度」；
      notes 按行数、todo 按条数、文件类按网格行列数估算，越底上移）。
- [x] **8 向缩放手柄**（4 边 + 4 角；缩放结束后强制刷新一次，让 SwiftUI 用上新尺寸）。
- [x] **双击标题栏折叠/展开**（`titlebarDoubleClickAction`：collapse/none）。
- [x] **portal/smart/collection 搜索框**（本地过滤，可清除）。
- [x] **todo 增删改**（底部输入行回车添加、悬停删除、优先级循环 high/medium/low、
      拖入文件生成「处理: 文件名」）。
- [x] **便签拖入文件追加路径**；**新建分区支持 5 种类型**（含 smart 扩展名选择器）。
- [x] **每分区锁定 `isLocked`**（禁拖动/缩放，隐藏手柄，标题栏小锁图标，右键切换）。
- [x] **屏幕参数变化重排** `ensurePartitionsInBounds`（只纠正越界，逐分区按所在屏）。
- [x] **新建分区自动避让**（光栅扫描找不重叠空位 + 级联偏移兜底）。
- [x] **分区设置补全**：smart 路径+扩展名、背景色/标题高亮色色板、不透明度
      （毛玻璃之上叠色）；全局设置补：快捷键录制、标题栏双击、映射门空白双击、
      最小宽度、备份按钮。
- [x] **顶栏**：锁定、隐藏顶栏、退出；**托盘**：对齐子菜单、自适应、还原宽度、
      顶栏开关（勾选态）、备份、退出。
- [x] **文件数徽标 + 标题用 headerColor**；**目录恒置顶排序**；**隐藏文件过滤**；
      **新建文件夹名消毒 + 重名递增**；**收集箱存在性校验**（10s 轮询自动剔除）。
- [x] **拦截壁纸点击**：全屏护盾窗口，层级 = `kCGDesktopIconWindowLevel`
      （必须低于分区的 +1，否则盖住未置顶分区）。
- [ ] feature parity 已基本达成 → Electron 版退役切换（需用户确认）。

### M8 — 补齐 P0 核心缺口（已完成，编译通过）
对照 `FEATURE_GAP.md` 的 P0 三项：
- [x] **portal 面包屑导航**：`breadcrumbBar` 多级路径条（`根 > 子A > 子B`），
      点击任意祖先节点 `navigate(to:)` 直达；`history` 栈改为纯 `currentPath` 模型，
      `goUp()` 按父目录推导（父级在根外则回根）。
- [x] **文件/文件夹重命名**：`AppDelegate.renameFile`（非法字符消毒 + 同目录重名递增
      `名称 2`）+ portal 文件右键「重命名」+ alert 输入。
- [x] **收集箱网格/列表切换 + 多维排序**：`CollectionView` 补 `viewMode` grid/list 切换、
      按名称/时间/大小/类型 + 升降序排序；`CollectionFile` 实时 stat 补 `size/modDate/fileType`。

### M9 — 补齐 P1 快捷入口（已完成，编译通过）
- [x] **portal 工具栏「访达定位」「即时刷新」**：`arrow.up.right.square` 打开当前目录、
      `arrow.clockwise` 手动 `load()`；合并掉 smart 专属刷新按钮（统一一个刷新入口）。
- [x] **顶栏三个对齐模式按钮**：`TopBarView` 加 `onAlign` + 顶部/左侧/右侧三按钮
      （`arrow.up/left/right.to.line`，`@State alignMode` 高亮）；`TopBarPanel` + AppDelegate
      两处创建点透传；`align(mode:)` 由 private 改 internal。
- [x] **托盘「DeskIsle 桌岛」品牌标牌**：`setupStatusItem` 首项 disabled 标牌 + separator。
- [x] **双击底边/右下角手柄自适应高度**：`ResizeGrip` 对 `.b`/`.br` 加 `onTapGesture(count:2)`。
- [x] **8 向缩放 NSCursor**：四边 `resizeUpDown`/`resizeLeftRight`，四角用 SF Symbol 斜双箭头
      自定义对角 cursor；`onHover` push/pop。

### M10 — 收敛决策：顶栏悬浮胶囊 + 排序 tie-breaker + 透明背景（已完成，编译零警告）
- [x] **顶栏固定悬浮胶囊**：`TopBarPanel` 离顶端 12→16px（对齐 top-4），`TopBarView`
      cornerRadius 16→22（胶囊）。
- [x] **排序 tie-breaker / 新建分区顺承**：`align(mode:)` 持久化 `settings.alignMode`；
      `findFreeSlot` 按 alignMode 分四向扫描（top/grid 行优先、left 列优先、right 从右往左列）；
      `TopBarView` 改 `@ObservedObject config` 读 alignMode 高亮（不再 @State）。
- [x] **分区固定透明背景**：去掉 `.ultraThinMaterial` 材质，仅保留圆角裁剪 + 极淡描边；
      `createPartition` 不再写 `blurAmount/borderRadius` 死字段（style 置空）。
- [x] 顺手清理两处 pre-existing warning（realign 死变量 `sh`、Color.init 的 `var s`→`let`）。

### M11 — 顶栏定位：不贴顶部 + 普通桌面/全屏 Space 位置一致（已完成，编译零警告）
- [x] `TopBarPanel` 加 `static height=44` / `topInset=40`（> 菜单栏），frame y 固定偏移
      `frame.height - height - topInset`——普通桌面落在菜单栏下方、与全屏 Space 绝对位置一致。
- [x] `AppDelegate.topMargin` 统一 4 处魔法数「84」→ `24 + height + topInset`。
- [x] 关键：用 `screen.frame`（完整屏）+ 固定偏移，不用 `visibleFrame`（全屏 Space 会漂）。





### 多显示器 / 多 Space 实测教训
- 弹窗（模态框/NSAlert）必须 `collectionBehavior += [.canJoinAllSpaces, .fullScreenAuxiliary]`
  并落位到分区所在屏，否则「窗口存在、onscreen=true、能收键盘，但看不见」
  （落在另一个屏的非当前 Space 上）。
- 合成点击/按键可能唤不醒 runModal 的 alert（Esc 有时不响应）；按按钮坐标精确点击可关闭。

## 构建 / 运行

```bash
cd mac
swift build --disable-sandbox    # 受限 shell 必须加 --disable-sandbox（SwiftPM 走 sandbox-exec 会被拦）
.build/debug/DeskIsle            # GUI 进程需以持久后台任务方式启动（nohup 会被回收）

bash build-app.sh                # 打包 → dist/DeskIsle.app（可 open 双击运行）
```

## 关键映射（Electron → 原生）

| Electron | 原生 |
|---|---|
| `setAlwaysOnTop(true,'floating')` | `window.level = .floating` |
| `setVisibleOnAllWorkspaces(true,{visibleOnFullScreen})` | `collectionBehavior = .canJoinAllSpaces (+ .fullScreenAuxiliary)` |
| 全屏 Space 探测器（CGS + 几何 + 三态状态机） | **不需要**：`collectionBehavior` 系统语义 |
| 鼠标穿透 + 50ms 光标轮询 + 热区上报 | 全局/本地鼠标监视器 + 圆角形状判定 + `ignoresMouseEvents` |
| 跨窗口状态同步（BroadcastChannel/IPC） | 单进程，一个 `ObservableObject`（字典式 Config） |
| `backdrop-filter: blur(20px)`（有合成陷阱） | `.ultraThinMaterial`（无合成问题） |
| 置顶跨窗口搬家 + 延迟隐藏 + 渲染优化 | 改 `level`，内容不搬家，零闪烁 |
| 折叠（React 重渲染 + hidden 分工） | 窗口高度 44↔H（`.frame(alignment: .top)` 防点击区错位） |
| 外部配置热重载（无此功能） | 目录 watcher + mtime + 自写保护 |

## M10 · 多显示器「按屏分别控制」（2026-09-17）

| 项 | 实现 |
|---|---|
| 屏幕标识 | `NSScreen.displayID`（`CGDirectDisplayID`），不用 `NSScreen.main`（随焦点漂移） |
| 交互目标屏 | `screenUnderCursor()` / `activeScreen()`（光标所在屏） |
| 每屏一个顶栏 | `topBars: [CGDirectDisplayID: TopBarPanel]`，回调按屏路由，闭包捕获 **screenID** 而非 NSScreen 实例 |
| 分区归属 | `panels(on:)` / `partitionIDs(on:)`，以 `panel.screen` 运行时判定（拖到哪块屏就属于哪块屏） |
| 显隐按屏 | `Config.hiddenScreens: Set<CGDirectDisplayID>`（替代原全局 `ghostHidden`） |
| 对齐按屏 | `align(mode:onScreenID:)` 只重排目标屏分区；`findFreeSlot` 只统计本屏占位 |
| 新建分区 | 在触发屏创建并于该屏排版（`createPartition(onScreenID:)`） |
| 弹窗落位 | 设置 / 新建面板改用 `activeScreen()` 落位（原 `referenceScreen()` 取「第一个分区所在屏」→ 点 A 弹 B） |
| 显示器插拔 | `screenParametersChanged` 重建顶栏 + `pruneHiddenScreens` |

### M10 补充 · 归属与对齐模式持久化（同日完成）

| 项 | 实现 |
|---|---|
| 分区归属持久化 | 分区加 `screenId`（Int = CGDirectDisplayID）：新建时写入、跨屏拖动时在 `panelDidMove` 更新；`rebuild` 按它选屏；旧配置由 `migrateScreenOwnership()` 一次性补齐 |
| 对齐模式按屏 | `settings.alignModeByScreen[screenId]`；`Config.alignMode(forScreen:)` / `setAlignMode(_:forScreen:)`；顶栏高亮、`realign`、`findFreeSlot`、新建顺承全部按屏；全局 `alignMode` 保留作默认值 |
| 显示器插拔 | `pruneScreenSettings(keeping:)` 清理失效的按屏对齐模式 |

⚠️ 注意：mac 的配置坐标是**相对所属屏**的，所以 screenId 是位置计算的必要前提。

### ⚠️ 同时修复的严重缺陷：配置从未落盘

`~/Library/Application Support/deskisle/` 首次运行时**并不存在**，而 `Config.save()` 用
`Data.write(to:)` 写临时文件——**不会自动创建目录**，于是保存静默失败（只打一条 NSLog），
表现为「分区能添加、重启后全部消失」。已在 `Config.load()` / `save()` 前统一调用 `ensureDirectory()`。

实测：写入不含 `screenId` 的测试配置 → 启动后 app 自动补齐 `screenId=2026465811` 并成功落盘。
