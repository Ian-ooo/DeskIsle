// 隔离实验：找出「vofs:false 的窗口在全屏空间下仍然可见」的根因。
//
// 上一轮实验的对照组 E（screen-saver / vofs=false / skip=false）确实被隐藏了，
// 但 DeskIsle 的 mainWindow（vofs=false / skip=true）没有。两者配置上唯一的差别
// 是 skipTransformProcessType —— 而它并不是"无副作用"的：
//
//   SetVisibleOnAllWorkspaces(visible=true, visibleOnFullScreen=false, skip=false)
//     → Browser::DockShow() → TransformProcessType(kProcessTransformToForegroundApplication)
//
// 也就是说：E 的进程最终是「前台应用」，而 DeskIsle 因为传了 skip=true，
// 进程始终停在 UIElement（accessory）状态。macOS 对这两类进程的窗口在全屏空间下的
// 处置策略可能完全不同 —— 本实验就是这个猜想的判决性测试。
//
// 2x2 自变量：进程类型（Foreground / UIElement）× 窗口层级（0 / floating / screen-saver）
// 全部窗口都设 visibleOnFullScreen=false，并且都 fullscreenable=false
// （注意：fullscreenable=false 会把 FullScreenAuxiliary 置 1，见 native_window_mac.mm，
//  所以我们随后必须用 setVisibleOnAllWorkspaces(false) 把它清掉）。
//
// 用法: electron scratch/fx-vofs.js <E|G|H|I|K|L> --no-sandbox

const { app, BrowserWindow, screen } = require('electron')

const SPECS = {
  // key: 进程类型      层级              skip
  E: { mode: 'foreground', level: 'screen-saver', skip: false, color: '#7f8c8d', note: '对照组(上轮已证实隐藏)' },
  G: { mode: 'foreground', level: 'floating', skip: false, color: '#27ae60', note: '前台进程·floating' },
  L: { mode: 'foreground', level: null, skip: false, color: '#16a085', note: '前台进程·普通层级(0)' },
  H: { mode: 'uielement', level: 'floating', skip: true, color: '#c0392b', note: 'UIElement·floating' },
  I: { mode: 'uielement', level: 'screen-saver', skip: true, color: '#d35400', note: 'UIElement·screen-saver' },
  K: { mode: 'uielement', level: null, skip: true, color: '#8e44ad', note: 'UIElement·普通层级 = mainWindow 精确模仿' },
}

const key = (process.argv[2] || 'E').toUpperCase()
const spec = SPECS[key]
if (!spec) {
  console.error(`未知的 key: ${key}`)
  app.exit(2)
}

const ORDER = Object.keys(SPECS)

app.whenReady().then(() => {
  // UIElement 模式：和 DeskIsle 的 whenReady() → hideDock() 一致
  // 前台模式：先 hide 再由 setVisibleOnAllWorkspaces 的 DockShow 转回前台
  if (process.platform === 'darwin' && app.dock) {
    try { app.dock.hide() } catch (_) {}
  }

  const d = screen.getPrimaryDisplay()
  const W = 340
  const H = 74
  const GAP = 6
  const idx = ORDER.indexOf(key)

  const win = new BrowserWindow({
    width: W,
    height: H,
    x: d.bounds.x + 40,
    y: d.bounds.y + 40 + idx * (H + GAP),
    transparent: true,
    backgroundColor: '#00000000',
    frame: false,
    hasShadow: false,
    focusable: true,
    acceptFirstMouse: true,
    fullscreenable: false, // 与 DeskIsle / 上轮实验保持一致
    skipTaskbar: true,
    show: false,
    webPreferences: { nodeIntegration: false, contextIsolation: true },
  })

  const html = `<html><body style="margin:0;font-family:-apple-system,Helvetica;height:100vh;
    display:flex;align-items:center;justify-content:center;background:${spec.color};color:#fff">
    <div style="text-align:center">
      <div style="font-size:32px;font-weight:800;line-height:1">${key}</div>
      <div style="font-size:11px;margin-top:5px;opacity:.95">
        ${spec.mode} · level=${spec.level === null ? '0(默认)' : spec.level} · vofs=false · skip=${spec.skip}
      </div>
      <div style="font-size:10px;margin-top:3px;opacity:.8">${spec.note}</div>
    </div></body></html>`

  win.loadURL('data:text/html;charset=utf-8,' + encodeURIComponent(html))

  // 与 DeskIsle createWindow() 的顺序保持一致：先定层级，再下发跨空间可见性
  if (spec.level) {
    win.setAlwaysOnTop(true, spec.level, 1)
  } else {
    win.setAlwaysOnTop(false)
  }

  win.setVisibleOnAllWorkspaces(true, {
    visibleOnFullScreen: false,
    skipTransformProcessType: spec.skip,
  })

  win.showInactive()

  console.log(
    `READY ${key} pid=${process.pid} mode=${spec.mode} level=${spec.level === null ? 0 : spec.level} vofs=false skip=${spec.skip}`
  )
})

app.on('window-all-closed', () => {})
