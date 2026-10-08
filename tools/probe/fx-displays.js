// 一次性诊断：打印 Electron 侧看到的显示器配置
const { app, screen } = require('electron');
app.on('window-all-closed', () => {});
app.whenReady().then(() => {
  const p = screen.getPrimaryDisplay();
  console.log('[disp] primary      =', JSON.stringify(p.bounds), 'scale=', p.scaleFactor, 'workArea=', JSON.stringify(p.workArea));
  screen.getAllDisplays().forEach((d, i) => {
    console.log('[disp] display ' + i + ' =', JSON.stringify(d.bounds), 'scale=', d.scaleFactor, 'id=', d.id);
  });
  app.quit();
});
