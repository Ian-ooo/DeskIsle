// 「伪全屏」发生器：制造一个 y=0、铺满屏幕的窗口，用来复现全屏探测器的几何假阳性。
//
// 为什么需要它：普通的无边框窗口会被 macOS 约束到「可见区域」(0,25)，
// 顶层不是 0，因此不会命中「顶边贴屏幕顶端」的判据。
// 只有 `setSimpleFullScreen(true)` 这类真正铺到菜单栏之上的窗口才满足 y≈0、height≈屏幕高。
// 它不会切换 Space（不是原生全屏 Space），所以权威判据仍会说「桌面」——
// 这正好复现了「几何提前信号说全屏、权威信号说桌面」的假阳性。
//
// 用法：electron scratch/fx-fake-fullscreen.js [持续时间秒，默认 12] --no-sandbox
const { app, BrowserWindow, screen } = require('electron');

app.on('window-all-closed', () => {});

const holdSec = Number(process.argv[2]) || 12;

app.whenReady().then(async () => {
  const b = screen.getPrimaryDisplay().bounds;
  const win = new BrowserWindow({
    width: b.width, height: b.height, x: b.x, y: b.y,
    frame: false, hasShadow: false, skipTaskbar: true,
    backgroundColor: '#101820',
    webPreferences: { nodeIntegration: true, contextIsolation: false }
  });
  win.loadURL('data:text/html;charset=utf-8,' + encodeURIComponent(
    '<body style="margin:0;background:#101820;color:#7dd3fc;font:28px -apple-system;display:flex;align-items:center;justify-content:center">伪全屏测试窗口</body>'
  ));
  win.once('ready-to-show', () => {
    win.setSimpleFullScreen(true);
    console.log('[fake-fs] ON  bounds=', JSON.stringify(win.getBounds()));
  });
  await new Promise((r) => setTimeout(r, 2500));
  console.log('[fake-fs] 保持 ' + holdSec + ' 秒…');
  await new Promise((r) => setTimeout(r, holdSec * 1000));
  console.log('[fake-fs] OFF');
  try { win.setSimpleFullScreen(false); } catch (_) {}
  await new Promise((r) => setTimeout(r, 800));
  app.quit();
});
