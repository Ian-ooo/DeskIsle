import AppKit

// DeskIsle（mac 原生版）入口。
// accessory 激活策略 = 不占 Dock、不出现在应用切换器，桌面挂件语义。
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
