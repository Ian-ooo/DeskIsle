// 实验 2：验证 setVisibleOnAllWorkspaces(true) 是否会把窗口拉回 0,0 全屏尺寸
// （边框less透明窗口在普通层级下会被 macOS 约束到「可见区域」= 菜单栏之下）
const { app, BrowserWindow, screen } = require('electron');

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// 不订阅这个事件时，销毁最后一个窗口会直接退出应用，导致后面的用例跑不到
app.on('window-all-closed', () => {});

app.whenReady().then(async () => {
  const b = screen.getPrimaryDisplay().bounds;
  console.log('primary bounds =', JSON.stringify(b));

  const mk = (extra = {}) => new BrowserWindow({
    width: b.width, height: b.height, x: b.x, y: b.y,
    transparent: true, backgroundColor: '#00000000',
    frame: false, hasShadow: false, focusable: true, acceptFirstMouse: true,
    fullscreenable: false, skipTaskbar: true, show: false,
    ...extra,
  });

  const report = (label, win) => {
    console.log(`${label}: getBounds=${JSON.stringify(win.getBounds())}`);
  };

  // A: 只 showInactive
  let w = mk();
  w.showInactive();
  await sleep(600);
  report('A 仅 showInactive', w);
  w.destroy();

  // B: showInactive + setVisibleOnAllWorkspaces(true, {visibleOnFullScreen:false, skipTransformProcessType:true})
  w = mk();
  w.setAlwaysOnTop(false);
  w.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: false, skipTransformProcessType: true });
  w.showInactive();
  await sleep(600);
  report('B +setVisibleOnAllWorkspaces(vfs=false,skip)', w);
  w.destroy();

  // C: 同上但 visibleOnFullScreen=true
  w = mk();
  w.setAlwaysOnTop(true, 'floating', 1);
  w.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true, skipTransformProcessType: true });
  w.showInactive();
  await sleep(600);
  report('C +setVisibleOnAllWorkspaces(vfs=true,skip) +floating', w);
  w.destroy();

  // D: showInactive 后再 setBounds（看看能否强行掰回去）
  w = mk();
  w.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: false, skipTransformProcessType: true });
  w.showInactive();
  await sleep(300);
  w.setBounds({ x: b.x, y: b.y, width: b.width, height: b.height });
  await sleep(400);
  report('D 先 show 后 setBounds', w);
  w.destroy();

  // E: 不用 setVisibleOnAllWorkspaces，改用 setBounds 硬设
  w = mk();
  w.showInactive();
  await sleep(300);
  w.setBounds({ x: b.x, y: b.y, width: b.width, height: b.height });
  await sleep(400);
  report('E 仅 setBounds', w);
  w.destroy();

  app.quit();
});
