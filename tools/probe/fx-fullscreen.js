// 制造一个「别的应用的全屏空间」—— 独立进程，所以它的全屏窗口
// 不是 fx-window 进程自己的窗口，FullScreenAuxiliary 的「同应用」限制无法生效，
// 这正是我们要测试的真实场景。
//
// 时间线（相对本进程启动）：
//   t=0.8s  进入全屏（macOS 原生全屏，会切到一个新的空间）
//   t=14s   退出全屏
//   t=16s   退出进程

const { app, BrowserWindow, screen } = require('electron')

app.whenReady().then(() => {
  const d = screen.getPrimaryDisplay()
  console.log(`display bounds = ${JSON.stringify(d.bounds)}`)

  const win = new BrowserWindow({
    width: 900,
    height: 600,
    x: d.bounds.x + 120,
    y: d.bounds.y + 120,
    backgroundColor: '#101820',
    frame: true,
    fullscreenable: true,
    show: false,
    webPreferences: { nodeIntegration: false, contextIsolation: true },
  })

  const html = `<html><body style="margin:0;font-family:-apple-system,Helvetica;background:#101820;color:#e8eef5;
    height:100vh;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:14px">
    <div style="font-size:34px;font-weight:700">全屏空间测试</div>
    <div style="font-size:15px;color:#8fa6bb;text-align:center;line-height:1.7">
      这是一个"别的应用"的全屏空间<br>
      请不要操作，约 14 秒后自动退出全屏
    </div></body></html>`

  win.loadURL('data:text/html;charset=utf-8,' + encodeURIComponent(html))

  win.once('ready-to-show', () => {
    win.show()
    win.focus()
    app.focus({ steal: true })
    win.moveTop()
    console.log(`READY fullscreen pid=${process.pid}`)

    setTimeout(() => {
      try {
        win.setFullScreen(true)
      } catch (e) {
        console.log('setFullScreen(true) threw: ' + e)
      }
    }, 800)
  })

  // 从全屏空间内部截图，才能看到该空间里别的窗口是否在上面。
  setTimeout(() => {
    try {
      const { execSync } = require('child_process')
      execSync('screencapture -x -o /tmp/ds-from-fullscreen-space.png')
      console.log('SNAPSHOT /tmp/ds-from-fullscreen-space.png captured')
    } catch (e) {
      console.log('SNAPSHOT failed: ' + e)
    }
  }, 3000)

  // 每 2 秒汇报一次自身全屏状态，便于判断到底有没有真的进入全屏空间
  const iv = setInterval(() => {
    if (!win || win.isDestroyed()) return
    let b = {}
    try { b = win.getBounds() } catch (_) {}
    console.log(`STATUS isFullScreen=${win.isFullScreen()} bounds=${b.width}x${b.height}@${b.x},${b.y}`)
  }, 2000)

  setTimeout(() => {
    try { win.setFullScreen(false) } catch (e) { console.log('setFullScreen(false) threw: ' + e) }
  }, 14000)

  setTimeout(() => {
    clearInterval(iv)
    app.quit()
  }, 16000)
})

app.on('window-all-closed', () => app.quit())
