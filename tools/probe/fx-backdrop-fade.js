// 对照实验：确认「backdrop-filter 与祖先 opacity 的相互作用」是否是
// 「外框先消失、内容后消失」的原因。
//
// 三个方案并排放在同一个窗口里，背景画满高对比条纹（这样「有没有模糊」一眼可辨）：
//   A. 祖先 opacity 过渡 + 子元素 backdrop-filter  ← 复刻当前分区实现
//   B. 元素自身 opacity 过渡 + 自身 backdrop-filter
//   C. 祖先 opacity 过渡 + 无 backdrop-filter（对照组）
//
// 过渡时长故意拉到 2s，方便用 screencapture 抓到中间帧。
// 用法：electron scratch/fx-backdrop-fade.js --no-sandbox
const { app, BrowserWindow, screen } = require('electron');

app.on('window-all-closed', () => {});

const html = `<!doctype html><html><head><meta charset="utf-8"><style>
  html,body{margin:0;height:100%;overflow:hidden;font:14px -apple-system,sans-serif;color:#fff}
  body{
    /* 高对比条纹背景：模糊与否极易分辨 */
    background: repeating-linear-gradient(90deg,#fff 0 6px,#111 6px 12px),
                repeating-linear-gradient(0deg,rgba(255,255,255,.35) 0 3px,rgba(0,0,0,.55) 3px 6px);
    background-blend-mode: overlay;
  }
  .row{display:flex;gap:40px;padding:80px}
  .wrap{width:300px}
  .fade{transition:opacity 2s linear}
  .box{
    border:1px solid rgba(255,255,255,.15);
    border-radius:16px;
    background:rgba(15,23,42,.65);
    padding:20px;
    color:#f8fafc;
    box-shadow:0 25px 50px -12px rgba(0,0,0,.4);
  }
  .blur{backdrop-filter:blur(20px);-webkit-backdrop-filter:blur(20px)}
  h3{margin:0 0 10px;font-size:15px;color:#38bdf8}
  p{margin:4px 0;font-size:13px}
  .tag{font-family:ui-monospace,monospace;font-size:11px;color:#94a3b8;margin-bottom:8px}
</style></head><body>
<div class="row">
  <div class="wrap">
    <div class="tag">A 祖先 opacity + 子 backdrop-filter（复刻现状）</div>
    <div class="fade" id="a"><div class="box blur"><h3>分区标题</h3><p>内容行 一</p><p>内容行 二</p><p>内容行 三</p></div></div>
  </div>
  <div class="wrap">
    <div class="tag">B 自身 opacity + 自身 backdrop-filter</div>
    <div id="b"><div class="box blur" style="transition:opacity 2s linear"><h3>分区标题</h3><p>内容行 一</p><p>内容行 二</p><p>内容行 三</p></div></div>
  </div>
  <div class="wrap">
    <div class="tag">C 祖先 opacity，无 backdrop-filter（对照）</div>
    <div class="fade" id="c"><div class="box"><h3>分区标题</h3><p>内容行 一</p><p>内容行 二</p><p>内容行 三</p></div></div>
  </div>
</div>
<script>
  window.__hide = () => {
    document.getElementById('a').style.opacity = '0';
    document.getElementById('b').firstElementChild.style.opacity = '0';
    document.getElementById('c').style.opacity = '0';
  };
  window.__show = () => {
    document.getElementById('a').style.opacity = '1';
    document.getElementById('b').firstElementChild.style.opacity = '1';
    document.getElementById('c').style.opacity = '1';
  };
</script></body></html>`;

app.whenReady().then(() => {
  const b = screen.getPrimaryDisplay().bounds;
  const win = new BrowserWindow({
    width: b.width, height: b.height, x: b.x, y: b.y,
    transparent: false, frame: false, hasShadow: false,
    fullscreenable: false, skipTaskbar: true,
    webPreferences: { nodeIntegration: true, contextIsolation: false }
  });
  win.loadURL('data:text/html;charset=utf-8,' + encodeURIComponent(html));
  win.webContents.on('did-finish-load', async () => {
    console.log('[exp] loaded; 3 秒后开始隐藏，请观察并抓帧');
    await new Promise((r) => setTimeout(r, 3000));
    console.log('[exp] HIDE now');
    win.webContents.executeJavaScript('window.__hide()');
    await new Promise((r) => setTimeout(r, 4000));
    console.log('[exp] SHOW now');
    win.webContents.executeJavaScript('window.__show()');
    await new Promise((r) => setTimeout(r, 4000));
    console.log('[exp] done');
    app.quit();
  });
});
