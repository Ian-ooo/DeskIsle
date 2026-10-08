// 一次性实验：验证 createWindow 参数里哪些项会让 macOS 把窗口约束到「可见区域」
// （表现为 y=25 / height=1175 而不是 0 / 1200）。
// 用法：electron scratch/fx-bounds-test.js --no-sandbox
const { app, BrowserWindow, screen } = require('electron');

app.whenReady().then(async () => {
  const b = screen.getPrimaryDisplay().bounds;
  console.log('primary display bounds =', JSON.stringify(b));

  const base = {
    width: b.width, height: b.height, x: b.x, y: b.y,
    transparent: true, backgroundColor: '#00000000',
    frame: false, hasShadow: false,
    focusable: true, acceptFirstMouse: true,
    fullscreenable: false, skipTaskbar: true,
  };

  const cases = [
    ['A 无 show:false（旧 mainWindow 的写法）', { ...base }],
    ['B 有 show:false + showInactive', { ...base, show: false }],
    ['C 有 show:false + setBounds 后再 show', { ...base, show: false }],
  ];

  for (const [name, opts] of cases) {
    const win = new BrowserWindow(opts);
    if (opts.show === false) {
      if (name.startsWith('C')) {
        win.showInactive();
        win.setBounds({ x: b.x, y: b.y, width: b.width, height: b.height });
      } else {
        win.showInactive();
      }
    }
    await new Promise((r) => setTimeout(r, 700));
    console.log(`${name}\n   getBounds()        = ${JSON.stringify(win.getBounds())}\n   getContentBounds() = ${JSON.stringify(win.getContentBounds())}`);
    win.destroy();
  }

  app.quit();
});
