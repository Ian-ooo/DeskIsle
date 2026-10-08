// 探测：当另一个应用进入原生全屏时，Electron 的 screen 模块会不会
// 通过 display-metrics-changed 通知，并且 workArea/bounds 是否变化。

const { app, screen } = require('electron')

function dump(prefix) {
  const d = screen.getPrimaryDisplay()
  console.log(`${prefix} bounds=${d.bounds.width}x${d.bounds.height}@${d.bounds.x},${d.bounds.y} workArea=${d.workArea.width}x${d.workArea.height}@${d.workArea.x},${d.workArea.y} scale=${d.scaleFactor}`)
}

app.whenReady().then(() => {
  dump('READY')

  screen.on('display-metrics-changed', (_event, display, changedMetrics) => {
    console.log(`EVENT display-metrics-changed id=${display.id} metrics=${changedMetrics.join(',')}`)
    dump('AFTER_EVENT')
  })

  screen.on('display-added', (_event, display) => {
    console.log(`EVENT display-added id=${display.id}`)
  })

  screen.on('display-removed', (_event, display) => {
    console.log(`EVENT display-removed id=${display.id}`)
  })

  setInterval(() => {
    dump('TICK')
  }, 500)

  setTimeout(() => app.quit(), 25000)
})
