// 配置矩阵：找出「能盖在**其他应用**原生全屏 Space 之上」的窗口配置。
// 四个小窗并排，唯一变量是 窗口层级 / skipTransformProcessType / 是否显式 setFullScreenable。
//
//   R 红 = floating       + skip 默认(false → 会 DockHide)
//   S 绿 = floating       + skip:true（DeskIsle 现状，对照组）
//   T 蓝 = screen-saver   + skip 默认(false)
//   U 黄 = main-menu      + skip:true
//
// 运行：unset ELECTRON_RUN_AS_NODE NODE_OPTIONS
//      ./node_modules/.bin/electron scratch/fx-matrix.js --no-sandbox

const { app, BrowserWindow } = require('electron');

app.dock.hide();
const log = (...a) => console.log(`[fx ${new Date().toISOString().slice(11, 19)}]`, ...a);

const VARIANTS = [
  { tag: 'R floating+skipDefault', color: '#dc2626', level: 'floating', skip: false, x: 80 },
  { tag: 'S floating+skipTrue', color: '#16a34a', level: 'floating', skip: true, x: 560 },
  { tag: 'T screenSaver+skipDefault', color: '#2563eb', level: 'screen-saver', skip: false, x: 1040 },
  { tag: 'U mainMenu+skipTrue', color: '#ca8a04', level: 'main-menu', skip: true, x: 1440 },
];

app.whenReady().then(() => {
  log('pid', process.pid);

  for (const v of VARIANTS) {
    const win = new BrowserWindow({
      width: 440,
      height: 170,
      x: v.x,
      y: 300,
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
        encodeURIComponent(
          `<body style="margin:0;background:transparent"><div style="width:440px;height:170px;
            background:${v.color};border-radius:14px;color:#fff;font:700 21px -apple-system;
            display:flex;align-items:center;justify-content:center;text-align:center;padding:10px">
            ${v.tag}</div></body>`
        )
    );

    win.once('ready-to-show', () => {
      win.setAlwaysOnTop(true, v.level, 1);
      if (v.skip) {
        win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true, skipTransformProcessType: true });
      } else {
        win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
      }
      win.setIgnoreMouseEvents(true);
      win.showInactive();
      log(`${v.tag} shown level=${v.level} skip=${v.skip} vofs=${win.isVisibleOnAllWorkspaces()}`);
    });
  }

  setInterval(() => log('heartbeat', BrowserWindow.getAllWindows().length), 4000);
});
