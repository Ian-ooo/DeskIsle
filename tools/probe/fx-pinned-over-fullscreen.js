// 隔离实验：验证「accessory 应用的 floating 窗口能否盖住**其他应用**的原生全屏 Space」。
// 完全模拟 DeskIsle pinnedWindow 的窗口配置，不触碰 DeskIsle 的用户配置。
//
// 运行：
//   unset ELECTRON_RUN_AS_NODE NODE_OPTIONS
//   ./node_modules/.bin/electron scratch/fx-pinned-over-fullscreen.js --no-sandbox
//
// 关闭：./node_modules/.bin/electron 进程退出（Cmd+Q 或 kill）

const { app, BrowserWindow } = require('electron');

app.dock.hide(); // 关键：与 DeskIsle 一样是 accessory（LSUIElement）应用

app.whenReady().then(() => {
  const win = new BrowserWindow({
    width: 420,
    height: 260,
    x: 200,
    y: 200,
    frame: false,
    transparent: true,
    resizable: false,
    hasShadow: false,
    focusable: false,
    skipTaskbar: true,
    show: false,
    webPreferences: { nodeIntegration: true, contextIsolation: false },
  });

  win.loadURL(
    'data:text/html,' +
      encodeURIComponent(`
      <body style="margin:0">
        <div style="width:420px;height:260px;background:rgba(220,38,38,0.92);border:4px solid #fde047;
                    border-radius:18px;color:#fff;font:600 22px -apple-system;display:flex;
                    align-items:center;justify-content:center;text-align:center;line-height:1.5">
          FULLSCREEN-AUX 测试浮窗<br/>（应盖在其他应用全屏之上）
        </div>
      </body>`)
  );

  win.once('ready-to-show', () => {
    // === 与 DeskIsle pinnedWindow 完全一致的窗口属性 ===
    win.setAlwaysOnTop(true, 'floating', 1);
    win.setVisibleOnAllWorkspaces(true, {
      visibleOnFullScreen: true,
      skipTransformProcessType: true,
    });
    win.showInactive();
    console.log('[fx] floating/auxiliary window shown');
    console.log('[fx] isVisibleOnAllWorkspaces =', win.isVisibleOnAllWorkspaces());
  });
});

app.on('window-all-closed', () => app.quit());
