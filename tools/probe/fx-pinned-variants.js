// 对照实验：哪种窗口配置能「盖在**其他应用**的原生全屏 Space 之上」？
// 四个窗口并排，属性各不相同，进 Chrome 全屏后抓屏，看哪几个可见。
//
// 运行：
//   unset ELECTRON_RUN_AS_NODE NODE_OPTIONS
//   ./node_modules/.bin/electron scratch/fx-pinned-variants.js --no-sandbox

const { app, BrowserWindow } = require('electron');

app.dock.hide(); // accessory 应用（与 DeskIsle 相同）

const VARIANTS = [
  { key: 'A', label: 'floating + skip:true（DeskIsle 现状）', color: '#dc2626', level: 'floating', skip: true },
  { key: 'B', label: 'screen-saver + skip:true', color: '#16a34a', level: 'screen-saver', skip: true },
  { key: 'C', label: 'status + skip:true', color: '#2563eb', level: 'status', skip: true },
  { key: 'D', label: 'floating + skip:false（会 DockHide）', color: '#ca8a04', level: 'floating', skip: false },
];

app.whenReady().then(() => {
  VARIANTS.forEach((v, i) => {
    const win = new BrowserWindow({
      width: 460,
      height: 150,
      x: 120 + i * 480,
      y: 120,
      frame: false,
      transparent: true,
      resizable: false,
      hasShadow: false,
      focusable: false,
      skipTaskbar: true,
      show: false,
    });

    win.loadURL(
      'data:text/html,' +
        encodeURIComponent(
          `<body style="margin:0"><div style="width:460px;height:150px;background:${v.color};
            border:4px solid #fff;border-radius:14px;color:#fff;font:600 19px -apple-system;
            display:flex;align-items:center;justify-content:center;text-align:center;padding:8px">
            ${v.key}: ${v.label}</div></body>`
        )
    );

    win.once('ready-to-show', () => {
      win.setAlwaysOnTop(true, v.level, 1);
      win.setVisibleOnAllWorkspaces(true, {
        visibleOnFullScreen: true,
        skipTransformProcessType: v.skip,
      });
      win.showInactive();
      console.log(`[fx] ${v.key} shown: level=${v.level} skip=${v.skip} vofs=${win.isVisibleOnAllWorkspaces()}`);
    });
  });
});

app.on('window-all-closed', () => app.quit());
