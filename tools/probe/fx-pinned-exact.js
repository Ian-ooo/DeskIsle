// 逐字段复刻 DeskIsle pinnedWindow 的浮窗，验证两件事：
//   1) 在普通桌面上确实可见（用来校验实验有效性）
//   2) 能否盖在**其他应用**的原生全屏 Space 之上
//
// P = 完全复刻 DeskIsle（floating + fullscreenable:false + focusable:true + skip:true）
// Q = P 但窗口层级提升到 screen-saver（对比用）
//
// 运行：
//   unset ELECTRON_RUN_AS_NODE NODE_OPTIONS
//   ./node_modules/.bin/electron scratch/fx-pinned-exact.js --no-sandbox

const { app, BrowserWindow, screen } = require('electron');
const fs = require('fs');

app.dock.hide();

const log = (...a) => console.log(`[fx ${new Date().toISOString().slice(11, 19)}]`, ...a);

function buildWindow(tag, color, level, skip, offsetY) {
  const { width, height, x, y } = screen.getPrimaryDisplay().bounds;

  // ==== 与 DeskIsle createPinnedWindow 完全一致的窗口属性 ====
  const win = new BrowserWindow({
    width,
    height,
    x,
    y,
    transparent: true,
    backgroundColor: '#00000000',
    frame: false,
    hasShadow: false,
    focusable: true,
    acceptFirstMouse: true,
    fullscreenable: false,
    skipTaskbar: true,
    show: false,
  });

  win.loadURL(
    'data:text/html,' +
      encodeURIComponent(`
      <body style="margin:0;background:transparent">
        <div style="position:absolute;left:120px;top:${offsetY}px;width:760px;height:150px;
             background:${color};border-radius:16px;color:#fff;
             font:700 24px -apple-system;display:flex;align-items:center;justify-content:center;
             box-shadow:0 8px 30px rgba(0,0,0,.5)">
          ${tag}
        </div>
      </body>`)
  );

  win.once('ready-to-show', () => {
    win.setAlwaysOnTop(true, level, 1);
    win.setVisibleOnAllWorkspaces(true, {
      visibleOnFullScreen: true,
      skipTransformProcessType: skip,
    });
    win.setIgnoreMouseEvents(true); // 与 DeskIsle 一致
    win.showInactive();
    log(`${tag} shown: level=${level} skip=${skip} vofs=${win.isVisibleOnAllWorkspaces()} bounds=${JSON.stringify(win.getBounds())}`);
  });

  return win;
}

app.whenReady().then(() => {
  log('pid', process.pid, 'display', JSON.stringify(screen.getPrimaryDisplay().bounds));
  buildWindow('P 复刻DeskIsle(floating,skip:true)', '#dc2626', 'floating', true, 300);
  buildWindow('Q floating+screen-saver', '#16a34a', 'screen-saver', true, 470);

  setTimeout(async () => {
    for (const [tag, file] of [['P', '/tmp/fxP.png'], ['Q', '/tmp/fxQ.png']]) {
      const w = BrowserWindow.getAllWindows()[tag === 'P' ? 0 : 1];
      try {
        const img = await w.capturePage();
        fs.writeFileSync(file, img.toPNG());
        log(`${tag} selfcheck bytes=${fs.statSync(file).size}`);
      } catch (e) {
        log(`${tag} selfcheck failed`, e.message);
      }
    }
  }, 2500);

  setInterval(() => log('heartbeat windows=', BrowserWindow.getAllWindows().length), 3000);
});
