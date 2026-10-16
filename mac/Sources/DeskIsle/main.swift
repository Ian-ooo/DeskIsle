import AppKit

// DeskIsle（mac 原生版）入口。
// accessory 激活策略 = 不占 Dock、不出现在应用切换器，桌面挂件语义。
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)

// ⚠️ 必须在 `NSApplication.shared` 之后、且在 `run()` 之前装：
// 无边框面板上的文本控件靠主菜单里的标准编辑项才能响应 ⌘C/⌘X/⌘V/⌘A/⌘Z，
// 没有它「分区内复制的文字在分区外粘贴不上」。详见 MainMenu.swift 的 A/B 实测。
MainMenuBuilder.install()

app.run()
