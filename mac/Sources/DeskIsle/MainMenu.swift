import AppKit

// MARK: - 主菜单（标准编辑命令的唯一载体）

/// DeskIsle 的主菜单 —— **存在的唯一理由是让 ⌘C / ⌘X / ⌘V / ⌘A / ⌘Z 生效**。
///
/// ## 为什么一个「不占 Dock 的桌面挂件」需要主菜单
///
/// 无边框 `NSPanel` 上的文本控件**收不到标准编辑快捷键**，除非主菜单里有对应项。
/// 实测（2026-10-16，`/tmp/fc4` A/B 对照，两组除 mainMenu 外完全一致）：
///
/// | 组 | `NSApp.mainMenu` | 按 ⌘C 后剪贴板 |
/// |---|---|---|
/// | A | `nil`（修复前） | **没变** —— 文字没进系统剪贴板 |
/// | B | 有「拷贝 ⌘C」 | 变成选中的文字 ✔ |
///
/// 症状就是用户报的「分区内复制的文字，在分区外粘贴不上」：
/// 便签里选好一段字按 ⌘C，看着像复制了（`NSTextView` 也确实处理了 `copy:`），
/// 但那条路径只在**响应链里有对应菜单项**时才会被走到；没有菜单项时按键直接
/// 落到 `NSWindow` 底层的默认处理 —— 什么也不做，且**不报错、不弹提示**。
///
/// ⚠️ 关键点：`action = #selector(NSText.copy(_:))` + **`target = nil`**
/// 是刻意的。`target = nil` 让 AppKit 沿**响应链**派发，于是：
/// - 焦点在便签 `NSTextView` → 走它自己的 `copy:`，系统剪贴板拿到选区文字；
/// - 焦点在搜索框 field editor → 同理；
/// - 焦点在分区窗口但**不在任何文本控件** → `NSApp.sendAction` 返回 false，
///   菜单项自动失效（灰色），按键继续交给 `installFileKeyRouting` 的文件快捷键。
/// 这正好和 `isTextInputActive` 的分工互补：那份代码决定「文件列表要不要接管」，
/// 而本菜单决定「文本控件的标准编辑能不能发生」。
///
/// ⚠️ `⌘C` / `⌘X` / `⌘V` **不要**在这里挂分区自己的文件复制 / 粘贴实现
/// （那在 `FileOperations.performFileAction` 里，由应用级 keyDown 监视器执行）。
/// 两者并存时会出现「有时复制文件、有时复制文字」取决于焦点，行为不可预期。
enum MainMenuBuilder {

    /// 装上主菜单。**必须在 `NSApplication.shared` 之后调用** ——
    /// top-level 阶段访问 `NSApp` 会 SIGILL（实测退出码 132）。
    static func install() {
        let mainMenu = NSMenu()

        // 应用菜单：DeskIsle 挂在状态栏（.accessory，无 Dock 图标），
        // 这里只放「关于」。**不要**放「退出」——那是状态栏菜单的职责，
        // 重复入口会让用户困惑。
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu(title: "DeskIsle 桌岛")
        appMenu.addItem(
            withTitle: "关于 DeskIsle 桌岛",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appItem.submenu = appMenu

        // 编辑菜单 —— 本文件存在的理由。
        //
        // `undo` / `redo` 用系统推荐的 "z" / "Z"：AppKit 会据此自动启用/禁用，
        // 无文本可撤时菜单项变灰，比自己判据可靠。
        //
        // ⚠️ 一律 `target = nil`：见文件头注释 —— 走响应链才是我们要的语义。
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "粘贴并匹配样式",
                         action: Selector(("pasteAsPlainText:")), keyEquivalent: "V")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu

        // ⚠️ 不要试图隐藏菜单栏：`NSMenu` **没有** `setVisibility` 这个 API（写出来编译不过）。
        // 也不需要 —— `.accessory` 激活策略下系统本来就不在屏幕顶栏画菜单栏，
        // `mainMenu` 此时只作为**快捷键派发表**存在，正是我们要的。
        // 将来若把策略改成 `.regular`（要占 Dock），菜单栏会显形，那时才需要处理。
    }
}