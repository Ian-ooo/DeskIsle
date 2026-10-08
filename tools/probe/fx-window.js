// 单个测试窗口 —— 每个配置跑一个进程，避免进程级状态（激活策略/DockShow）互相污染。
//
// 用法: electron scratch/fx-window.js <A..F>
//
// 测试矩阵的两个自变量：
//   1. 窗口层级 level（floating=3 / screen-saver=1000）
//   2. visibleOnFullScreen 与 skipTransformProcessType
// 另外区分透明/不透明窗口 —— DeskIsle 用的是 transparent:true，
// 而透明 NSWindow 在全屏空间下的表现可能与不透明窗口不同。

const { app, BrowserWindow, screen } = require('electron')

const SPECS = {
  A: { level: 'floating',     vofs: true,  transparent: false, skip: false, color: '#c0392b' },
  B: { level: 'screen-saver', vofs: true,  transparent: false, skip: false, color: '#27ae60' },
  C: { level: 'screen-saver', vofs: true,  transparent: true,  skip: false, color: '#2980b9' },
  D: { level: 'floating',     vofs: true,  transparent: true,  skip: false, color: '#8e44ad' },
  E: { level: 'screen-saver', vofs: false, transparent: true,  skip: false, color: '#7f8c8d' },
  F: { level: 'screen-saver', vofs: true,  transparent: false, skip: true,  color: '#d35400' },
}

const key = (process.argv[2] || 'A').toUpperCase()
const spec = SPECS[key] || SPECS.A

app.whenReady().then(() => {
  // 与 DeskIsle 保持一致：应用本身就是 UIElement（无 Dock 图标）
  if (process.platform === 'darwin' && app.dock) {
    try { app.dock.hide() } catch (_) {}
  }

  const d = screen.getPrimaryDisplay()
  const W = 400
  const H = 96
  const GAP = 6
  const idx = Object.keys(SPECS).indexOf(key)

  const win = new BrowserWindow({
    width: W,
    height: H,
    x: d.bounds.x + 40,
    y: d.bounds.y + 40 + idx * (H + GAP),
    transparent: spec.transparent,
    backgroundColor: spec.transparent ? '#00000000' : spec.color,
    frame: false,
    hasShadow: false,
    focusable: true,
    fullscreenable: false,
    skipTaskbar: true,
    show: false,
    webPreferences: { nodeIntegration: false, contextIsolation: true },
  })

  const bg = spec.transparent ? spec.color : 'transparent'
  const html = `<html><body style="margin:0;font-family:-apple-system,Helvetica;height:100vh;
    display:flex;align-items:center;justify-content:center;background:${bg};color:#fff">
    <div style="text-align:center">
      <div style="font-size:40px;font-weight:800;line-height:1">${key}</div>
      <div style="font-size:13px;margin-top:6px;opacity:.95">
        level=${spec.level} · vofs=${spec.vofs} · ${spec.transparent ? '透明' : '不透明'}${spec.skip ? ' · skip=true' : ''}
      </div>
    </div></body></html>`

  win.loadURL('data:text/html;charset=utf-8,' + encodeURIComponent(html))

  // 先设跨空间可见性，再设层级 —— 顺序影响可能存在的相互覆盖
  win.setVisibleOnAllWorkspaces(true, {
    visibleOnFullScreen: spec.vofs,
    skipTransformProcessType: spec.skip,
  })
  win.setAlwaysOnTop(true, spec.level, 1)

  win.showInactive()

  console.log(`READY ${key} pid=${process.pid} level=${spec.level} vofs=${spec.vofs} transparent=${spec.transparent} skip=${spec.skip}`)
})

// 保持存活，由驱动脚本统一收尾
app.on('window-all-closed', () => {})
