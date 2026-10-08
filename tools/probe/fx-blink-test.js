// 隔离实验：验证「在可见窗口上切换 setVisibleOnAllWorkspaces 的 visibleOnFullScreen」
// 是否会造成窗口可见性闪烁（置顶/取消置顶时 DeskIsle 正好会做这件事）。
//
// 窗口：亮红色 400x200，浮在 (400,600)，accessory 应用 + focusable（与 DeskIsle 一致）。
// 每 2.5 秒在 visibleOnFullScreen: false ↔ true 之间切换一次，并打印毫秒时间戳。
// 外部用 screencapture -R 连续抓该区域，窗口消失时 PNG 体积会明显变大（露出壁纸）。
//
// 运行：unset ELECTRON_RUN_AS_NODE NODE_OPTIONS
//      ./node_modules/.bin/electron scratch/fx-blink-test.js --no-sandbox

const { app, BrowserWindow } = require('electron');

app.dock.hide();
const t = () => Date.now() % 1000000;

app.whenReady().then(() => {
  const win = new BrowserWindow({
    width: 400,
    height: 200,
    x: 400,
    y: 600,
    frame: false,
    transparent: false,
    backgroundColor: '#dc2626',
    resizable: false,
    hasShadow: false,
    focusable: true,        // 与 DeskIsle 一致
    acceptFirstMouse: true,
    fullscreenable: false,  // 与 DeskIsle 一致
    skipTaskbar: true,
    show: false,
  });

  win.loadURL('data:text/html,' + encodeURIComponent(
    '<body style="margin:0"><div style="width:400px;height:200px;background:#dc2626;' +
    'color:#fff;font:700 30px -apple-system;display:flex;align-items:center;' +
    'justify-content:center">BLINK TEST</div></body>'));

  win.once('ready-to-show', () => {
    win.setAlwaysOnTop(true, 'floating', 1);
    // 初始态：模拟「没有置顶分区」时的 DeskIsle 置顶窗口
    win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: false, skipTransformProcessType: true });
    win.showInactive();
    console.log(`[${t()}] shown, visibleOnFullScreen=false`);

    let flag = false;
    let n = 0;
    const timer = setInterval(() => {
      flag = !flag;
      n += 1;
      if (n > 8) { clearInterval(timer); console.log(`[${t()}] done`); return; }
      console.log(`[${t()}] calling setVisibleOnAllWorkspaces(visibleOnFullScreen=${flag})`);
      win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: flag, skipTransformProcessType: true });
      console.log(`[${t()}] call returned, isVisible=${win.isVisible()}`);
    }, 2500);
  });
});
