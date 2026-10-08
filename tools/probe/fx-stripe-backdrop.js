// 静态高对比条纹背景窗口：给置顶分区当"背景板"，让 backdrop-filter 的
// 有/无可以通过像素方差测出来（壁纸太柔和，测不出差异）。
// 用法：electron scratch/fx-stripe-backdrop.js --no-sandbox   （Ctrl+C / kill 退出）
const { app, BrowserWindow, screen } = require('electron');

app.on('window-all-closed', () => {});

const html = `<!doctype html><html><head><meta charset="utf-8"><style>
  html,body{margin:0;height:100%;overflow:hidden}
  body{
    background: repeating-linear-gradient(90deg,#fff 0 6px,#111 6px 12px),
                repeating-linear-gradient(0deg,rgba(255,255,255,.35) 0 3px,rgba(0,0,0,.55) 3px 6px);
    background-blend-mode: overlay;
  }
</style></head><body></body></html>`;

app.whenReady().then(() => {
  const b = screen.getPrimaryDisplay().bounds;
  const win = new BrowserWindow({
    width: b.width, height: b.height, x: b.x, y: b.y,
    transparent: false, frame: false, hasShadow: false,
    fullscreenable: false, skipTaskbar: true,
    webPreferences: { nodeIntegration: true, contextIsolation: false }
  });
  win.loadURL('data:text/html;charset=utf-8,' + encodeURIComponent(html));
  win.webContents.on('did-finish-load', () => console.log('[stripe] ready'));
});
