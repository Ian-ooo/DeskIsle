// 最小可靠实验：先确认「浮窗在桌面上确实可见」，再测「能否盖住其他应用全屏」。
// 分两阶段，由 stdin 控制：启动后 3 秒自动抓自检图，之后保持存活并每 2 秒打印一次心跳。

const { app, BrowserWindow, screen } = require('electron');
const fs = require('fs');

app.dock.hide();

const log = (...a) => console.log(`[fx ${new Date().toISOString().slice(11, 19)}]`, ...a);

process.on('uncaughtException', (e) => log('uncaughtException', e && e.message));
process.on('unhandledRejection', (e) => log('unhandledRejection', e && String(e)));
app.on('quit', () => log('app quit'));

app.whenReady().then(async () => {
  log('pid', process.pid, 'ready');

  const variants = [
    { key: 'A', color: '#dc2626', level: 'floating', skip: true, x: 120 },
    { key: 'B', color: '#16a34a', level: 'screen-saver', skip: true, x: 620 },
    { key: 'C', color: '#2563eb', level: 'status', skip: true, x: 1120 },
    { key: 'D', color: '#ca8a04', level: 'floating', skip: false, x: 1620 },
  ];

  const wins = [];
  for (const v of variants) {
    const win = new BrowserWindow({
      width: 440,
      height: 160,
      x: v.x,
      y: 140,
      frame: false,
      transparent: false,
      backgroundColor: v.color,
      resizable: false,
      hasShadow: false,
      focusable: false,
      skipTaskbar: true,
      show: false,
    });

    win.on('closed', () => log(`${v.key} window closed`));
    win.webContents.on('render-process-gone', (_e, d) => log(`${v.key} renderer gone`, d));

    win.loadURL(
      'data:text/html,' +
        encodeURIComponent(
          `<body style="margin:0"><div style="width:440px;height:160px;background:${v.color};
            color:#fff;font:700 26px -apple-system;display:flex;align-items:center;
            justify-content:center">${v.key}</div></body>`
        )
    );

    win.once('ready-to-show', () => {
      win.setAlwaysOnTop(true, v.level, 1);
      win.setVisibleOnAllWorkspaces(true, {
        visibleOnFullScreen: true,
        skipTransformProcessType: v.skip,
      });
      win.showInactive();
      log(`${v.key} shown level=${v.level} skip=${v.skip} visible=${win.isVisible()} bounds=${JSON.stringify(win.getBounds())}`);
    });

    wins.push({ v, win });
  }

  // 自检：把每个窗口自身内容截图落盘，确认真的渲染了
  setTimeout(async () => {
    for (const { v, win } of wins) {
      try {
        const img = await win.capturePage();
        fs.writeFileSync(`/tmp/fx-selfcheck-${v.key}.png`, img.toPNG());
        log(`${v.key} selfcheck png bytes=${fs.statSync(`/tmp/fx-selfcheck-${v.key}.png`).size}`);
      } catch (e) {
        log(`${v.key} capturePage failed`, e.message);
      }
    }
  }, 2500);

  setInterval(() => {
    log('heartbeat', wins.map(({ v, win }) => `${v.key}:${win.isDestroyed() ? 'destroyed' : 'alive'}`).join(' '));
  }, 2000);
});
