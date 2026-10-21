import AppKit
import Carbon        // kVK_* 键码常量：fileKeyName 按键码认特殊键（数值无规律，必须用符号）
import DeskIsleCore

// MARK: - 文件操作：键盘意图的执行层

/// PortalView 上报给 AppDelegate 的**操作上下文快照**。
///
/// 为什么不由 AppDelegate 直接持有选中态：选中是视图内部的 `@State`（每个分区一份，
/// 而且分区窗口是按需重建的）。复制一份快照给键盘用，是改动最小且不会两边打架的做法。
struct FileOpContext {
    /// 当前**可见**的条目路径（已按显示顺序排列，且已经过搜索过滤）。
    var visiblePaths: [String] = []
    /// 当前选中的路径。
    var selectedPaths: [String] = []
    /// 当前浏览目录 —— 粘贴的目标目录。
    var cwd: String = ""
}

extension AppDelegate {

    // MARK: 键盘路由

    /// 应用级 keyDown 监视器 —— 文件快捷键的**统一入口**。
    ///
    /// ⚠️ 为什么必须放在这一层，而不是只写在 `PartitionPanel.sendEvent` 里：
    /// 那个分支**只在分区是 key window 时**才会被调用。而分区是 `.nonactivatingPanel`，
    /// key window 的归属随时会被 AppKit 重新安排（实测 `NSApp.activate` 之后常常落到顶栏
    /// `TopBarPanel`，而不是用户刚点过的那个分区），一旦丢掉 key，`sendEvent` 一条 keyDown
    /// 都收不到 —— 用户看到的就是「分区里的快捷键一个都不起作用」。
    /// `addLocalMonitorForEvents` 监视的是**发给本应用**的事件，与窗口的 key 状态无关，
    /// 所以这一层才是稳的入口（`PartitionPanel.sendEvent` 里的分支因此废弃）。
    func installFileKeyRouting() {
        guard fileKeyMonitor == nil else { return }
        fileKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  // 模态（设置 / 搜索）开着时，键盘全归它，这里不要抢。
                  !self.isModalOpen,
                  let target = self.keyTargetPanel(for: event),
                  !self.isTextInputActive(in: target.partitionID),
                  self.handleFileKey(partitionID: target.partitionID, event: event)
            else { return event }
            return nil   // 已被文件列表消费，不再往下派发
        }
    }

    /// 这一下按键该由哪个分区来解读 —— 只认「用户正在操作的那个」。
    ///
    /// 事件携带的 window 是**真实接收它的窗口**；key window 次之（分区在非激活面板下
    /// 有时拿不到 key，靠这条兜住）。两条都空就说明按键不属于任何分区，
    /// 原样放行（`nil` → 交给 AppKit）。
    private func keyTargetPanel(for event: NSEvent) -> PartitionPanel? {
        if let w = event.window as? PartitionPanel { return w }
        if let k = NSApp.keyWindow as? PartitionPanel { return k }
        return nil
    }

    /// 该分区当前是否正在编辑文本（搜索框 / 便签），此时键盘必须让给输入控件。
    ///
    /// ⚠️ 为什么不能只看 `firstResponder`：`.nonactivatingPanel` 里 SwiftUI 的 TextField
    /// **不会因为点了别处而 resign**（这条注释的原作者在 `PartitionView` 里也踩过），
    /// 于是「用户点过搜索框之后」firstResponder 会一直是那个 field editor ——
    /// 判据恒为真，文件快捷键从此**永久失效**。所以主判据改用 SwiftUI `@FocusState`
    /// 明确上报的信号（`setPortalTextFocus`），firstResponder 只作为
    /// 便签这类**原生文本视图**的兜底。
    func isTextInputActive(in id: String) -> Bool {
        if portalTextFocus.contains(id) { return true }
        // ⚠️ portal 分区到此为止。它的文本输入（搜索框）有精确的 SwiftUI 焦点信号，
        // 而 firstResponder 在 nonactivatingPanel 下会**残留**（点别处也不 resign），
        // 一旦在这里接着看它，就会把「点过一次搜索框」之后的快捷键永久判成「正在打字」。
        // 便签这类**原生**文本视图没有信号可用，才走下面的 firstResponder 兜底。
        let type = config.str("type", of: id) ?? ""
        guard !type.isEmpty, type != "portal" else { return false }
        guard let panel = panel(for: id), panel.isKeyWindow else { return false }
        if let tv = panel.firstResponder as? NSTextView, tv.isEditable { return true }
        return false
    }

    /// SearchField 的焦点变化上报（`portalTextFocus` 的写入口之一）。
    func setPortalTextFocus(_ id: String, active: Bool) {
        if active { portalTextFocus.insert(id) } else { portalTextFocus.remove(id) }
    }

    /// 用户点了输入框以外的地方 —— 让搜索框**真正**放弃焦点。
    ///
    /// ⚠️ 为什么不能等 SwiftUI 自己来：分区是 `.nonactivatingPanel`，实测**点击文件列表
    /// 不会让搜索框的 `@FocusState` 变回 false**（AppKit 的 field editor 也不 resign）。
    /// 于是「点过一次搜索框」之后 `isTextInputActive` 恒为真，
    /// ⌘X / ⌘C / ⌘V / ⌘Z 从此**全部失效** —— 这正是用户报的现象。
    /// 所以焦点释放必须由**真实点击位置**驱动，而不是指望框架的通知。
    ///
    /// - Parameter locationInWindow: 点击落在窗口坐标系的位置（`NSEvent.locationInWindow`）。
    func releaseTextFocusIfNeeded(in panel: PartitionPanel, clickAt locationInWindow: NSPoint) {
        let id = panel.partitionID
        // 没在输入态就没什么要放的；点在输入框**里面**也要留住（用户还要打字）。
        guard portalTextFocus.contains(id) else { return }
        if let hit = panel.contentView?.hitTest(locationInWindow), Self.isTextInputView(hit) { return }

        portalTextFocus.remove(id)
        panel.makeFirstResponder(nil)
        // SwiftUI 侧也要同步，否则 `@FocusState` 仍是 true，
        // 下次再点搜索框不会触发 onChange，焦点信号就再也回不来了。
        NotificationCenter.default.post(name: .portalResignTextFocus, object: id)
    }

    /// 该视图（或其祖先）是不是文本输入控件。
    /// SwiftUI 的 TextField 底层是 `AppKitTextField`（`NSTextField` 子类），点上去命中的是它或其容器，
    /// 所以要沿父链找，不能只比较 hit 本身的类型。
    static func isTextInputView(_ view: NSView) -> Bool {
        var cur: NSView? = view
        while let v = cur {
            if v is NSTextField || v is NSTextView { return true }
            cur = v.superview
        }
        return false
    }

    // MARK: 上下文上报

    /// PortalView 在选区 / 可见集合 / 目录变化时调用。
    func syncPortalContext(_ id: String, visible: [String], selected: [String], cwd: String) {
        portalContexts[id] = FileOpContext(visiblePaths: visible, selectedPaths: selected, cwd: cwd)
    }

    func releasePortalContext(_ id: String) {
        portalContexts.removeValue(forKey: id)
    }

    // MARK: 键盘

    /// 把 AppKit 的按键事件翻成 `FileKeyShortcuts` 认识的键名。
    ///
    /// ⚠️ 特殊键**没有**可读字符（Escape / 方向键 / F2 的 `characters` 里是私有区码点），
    /// 必须按 keyCode 单独认；其余走 `charactersIgnoringModifiers` —— 它已经剥掉了
    /// ⌘ / ⇧，所以 ⌘A 拿到的是 `"a"` 而不是带修饰的组合。
    ///
    /// ⚠️⚠️ 键码**必须写注释标明出处**，因为它们是一串无规律的数字，且极易写错：
    /// - `kVK_F2 = 0x78 = 120`（**不是 96** —— 96 是 `kVK_F5`，历史上在此写成 96，
    ///   导致「按 F2 不触发重命名、按 F5 反而触发」；`FileKeyShortcuts.f2` 的语义是重命名）
    /// - 其余见 Carbon `Events.h`：`kVK_Delete = 117`（fn+⌫，Delete Forward）、
    ///   `kVK_Return = 36`、`kVK_Escape = 53`、`kVK_Space = 49`、`kVK_ForwardDelete = 51`（⌫）
    static func fileKeyName(from event: NSEvent) -> String {
        // `event.keyCode` 是 UInt16，而 Carbon 的 kVK_* 是 Int —— 这里统一折成 UInt32 传给键码表。
        let code = UInt32(event.keyCode)
        switch code {
        case UInt32(kVK_ForwardDelete): return "backspace"  // ⌫
        case UInt32(kVK_Delete):       return "delete"     // fn+⌫（Delete Forward）
        case UInt32(kVK_Escape):       return "escape"
        case UInt32(kVK_Return):       return "enter"      // ↩
        case UInt32(kVK_Space):        return "space"
        default:                       break
        }
        // F 键统一交给 FunctionKeys（键码表单一来源）。历史上这里写的是 `case 96: return "f2"`，
        // 而 96 是 kVK_F5、kVK_F2 其实是 120 ⇒ 「按 F2 不重命名、按 F5 才重命名」。
        if let fn = FunctionKeys.name(for: code) { return fn.lowercased() }
        guard let ch = event.charactersIgnoringModifiers, !ch.isEmpty else { return "" }
        return ch.lowercased()
    }

    /// 处理文件列表语境下的按键。
    ///
    /// - Returns: `true` = 这一下已被文件列表消费，**不要再交给 AppKit**。
    ///   ⚠️ 必须返回给调用方（`PartitionPanel.sendEvent`）去决定要不要 `super.sendEvent`，
    ///   否则会把便签编辑之类的正常按键一并吃掉。
    func handleFileKey(partitionID: String, event: NSEvent) -> Bool {
        // 只有 portal 分区才处理文件相关快捷键
        let type = config.str("type", of: partitionID) ?? ""
        guard type.isEmpty || type == "portal" else { return false }

        let ctx = portalContexts[partitionID] ?? FileOpContext(visiblePaths: [], selectedPaths: [], cwd: "")

        let name = Self.fileKeyName(from: event)
        let key = FileKeyShortcuts.key(fromName: name)

        let flags = event.modifierFlags
        let hasCmd = flags.contains(.command)
        let hasOpt = flags.contains(.option)
        let hasCtrl = flags.contains(.control)
        let hasShift = flags.contains(.shift)

        // 1. 标准文件快捷键（⌘A、⌘C、⌘X、⌘V、⌘⌫、Escape、Space、F2、↩）
        if key != .other {
            let action = FileKeyShortcuts.action(
                for: key,
                primary: hasCmd,
                shift: hasShift,
                selectedCount: ctx.selectedPaths.count,
                layout: .mac
            )
            // 特殊增强：如果当前未选中任何文件，按空格直接自动选中并预览第一个可见项目
            if key == .space && action == .none && !hasCmd && !hasOpt && !hasCtrl {
                if let first = ctx.visiblePaths.first {
                    NotificationCenter.default.post(
                        name: .portalQuickSelect,
                        object: partitionID,
                        userInfo: ["exactPath": first]
                    )
                    previewSelection(first, in: partitionID)
                    return true
                }
            }
            if action != .none {
                performFileAction(action, in: partitionID, context: ctx)
                return true
            }
        }

        // 2. 映射文件夹深度键盘流（返回上一级目录）：
        //    - ⌘↑（macOS 访达标准前往上级目录）
        //    - ⌥↑ / Alt+Up（跨平台通用）
        //    - ⌘[（macOS 访达标准后退）
        //    - Backspace / ⌫（非输入框状态下裸按退格，极度方便且无误删风险）
        let isGoUp: Bool = {
            if event.keyCode == 126 { // Up arrow
                return (hasCmd && !hasOpt && !hasCtrl) || (hasOpt && !hasCmd && !hasCtrl)
            }
            if hasCmd && !hasOpt && !hasCtrl && (event.keyCode == 33 || event.charactersIgnoringModifiers == "[") {
                return true
            }
            if !hasCmd && !hasOpt && !hasCtrl && !hasShift && event.keyCode == 51 { // ⌫
                return true
            }
            return false
        }()

        if isGoUp {
            NotificationCenter.default.post(name: .portalNavigateParent, object: partitionID)
            return true
        }

        // 3. 映射文件夹深度键盘流（下钻进入选中的文件夹 / 打开选中文件）：
        //    - ⌘↓（macOS 访达标准打开所选项目）
        //    - ⌘O（macOS 访达标准打开）
        //    - ⌘]（macOS 访达标准前进）
        //    - ⌘↩（Command+Enter）
        let isEnterSelected: Bool = {
            if hasCmd && !hasOpt && !hasCtrl {
                if event.keyCode == 125 { // Down arrow
                    return true
                }
                if event.keyCode == 31 || event.charactersIgnoringModifiers?.lowercased() == "o" { // ⌘O
                    return true
                }
                if event.keyCode == 30 || event.charactersIgnoringModifiers == "]" { // ⌘]
                    return true
                }
                if event.keyCode == 36 { // ⌘↩
                    return true
                }
            }
            return false
        }()

        if isEnterSelected {
            NotificationCenter.default.post(name: .portalEnterSelected, object: partitionID)
            return true
        }

        // 4. 方向键导航（上下左右），支持 ⇧ 连选扩选
        if !hasCmd && !hasCtrl && !hasOpt {
            let dir: String? = {
                switch event.keyCode {
                case 126: return "up"
                case 125: return "down"
                case 123: return "left"
                case 124: return "right"
                default:  return nil
                }
            }()
            if let direction = dir {
                NotificationCenter.default.post(
                    name: .portalArrowNavigate,
                    object: partitionID,
                    userInfo: ["direction": direction, "shift": hasShift]
                )
                return true
            }
        }

        // 5. 首字母/多字母即时跳转（Type-to-Select，对齐访达）
        if !hasCmd && !hasCtrl && !hasOpt,
           event.keyCode != 49,
           let chars = event.charactersIgnoringModifiers,
           chars.count == 1,
           let scalar = chars.unicodeScalars.first,
           !CharacterSet.controlCharacters.contains(scalar) {
            NotificationCenter.default.post(
                name: .portalQuickSelect,
                object: partitionID,
                userInfo: ["char": chars]
            )
            return true
        }

        return false
    }

    // MARK: 执行

    func performFileAction(_ action: FileKeyAction, in id: String, context: FileOpContext) {
        switch action {
        case .none:
            break

        case .selectAll:
            // 选中态活在视图里，这里只能「请它去全选」。
            NotificationCenter.default.post(name: .portalSelectAll, object: id)

        case .clearSelection:
            NotificationCenter.default.post(name: .portalClearSelection, object: id)
            if QuickPreview.shared.isShowing {
                QuickPreview.shared.close()
            }

        case .trash:
            trashPaths(context.selectedPaths, in: id, context: context)

        case .rename:
            NotificationCenter.default.post(name: .portalRequestRename, object: id)

        case .preview:
            guard let path = context.selectedPaths.first else { break }
            previewSelection(path, in: id)

        case .copy:
            FileClipboard.shared.copy(context.selectedPaths)
            reportClipboard("已复制", count: context.selectedPaths.count, icon: "doc.on.doc")

        case .cut:
            FileClipboard.shared.cut(context.selectedPaths)
            reportClipboard("已剪切", count: context.selectedPaths.count, icon: "scissors")

        case .paste:
            pasteClipboard(into: context.cwd, in: id)

        case .undo:
            undoLastFileOperation(in: id)
        }
    }

    /// 空格快速查看：调用原生快速预览（图片/PDF/代码文本/文件夹原生浮层，再次空格或 Esc 关闭）。
    private func previewSelection(_ path: String, in id: String? = nil) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        QuickPreview.shared.toggle(path, partitionID: id)
    }

    // MARK: 废纸篓

    func trashPaths(_ paths: [String], in id: String, context: FileOpContext? = nil) {
        guard !paths.isEmpty else { return }
        var failed: [String] = []
        var moved = 0
        var trashedPairs: [(original: String, trashed: String)] = []
        for path in paths {
            let before = FileManager.default.fileExists(atPath: path)
            if let trashedPath = trashFileResultingPath(path), before {
                moved += 1
                trashedPairs.append((original: path, trashed: trashedPath))
            } else {
                failed.append((path as NSString).lastPathComponent)
            }
        }
        if moved > 0 {
            // 记下「哪一锅盘子饺落在废纸篓的哪个名字上」—— ⌘Z 全靠它捡回来。
            FileUndoStack.shared.push(.restoreFromTrash(pairs: trashedPairs), verb: "移到废纸篓")
        }
        NotificationCenter.default.post(name: .portalFolderChanged, object: id)
        if moved > 0 {
            Toast.shared.show(moved == 1 ? "已移到废纸篓" : "已移到废纸篓（\(moved) 项）",
                              icon: "trash")
        }
        if !failed.isEmpty {
            Toast.shared.show("\(failed.count) 项没能移到废纸篓",
                              detail: failed.prefix(2).joined(separator: "、"),
                              icon: "exclamationmark.triangle.fill")
        }
    }

    // MARK: 剪贴板粘贴

    /// 把内部剪贴板里的文件贴到 `directory`。
    ///
    /// 三条规矩与 `moveFilesIntoPortal` 完全一致（那里踩过的坑这里一样会踩）：
    /// 1. **绝不覆盖** —— 同名就自动加「 2」后缀；
    /// 2. **不能把文件夹贴进自己的子孙目录**；
    /// 3. 剪切时**同目录 = no-op**，不然会出现「剪切→粘贴回原处→报失败」的怪象。
    @discardableResult
    func pasteClipboard(into directory: String, in id: String) -> (done: Int, failed: [String]) {
        let clip = FileClipboard.shared
        guard !directory.isEmpty else { return (0, []) }

        // 内部剪贴板空着时退到**系统剪贴板**：在访达里 ⌘C 再回来贴是很自然的动作，
        // 而原来的实现遇到这种情况会**静默返回** —— 用户只看到「⌘V 没反应」，
        // 于是得出「粘贴快捷键坏了」的结论。要么真能贴，要么把话说清楚。
        let fallbackPaths = clip.isEmpty ? systemPasteboardFilePaths() : []
        let paths = clip.isEmpty ? fallbackPaths : clip.paths
        guard !paths.isEmpty else {
            Toast.shared.show("没有可粘贴的内容",
                              detail: "先在 DeskIsle 里 ⌘C / ⌘X，或在访达里复制文件",
                              icon: "doc.on.clipboard")
            return (0, [])
        }

        // 复用移入的同名冲突三选一逻辑（保留两者 / 停止 / 替换）。
        // 剪切 = 移动，复制 = 复制；「停止」会整体取消且**不清空**剪切板（让用户重试）。
        let (done, failed, decision, pairs) = relocateFiles(paths, into: directory, move: clip.isCut)

        if done > 0 {
            // 剪切挪进来的 = 移回原处；复制出来的 = 删掉这些副本。
            if clip.isCut {
                FileUndoStack.shared.push(.moveBack(pairs: pairs), verb: "粘贴（移动）")
            } else {
                FileUndoStack.shared.push(.removeCopies(pairs.map(\.to)), verb: "粘贴（复制）")
            }
            NotificationCenter.default.post(name: .portalFolderChanged, object: id)
            Toast.shared.show(clip.isCut ? "已粘贴（移动 \(done) 项）" : "已粘贴（复制 \(done) 项）",
                              detail: (directory as NSString).lastPathComponent,
                              icon: "doc.on.clipboard")
        }
        if !failed.isEmpty {
            Toast.shared.show("\(failed.count) 项没能粘贴",
                              detail: failed.prefix(2).joined(separator: "、"),
                              icon: "exclamationmark.triangle.fill")
        }
        // ⚠️ 剪切是一次性的：源已经不在原处了，留着再贴一次只会报错。
        // 但「停止」= 整体取消，保留剪切板让用户换个动作重试。
        if clip.isCut && decision != .stop { clip.clear() }
        return (done, failed)
    }

    /// 系统剪贴板里的文件路径（访达复制的结果）。
    private func systemPasteboardFilePaths() -> [String] {
        guard let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else {
            return []
        }
        // 只认本地存在的文件：网页 URL / 纯文本不该在这里被当成「能贴的文件」。
        return urls.map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
    }

    private func reportClipboard(_ verb: String, count: Int, icon: String) {
        Toast.shared.show(count == 1 ? "\(verb) 1 项" : "\(verb) \(count) 项",
                          detail: FileClipboard.shared.hint,
                          icon: icon)
    }

    // MARK: 菜单入口（与键盘走同一个剪贴板）

    func copyToClipboard(_ paths: [String]) {
        FileClipboard.shared.copy(paths)
        reportClipboard("已复制", count: paths.count, icon: "doc.on.doc")
    }

    /// 把路径写成**纯文本**放到系统剪贴板，供终端、便签、浏览器地址栏粘贴。
    ///
    /// 多项用换行隔开。刻意不碰 `FileClipboard`：那一份记的是「拷贝 / 剪切文件」，
    /// 复制路径不该把上一次的文件剪切清掉，也不该让分区里的 ⌘V 把路径当文件贴进来。
    func copyPathsAsText(_ paths: [String]) {
        let lines = paths.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(lines.joined(separator: "\n"), forType: .string)
        let detail = lines.count == 1 ? lines[0] : "\(lines.count) 个路径"
        Toast.shared.show("已复制路径", detail: detail, icon: "link")
    }

    func cutToClipboard(_ paths: [String]) {
        FileClipboard.shared.cut(paths)
        reportClipboard("已剪切", count: paths.count, icon: "scissors")
    }

    /// 多选「在访达中显示」：一次调用选中全部（逐个调用会把访达来回激活 N 次）。
    func revealInFinderAll(_ paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // MARK: - 原生显示简介（Get Info）

    /// 打开系统原生的「显示简介」信息面板（⌘I）。
    func showGetInfo(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        let targetStatements = paths.map { p in
            "open information window of (POSIX file \"\(p.replacingOccurrences(of: "\"", with: "\\\""))\" as alias)"
        }.joined(separator: "\n")
        let script = """
        tell application "Finder"
            activate
            \(targetStatements)
        end tell
        """
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
        }
    }

    // MARK: - 原生压缩（Compress）

    /// 将选中的文件/文件夹压缩归档为 .zip 文件（对齐访达压缩功能）。
    func compressPaths(_ paths: [String], in partitionId: String) {
        guard !paths.isEmpty else { return }
        let parentDir = (paths[0] as NSString).deletingLastPathComponent
        let baseName: String
        if paths.count == 1 {
            let last = (paths[0] as NSString).lastPathComponent
            let ext = (paths[0] as NSString).pathExtension
            baseName = ext.isEmpty ? last : (last as NSString).deletingPathExtension
        } else {
            baseName = "归档"
        }

        var candidate = (parentDir as NSString).appendingPathComponent("\(baseName).zip")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate) {
            candidate = (parentDir as NSString).appendingPathComponent("\(baseName) \(counter).zip")
            counter += 1
        }
        let destZipPath = candidate
        let destName = (destZipPath as NSString).lastPathComponent

        Toast.shared.show("正在压缩...", detail: destName, icon: "archivebox")

        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            if paths.count == 1 {
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                proc.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", paths[0], destZipPath]
            } else {
                proc.currentDirectoryURL = URL(fileURLWithPath: parentDir)
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                let relNames = paths.map { ($0 as NSString).lastPathComponent }
                proc.arguments = ["-r", "-q", destZipPath] + relNames
            }

            do {
                try proc.run()
                proc.waitUntilExit()
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .portalFolderChanged, object: partitionId)
                    Toast.shared.show("已生成压缩文件", detail: destName, icon: "archivebox.fill")
                }
            } catch {
                DispatchQueue.main.async {
                    Toast.shared.show("压缩失败", icon: "exclamationmark.triangle.fill")
                }
            }
        }
    }

    // MARK: - 原生解压（Unarchive）

    /// 将归档文件解压缩到当前目录下（支持 zip、tar、gz、tgz、bz2、tbz2、xz、7z 等）。
    /// 包含防止散包逻辑：若压缩包内包含多个根目录条目，则自动创建同名文件夹解压，避免文件散落在当前目录。
    func unarchivePath(_ path: String, in partitionId: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let parentDir = (path as NSString).deletingLastPathComponent
        let fileName = (path as NSString).lastPathComponent
        let ext = (path as NSString).pathExtension.lowercased()

        Toast.shared.show("正在解压...", detail: fileName, icon: "archivebox")

        DispatchQueue.global(qos: .userInitiated).async {
            var stem = (fileName as NSString).deletingPathExtension
            if stem.lowercased().hasSuffix(".tar") {
                stem = (stem as NSString).deletingPathExtension
            }

            var destDir = parentDir
            // 检测压缩包内的顶层条目数（防止散包污染当前目录）
            let checkProc = Process()
            checkProc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            checkProc.arguments = ["-tf", path]
            let pipe = Pipe()
            checkProc.standardOutput = pipe
            checkProc.standardError = Pipe()
            if (try? checkProc.run()) != nil {
                checkProc.waitUntilExit()
                if checkProc.terminationStatus == 0 {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    if let output = String(data: data, encoding: .utf8) {
                        var roots = Set<String>()
                        for line in output.components(separatedBy: "\n") {
                            var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                            if trimmed.hasPrefix("./") { trimmed.removeFirst(2) }
                            if let first = trimmed.split(separator: "/").first, !first.isEmpty {
                                roots.insert(String(first))
                            }
                        }
                        if roots.count > 1 {
                            // 多个根条目：在同级创建专属文件夹解压
                            var candidate = (parentDir as NSString).appendingPathComponent(stem)
                            var counter = 2
                            while FileManager.default.fileExists(atPath: candidate) {
                                candidate = (parentDir as NSString).appendingPathComponent("\(stem) \(counter)")
                                counter += 1
                            }
                            try? FileManager.default.createDirectory(atPath: candidate, withIntermediateDirectories: true)
                            destDir = candidate
                        }
                    }
                }
            }

            let proc = Process()
            if ext == "zip" {
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                proc.arguments = ["-x", "-k", "--sequesterRsrc", path, destDir]
            } else {
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                proc.arguments = ["-xf", path, "-C", destDir]
            }

            do {
                try proc.run()
                proc.waitUntilExit()
                let success = proc.terminationStatus == 0
                DispatchQueue.main.async {
                    if success {
                        NotificationCenter.default.post(name: .portalFolderChanged, object: partitionId)
                        Toast.shared.show("解压完成", detail: fileName, icon: "archivebox.fill")
                    } else {
                        Toast.shared.show("解压失败", detail: "“\(fileName)”可能损坏或格式不受支持", icon: "exclamationmark.triangle.fill", emphasized: true)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    Toast.shared.show("解压失败", detail: "“\(fileName)”可能损坏或格式不受支持", icon: "exclamationmark.triangle.fill", emphasized: true)
                }
            }
        }
    }

    // MARK: - 制作副本（Duplicate，访达快捷键 ⌘D）

    /// 在当前同级目录下直接生成一份副本（如「xxx 副本.ext」）。
    func duplicatePaths(_ paths: [String], in partitionId: String) {
        guard !paths.isEmpty else { return }
        var done = 0
        var created: [String] = []
        for path in paths {
            let parent = (path as NSString).deletingLastPathComponent
            let last = (path as NSString).lastPathComponent
            let ext = (path as NSString).pathExtension
            let stem = ext.isEmpty ? last : (last as NSString).deletingPathExtension

            func makeName(_ counter: Int) -> String {
                let tag = counter == 1 ? "副本" : "副本 \(counter)"
                return ext.isEmpty ? "\(stem) \(tag)" : "\(stem) \(tag).\(ext)"
            }

            var counter = 1
            var dest = (parent as NSString).appendingPathComponent(makeName(counter))
            while FileManager.default.fileExists(atPath: dest) {
                counter += 1
                dest = (parent as NSString).appendingPathComponent(makeName(counter))
            }

            do {
                try FileManager.default.copyItem(atPath: path, toPath: dest)
                done += 1
                created.append(dest)
            } catch {
                NSLog("[DeskIsle] 复制副本失败: %@", error.localizedDescription)
            }
        }

        if done > 0 {
            FileUndoStack.shared.push(.removeCreated(created), verb: "制作副本")
            NotificationCenter.default.post(name: .portalFolderChanged, object: partitionId)
            Toast.shared.show(done == 1 ? "已创建副本" : "已创建 \(done) 项副本", icon: "plus.square.on.square")
        }
    }

    // MARK: - 快速查看

    /// 快速查看（空格预览）。
    func quickLook(_ path: String) {
        previewSelection(path)
    }
}
