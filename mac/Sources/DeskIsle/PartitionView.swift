import SwiftUI
import AppKit
import DeskIsleCore
import DeskIsleLayout   // Look / DeskFont / PartitionLook：字号与外观三端同源常量

/// 分区容器：圆角毛玻璃 + 标题栏（锁定/置顶/自适应/折叠/设置/删除）+ 按类型分发内容。
struct PartitionView: View {
    @ObservedObject var config: Config
    let id: String
    /// 折叠分区悬停时临时展开（hoverPeekCollapsed），不改 config.isCollapsed。
    @State private var hoverExpanded = false
    @State private var isHeaderDropTargeted = false
    @State private var springLoadWork: DispatchWorkItem?
    /// 双击标题进入行内重命名。
    @State private var editingTitle = false
    @State private var titleDraft = ""
    @FocusState private var titleFieldFocused: Bool

    // ⚠️ 圆角是**分区级可配项**（`style.borderRadius`），缺省回到 `Look.cornerRadius`。
    // 必须每次从 config 读：用户在设置里拖滑杆时靠 `config.revision` 触发重绘，
    // 若这里写死成 let，改完样式必须重建窗口才看得到。
    private var corner: CGFloat {
        PartitionLook.clamped(cornerRadius: CGFloat(config.style("borderRadius", of: id,
                                                                 default: Look.cornerRadius)))
    }
    /// 背景遮罩色 + 不透明度（缺省 = 黑色 + 跟随全局不透明度设置）。
    private var bgColor: Color {
        Color(hex: config.styleStr("bgColor", of: id, default: PartitionLook.defaultBgColor))
    }
    private var bgOpacity: Double {
        PartitionLook.clamped(bgOpacity: config.style("bgOpacity", of: id,
                                                      default: config.partitionBgOpacity))
    }
    /// 模糊强度 → SwiftUI Material 档位。
    /// mac 的系统材质**没有连续的像素半径**可调，只能按档位取（`PartitionLook.blurTier`）；
    /// 三端数值同源、解释各异，详见 `PartitionLook` 的文档注释。
    private var blurAmount: CGFloat {
        PartitionLook.clamped(blur: CGFloat(config.style("blurAmount", of: id,
                                                         default: PartitionLook.defaultBlurAmount)))
    }
    private var blurMaterial: Material? {
        switch PartitionLook.blurTier(for: blurAmount) {
        case .none: return nil      // 完全不要毛玻璃（用户想要纯色卡片）
        case .ultraThin: return .ultraThinMaterial
        case .thin: return .thinMaterial
        case .regular: return .regularMaterial
        }
    }
    /// 正文色：空串 = 跟随系统（`Color.primary`）。
    private var contentTextColor: Color? {
        let s = config.styleStr("textColor", of: id, default: PartitionLook.defaultContentTextColor)
        return s.isEmpty ? nil : Color(hex: s)
    }

    private var isCollapsed: Bool { config.bool("isCollapsed", of: id) }
    private var hoverPeekEnabled: Bool {
        (config.settings["hoverPeekCollapsed"] as? Bool) ?? true
    }
    private var actuallyCollapsed: Bool { isCollapsed && !hoverExpanded }
    private var locked: Bool { AppDelegate.shared?.isLocked(id) ?? false }
    private var type: String { config.str("type", of: id) ?? "" }
    private var headerColor: Color { Color(hex: config.styleStr("headerColor", of: id, default: "#38bdf8")) }

    var body: some View {
        VStack(spacing: 0) {
            header
                .onDrop(of: [.fileURL], isTargeted: $isHeaderDropTargeted) { providers in
                    loadDroppedPaths(providers) { paths in
                        handleHeaderDrop(paths)
                    }
                    return true
                }
                .onChange(of: isHeaderDropTargeted) { targeted in
                    springLoadWork?.cancel()
                    springLoadWork = nil
                    if targeted {
                        guard isCollapsed else { return }
                        let w = DispatchWorkItem {
                            hoverExpanded = true
                            AppDelegate.shared?.hoverPeek(id, expanded: true)
                        }
                        springLoadWork = w
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: w)
                    } else {
                        if hoverExpanded {
                            hoverExpanded = false
                            AppDelegate.shared?.hoverPeek(id, expanded: false)
                        }
                    }
                }
            if !actuallyCollapsed {
                Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
                content
            }
        }
        // alignment: .top —— 折叠时 VStack 内容（仅 header）必须贴顶；
        // 充满宿主窗口，使窗口拖拽与缩放时毛玻璃背景、边框和内容实时无缝跟随。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // 半透明毛玻璃背景：系统模糊 + 可调淡遮罩。
        // 遮罩不透明度来自「全局设置 → 分区背景不透明度」（旧配置无此键时按 0.10，与历史值一致），
        // 拖动滑条时 config.revision 变化即可实时重绘（无需重建窗口）。
        // 背景一层：用户可选的背景色 + 不透明度（缺省 = 黑色 + 跟随全局不透明度，与历史一致）。
        // 二阶背景：毛玻璃材质。**条件式修饰禁止写在 ViewBuilder 里**（会派生不同类型），
        // 用 AnyView 抹平 —— 这里是唯一可接受 AnyView 的场景。
        .background(bgColor.opacity(bgOpacity),
                    in: RoundedRectangle(cornerRadius: corner, style: .continuous))
        .background {
            // 条件式修饰用 Group 抹平类型（比 AnyView 干净：不丢布局信息）。
            Group {
                if let m = blurMaterial {
                    RoundedRectangle(cornerRadius: corner, style: .continuous).fill(m)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        // 正文色（空串 = 跟随系统）：整体作为环境色下传给内容，内容里显式写过颜色的地方不被覆盖 ——
        // 这是刻意的：分区内部的强调色/警告色不应被背景配色连带改掉。
        .foregroundStyle(contentTextColor ?? Color.primary)
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
        )
        .onHover { hovering in
            guard isCollapsed, hoverPeekEnabled else { return }
            if hovering != hoverExpanded {
                hoverExpanded = hovering
                AppDelegate.shared?.hoverPeek(id, expanded: hovering)
            }
        }
        .onChange(of: isCollapsed) { _ in hoverExpanded = false }
        // 失焦保存：nonactivatingPanel 下 TextField 点击窗口外不一定 resign first responder，
        // @FocusState 的失焦不可靠，改用「窗口 resign key」信号兜底（点击其他分区/应用/桌面时触发）。
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            commitTitle()
        }
    }

    // MARK: - 标题栏

    private var defaultTypeIcon: String {
        switch type {
        case "portal": return "📁 "
        case "todo": return "✅ "
        case "notes": return "📝 "
        default: return "📁 "
        }
    }

    /// 从当前标题中分离出 icon 和纯文本名称
    private var titleParts: (icon: String, text: String) {
        let full = config.str("title", of: id) ?? type
        for emoji in ["📁 ", "✅ ", "📝 ", "📥 ", "📁", "✅", "📝", "📥"] {
            if full.hasPrefix(emoji) {
                let rest = String(full.dropFirst(emoji.count)).trimmingCharacters(in: .whitespaces)
                let iconWithSpace = emoji.hasSuffix(" ") ? emoji : emoji + " "
                return (iconWithSpace, rest)
            }
        }
        return (defaultTypeIcon, full)
    }

    private var header: some View {
        // spacing 5（原 6）：标题栏右侧按钮已增至 6 个，
        // 每档省 1pt 就能给中文标题多让出约 8pt —— 正好是一个汉字的三分之一。
        HStack(spacing: 5) {
            if editingTitle {
                HStack(spacing: 4) {
                    Text(titleParts.icon)
                        .font(DeskFont.glyph)
                        .lineLimit(1)
                    TextField("分区名称", text: Binding(
                        get: { titleDraft },
                        set: { titleDraft = String($0.prefix(10)) }
                    ))
                    .textFieldStyle(.plain)
                    .font(DeskFont.header)
                    .foregroundStyle(headerColor)
                    .focused($titleFieldFocused)
                    .onSubmit { commitTitle() }
                    .onExitCommand { cancelTitle() }
                    .onChange(of: titleFieldFocused) { f in if !f { commitTitle() } }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.16)))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(headerColor.opacity(0.55), lineWidth: 1))
                .frame(width: 172)   // 10 个汉字（12.5pt ≈ 125pt）+ emoji(20pt) + padding(24pt)
                .fixedSize(horizontal: true, vertical: false)
            } else {
                // 单行 + 尾部截断：标题栏高度固定 44pt，一旦换行会把标题栏撑高、
                // 与折叠态（仅 44pt）和 autoFitHeight 的 headerHeight 假设打架。
                Text(config.str("title", of: id) ?? type)
                    .font(DeskFont.header)
                    .foregroundStyle(headerColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { beginTitle() }
            }

            if let badge = config.badgeInfo(of: id) {
                Text(badge.text)
                    .font(DeskFont.badge)
                    .foregroundStyle(badge.isAllDone ? Color.green : .secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(badge.isAllDone ? Color.green.opacity(0.18) : Color.primary.opacity(0.10)))
            }

            Color.clear
                .frame(maxWidth: .infinity, maxHeight: 44)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    if AppDelegate.shared?.blockedByLock(id, action: "折叠") != true {
                        AppDelegate.shared?.toggleCollapse(id)
                    }
                }

            // 按钮从左到右：锁定 · 置顶 · 自适应 · 折叠 · **设置** · 删除。
            // 「锁定」放在最左：它是**唯一能在锁定态下操作**的按钮（解锁出口），
            // 必须固定在最容易被摸到的位置 —— 否则图标一压暗，用户会找不到怎么解。
            // 「设置」放在删除左侧第一位：**破坏性操作（删除）永远单独待在最右端**，
            // 与它相邻的是入口型按钮而非另一个动作按钮 —— 手顺滑到最右时不会误触删除。
            //
            // 锁定态：除「解锁」外的功能图标一律**压暗 + 提示语换成锁定原因**。
            // 压暗只是「先告诉你点不动」；用户真点了仍会收到一句瞬时提示
            // （拦截在 AppDelegate.blockedByLock）—— 只压暗不给回应会让人以为程序卡住。
            let pinned = config.bool("isAlwaysOnTop", of: id)
            headerButton(locked ? "lock.fill" : "lock.open",
                         locked ? "解锁该分区" : "锁定该分区",
                         tint: locked ? .orange : .secondary) {
                // 锁定按钮自身**永不压暗**：它是锁定时唯一还有效的出口
                AppDelegate.shared?.togglePartitionLock(id)
            }
            headerButton(pinned ? "pin.fill" : "pin",
                         locked ? lockedTooltip(pinned ? "取消置顶" : "置顶")
                                : (pinned ? "取消置顶" : "置顶"),
                         tint: pinned ? .orange : .secondary, dimmed: locked) {
                AppDelegate.shared?.setPinned(id, !pinned)
            }
            headerButton("arrow.up.and.down.and.arrow.left.and.right",
                         locked ? lockedTooltip("自适应宽高") : "自适应宽高",
                         dimmed: locked) {
                // 显式点「自适应宽高」→ 折叠中的分区顺势展开（用户想看内容）
                AppDelegate.shared?.autoFitHeight(id, expandIfCollapsed: true)
            }
            headerButton(isCollapsed ? "chevron.down" : "chevron.up",
                         locked ? lockedTooltip(isCollapsed ? "展开" : "折叠")
                                : (isCollapsed ? "展开分区" : "折叠分区"),
                         dimmed: locked) {
                AppDelegate.shared?.toggleCollapse(id)
            }
            headerButton("gearshape",
                         locked ? lockedTooltip("打开分区设置") : "分区设置",
                         dimmed: locked) {
                AppDelegate.shared?.openPartitionSettings(id)
            }
            // 删除图标用 trash（原为 xmark）—— 与批量操作条的删除图标统一，
            // 「✕」在 macOS 上更多表示「关闭」，而这里是解绑分区，语义要明确。
            headerButton("trash",
                         locked ? lockedTooltip("删除") : "删除分区",
                         dimmed: locked) {
                AppDelegate.shared?.confirmRemovePartition(id)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)   // 固定标题栏高度，内容垂直居中（与折叠高度/autoFitHeight 的 header=44 一致）
    }

    // MARK: - 标题行内重命名

    private func beginTitle() {
        // 重命名同样属于「改分区自己」，锁定时在双击这一步就拦下 ——
        // 让用户改完名字再拒绝保存，比一开始就说清楚糟得多。
        if AppDelegate.shared?.blockedByLock(id, action: "重命名") == true { return }
        titleDraft = titleParts.text
        editingTitle = true
        // 视图切换后 TextField 才挂载，焦点需在下一帧设置
        DispatchQueue.main.async { titleFieldFocused = true }
    }

    private func commitTitle() {
        guard editingTitle else { return }
        editingTitle = false
        let t = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = t.isEmpty ? titleParts.text : t
        let newTitle = titleParts.icon + String(body.prefix(10))
        if newTitle != (config.str("title", of: id) ?? "") {
            AppDelegate.shared?.updatePartition(id, key: "title", value: newTitle)
        }
    }

    private func cancelTitle() {
        editingTitle = false
    }

    private func handleHeaderDrop(_ paths: [String]) {
        springLoadWork?.cancel()
        springLoadWork = nil
        if hoverExpanded {
            hoverExpanded = false
            AppDelegate.shared?.hoverPeek(id, expanded: false)
        }
        guard !paths.isEmpty else { return }
        switch type {
        case "portal":
            let dest = config.str("folderPath", of: id) ?? ""
            guard !dest.isEmpty else { return }
            FileDrag.handledInsideApp = true
            let r = AppDelegate.shared?.moveFilesIntoPortal(id, paths: paths, directory: dest)
            if let r = r, r.moved > 0 {
                Toast.shared.show("已移入 \(r.moved) 个文件", icon: "tray.and.arrow.down.fill")
            }
        case "notes":
            let existing = config.str("noteContent", of: id) ?? ""
            let addition = paths.joined(separator: "\n")
            let newText = existing.isEmpty ? addition : existing + "\n" + addition
            AppDelegate.shared?.updateNote(id, newText)
        case "todo":
            for p in paths {
                let name = (p as NSString).lastPathComponent
                AppDelegate.shared?.addTodo(id, text: name)
            }
        default:
            break
        }
    }

    /// 标题栏功能按钮。
    ///
    /// `tint` 必须**显式传入**，不能靠调用点在外层链一个 `.foregroundStyle(...)` ——
    /// 内层 Image 上的 `.foregroundStyle(.secondary)` 会盖住外层传下来的环境样式，
    /// 于是「置顶/锁定变橙」这条一直没生效过（图标恒为灰色）。改成参数后一并修好。
    ///
    /// `dimmed`：锁定时压暗到 40%，配合调用点换掉的提示语，
    /// 让人在**点之前**就知道这个按钮现在不会生效。
    private func headerButton(_ icon: String, _ help: String,
                              tint: Color = .secondary,
                              dimmed: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(DeskFont.headerIcon)
                .foregroundStyle(tint)
                .opacity(dimmed ? 0.4 : 1)
                // 固定 14×14：标题栏按钮不能在窄分区里被压缩成 0 宽 —— 那会让「折叠/删除」
                // 变成点不到的隐形按钮，比图标挤在一起更糟。
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(help)
    }

    /// 锁定态下的悬浮提示。与点击后弹出的瞬时提示用同一套措辞，
    /// 免得「悬停看到一套、点了看到另一套」。
    private func lockedTooltip(_ action: String) -> String { "已锁定，无法\(action)" }

    // MARK: - 内容分发

    @ViewBuilder
    private var content: some View {
        switch type {
        case "portal":
            PortalView(folderPath: config.str("folderPath", of: id) ?? "",
                       viewMode: config.str("viewMode", of: id) ?? "grid",
                       id: id,
                       sortBy: config.str("sortBy", of: id) ?? "name",
                       sortOrder: config.str("sortOrder", of: id) ?? "asc")
        case "notes":
            NotesView(id: id, initialText: config.str("noteContent", of: id) ?? "")
        case "todo":
            TodoView(id: id, config: config)
        default:
            Text(type)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - 拖出载体

/// 构造「把文件从分区拖到别处」的拖放载体（Finder / 邮件 / 聊天窗口等）。
///
/// 用 `NSItemProvider(contentsOf:)` 携带**文件 URL**而不是纯文本 ——
/// 接收方才能拿到真实文件并执行复制/移动；传文本的话对方只会得到一串路径。
/// 目录同样支持（拖到访达可复制整个文件夹）。
///
/// ⚠️ 放在文件作用域：portal 分区各处共用同一份实现，
/// 避免各处各写一份导致行为不一致（例如某处漏设 `suggestedName`）。
func fileDragProvider(_ path: String) -> NSItemProvider {
    let url = URL(fileURLWithPath: path)
    guard let provider = NSItemProvider(contentsOf: url) else { return NSItemProvider() }
    provider.suggestedName = url.lastPathComponent
    return provider
}

/// 从 drop 进来的 provider 里取出文件路径。
///
/// ⚠️ `loadItem` 是异步的，且**回调不在主线程** —— 所有调用方拿到路径后都要切回主线程再动 UI
/// （这里统一在 `notify` 里切回 `.main`，调用方不必各自记一次）。
///
/// 一个 provider 可能同时给 `Data`（URL 的 dataRepresentation）或 `URL` 两种形态，
/// 两种都要认：不同来源（访达 / 另一个分区 / 浏览器下载）给的不一样。
func loadDroppedPaths(_ providers: [NSItemProvider], completion: @escaping ([String]) -> Void) {
    var paths: [String] = []
    let group = DispatchGroup()
    let lock = NSLock()
    for provider in providers {
        group.enter()
        provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
            var path: String?
            if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                path = url.path
            } else if let url = item as? URL {
                path = url.path
            }
            if let p = path {
                lock.lock(); paths.append(p); lock.unlock()
            }
            group.leave()
        }
    }
    group.notify(queue: .main) { completion(paths) }
}

// MARK: - 通用搜索框

private struct SearchField: View {
    @Binding var text: String
    var onSubmit: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            TextField("搜索", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .focused($isFocused)
                .onSubmit { onSubmit?() }
                .onExitCommand {
                    text = ""
                    isFocused = false
                    onCancel?()
                }
            if !text.isEmpty {
                Button {
                    text = ""
                    isFocused = false
                    onCancel?()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
    }
}

// MARK: - portal 事件监听封装（拆分子表达式避免 Swift 类型推断超时）

private struct PortalEventsModifier: ViewModifier {
    let id: String
    let onFolderChanged: () -> Void
    let onSelectAll: () -> Void
    let onClearSelection: () -> Void
    let onActiveChanged: (Notification) -> Void
    let onRename: () -> Void
    let onQuickSelect: (String) -> Void
    let onSelectExact: (String) -> Void
    let onArrowNavigate: (String, Bool) -> Void
    let onGoUp: () -> Void
    let onEnterSelected: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .portalFolderChanged).filter { ($0.object as? String) == id }) { _ in onFolderChanged() }
            .onReceive(NotificationCenter.default.publisher(for: .portalSelectAll).filter { ($0.object as? String) == id }) { _ in onSelectAll() }
            .onReceive(NotificationCenter.default.publisher(for: .portalClearSelection).filter { ($0.object as? String) == id }) { _ in onClearSelection() }
            .onReceive(NotificationCenter.default.publisher(for: .portalActivePartitionChanged)) { onActiveChanged($0) }
            .onReceive(NotificationCenter.default.publisher(for: .portalRequestRename).filter { ($0.object as? String) == id }) { _ in onRename() }
            .onReceive(NotificationCenter.default.publisher(for: .portalQuickSelect).filter { ($0.object as? String) == id }) { n in
                if let exact = n.userInfo?["exactPath"] as? String {
                    onSelectExact(exact)
                } else if let char = n.userInfo?["char"] as? String {
                    onQuickSelect(char)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .portalArrowNavigate).filter { ($0.object as? String) == id }) { n in
                if let dir = n.userInfo?["direction"] as? String {
                    let shift = (n.userInfo?["shift"] as? Bool) ?? false
                    onArrowNavigate(dir, shift)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .portalNavigateParent).filter { ($0.object as? String) == id }) { _ in onGoUp() }
            .onReceive(NotificationCenter.default.publisher(for: .portalEnterSelected).filter { ($0.object as? String) == id }) { _ in onEnterSelected() }
    }
}

// MARK: - portal 文件网格（含排序、子文件夹浏览、新建文件夹、搜索）

struct PortalView: View {
    let folderPath: String
    let viewMode: String
    let id: String
    @State private var entries: [Entry] = []
    /// 扫描代次：后台扫描回来后用它判断结果是否已过期（快速切换目录时只采纳最后一次）
    @State private var scanGeneration = 0
    @State private var currentPath: String
    @State private var sortBy: String
    @State private var sortOrder: String
    @State private var showingNewFolder = false
    @State private var newFolderName = "新建文件夹"
    @State private var search = ""
    @State private var renaming: Entry?
    @State private var renameText = ""
    /// 整个内容区是否正被拖入的文件指着（用于画一圈高亮边框）
    @State private var isDropTargeted = false
    /// 正被拖入文件指着的**文件夹条目**路径（nil = 悬在空白处 / 非目录条目上）。
    ///
    /// ⚠️ 不能省：内层落点会把文件搬进这个子目录，而访达此时会把目标文件夹明显高亮出来。
    /// 历史事故：没有这圈高亮时，用户完全看不出落进了子层，两个文件夹就这么被「拖丢」了
    /// （`ss-project` 进了 `myself/test/`、`架构师课程` 进了 `work/ioc/`）。
    @State private var dropTargetPath: String? = nil
    /// 弹性文件夹（Spring-loaded Folders）延时展开任务
    @State private var springLoadWork: DispatchWorkItem? = nil
    /// 点击选中的条目（`FileSelection` 是纯逻辑，判据与 Windows / Electron 同源）
    @State private var selection = FileSelection()
    /// 双击检测：SwiftUI 的 `.onTapGesture(count: 2)` 与同视图的 `.onDrag` 共存时会被拖拽手势
    /// 吞掉、双击经常失灵。这里改成「记录上次点击的时间与路径」、用系统双击间隔判定，
    /// 既保留单击选中、又让双击打开 / 进入目录稳定生效（与 Windows 的 ClickCount、
    /// Electron 的原生 onDoubleClick 一致）。
    @State private var lastTapTime: Date = .distantPast
    @State private var lastTapPath: String = ""
    /// 本分区窗口当前是不是 key —— 决定选中高亮用「强」「弱」哪一档（见 selectionChrome）。
    @StateObject private var keyWatcher = WindowKeyWatcher()
    /// 键盘首字母跳转与方向键定位
    @State private var quickSearchBuffer = ""
    @State private var lastQuickSearchTime: TimeInterval = 0
    @State private var targetScrollPath: String? = nil
    /// 子目录返回上一级时的焦点与滚动恢复目标路径
    @State private var pendingRestorePath: String? = nil
    /// 容器宽度（用于计算网格方向键导航列数）
    @State private var containerWidth: CGFloat = 300
    /// `entries` 经搜索过滤后的可见条目缓存。
    ///
    /// 改为 `@State` 而非计算属性，避免同一次 body 调用中多处引用（toolbar / onChange /
    /// orderedSelected 等）各自重跑一遍 `filter`。只在 `search` 或 `entries` 真正变化时
    /// 由 `recomputeVisible()` 更新。
    @State private var visibleEntries: [Entry] = []

    init(folderPath: String, viewMode: String, id: String,
         sortBy: String = "name", sortOrder: String = "asc") {
        self.folderPath = folderPath
        self.viewMode = viewMode
        self.id = id
        let savedSub = AppDelegate.shared?.config.str("currentSubPath", of: id)
        let initialPath: String
        if let sub = savedSub, !sub.isEmpty, FileManager.default.fileExists(atPath: sub),
           !folderPath.isEmpty, sub.hasPrefix(folderPath) {
            initialPath = sub
        } else {
            initialPath = folderPath
        }
        _currentPath = State(initialValue: initialPath)
        _sortBy = State(initialValue: sortBy)
        _sortOrder = State(initialValue: sortOrder)
    }

    struct Entry: Identifiable, Equatable {
        var id: String { path }
        let name: String
        /// **是否当文件夹对待**（= 是目录 且 不是包）。`.app` 在这里是 `false` ——
        /// 双击要启动应用，而不是钻进 `Foo.app/Contents/`。
        let isDir: Bool
        /// 是否是个「包」（`.app` / `.bundle` / `.pages` …）。仅用于右键菜单
        /// 额外提供一枚「显示包内容」出口，以及挑选图标。
        let isPackage: Bool
        let size: Int64
        let path: String
        let modDate: Date
        let fileType: String
    }

    private func normalizePath(_ p: String) -> String {
        URL(fileURLWithPath: p).standardized.path
    }

    private var isBrowsingSub: Bool {
        let cur = normalizePath(currentPath)
        let root = normalizePath(folderPath)
        return !cur.isEmpty && !root.isEmpty && cur != root
    }
    /// 根据当前 `search` 和 `entries` 重算 `visibleEntries`。
    ///
    /// 调用时机：`entries` 被赋值之后、`search` 变化之后。
    /// 绝不在 body 里直接调用 —— 那样等于把计算属性的问题原样搬到这里。
    private func recomputeVisible() {
        if search.isEmpty {
            visibleEntries = entries
        } else {
            visibleEntries = entries.filter { $0.name.localizedCaseInsensitiveContains(search) }
        }
    }
    private var sortLabel: String {
        switch sortBy {
        case "time": return "时间"
        case "size": return "大小"
        case "type": return "类型"
        default: return "名称"
        }
    }
    /// 当前选区条目数缓存 —— 专门为了给 body 里的条件分支和 animation value 使用。
    ///
    /// 原先在 body 里写 `let selCount = orderedSelected().count` + `return ZStack(...)`，
    /// `let`+`return` 会让 SwiftUI 的类型检查器超时。改为 @State 后 body 里只读属性，
    /// 无需 return，也不在每次重算 body 时重跑排序。
    @State private var selectionCount: Int = 0

    var body: some View {
        bodyCore
            .alert("新建文件夹", isPresented: $showingNewFolder) {
                TextField("文件夹名称", text: $newFolderName)
                Button("创建") {
                    AppDelegate.shared?.createFolderInPortal(id, path: currentPath, name: newFolderName)
                    newFolderName = "新建文件夹"
                }
                Button("取消", role: .cancel) { newFolderName = "新建文件夹" }
            } message: {
                Text("在 \(currentPath) 下创建")
            }
            .alert("重命名", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("新名称", text: $renameText)
                Button("确定") {
                    if let e = renaming {
                        AppDelegate.shared?.renameFile(e.path, to: renameText)
                        load()
                    }
                    renaming = nil
                }
                Button("取消", role: .cancel) { renaming = nil }
            }
    }

    /// body 的主体布局 + 事件修饰（拆出来给编译器减压）。
    private var bodyCore: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                toolbar
                if isBrowsingSub { breadcrumbBar }
                Divider().opacity(0.5)
                content
            }

            if selectionCount >= 2 {
                selectionActionBar
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: selectionCount >= 2)
        .onAppear {
            reportContext()
            load()
        }
        .onDisappear {
            springLoadWork?.cancel()
            springLoadWork = nil
            AppDelegate.shared?.releasePortalContext(id)
        }
        .background(WindowKeyProbe { keyWatcher.bind($0) })
        .modifier(PortalEventsModifier(
            id: id,
            // 目录变化走合并入口：连着来的通知只跑最后一次扫描（见 `scheduleReload`）。
            // 其余入口（切目录 / 刷新按钮 / 排序）仍直接 `load()`，要的是即时反馈。
            onFolderChanged: { scheduleReload() },
            onSelectAll: { selectAllVisible() },
            onClearSelection: {
                selection.clear()
                lastTapTime = .distantPast
                lastTapPath = ""
                if QuickPreview.shared.isShowing {
                    QuickPreview.shared.close()
                }
            },
            onActiveChanged: { n in
                if FileSelectionScope.shouldClear(ownID: id, activeID: n.object as? String) {
                    lastTapTime = .distantPast
                    lastTapPath = ""
                    selection.clear()
                }
            },
            onRename: { renameSingleSelection() },
            onQuickSelect: { handleQuickSelect(char: $0) },
            onSelectExact: { path in
                selection.click(path, visible: visibleEntries.map(\.path))
                targetScrollPath = path
            },
            onArrowNavigate: { handleArrowNavigate(direction: $0, shift: $1) },
            onGoUp: { goUp() },
            onEnterSelected: { enterSelected() }
        ))
        // visibleEntries 是 @State，SwiftUI 直接对比新旧值，无需再 .map(\.path)
        .onChange(of: visibleEntries) { _ in
            selectionCount = selection.orderedSelection(visible: visibleEntries.map(\.path)).count
            reportContext()
        }
        .onChange(of: search) { _ in recomputeVisible() }
        .onChange(of: selection.selected) { sel in
            // 同步选区条目数，供 body 里 selectionActionBar 的显隐和 animation 使用。
            selectionCount = selection.orderedSelection(visible: visibleEntries.map(\.path)).count
            reportContext()
            // 实时预览连播：若空格快速预览当前已处于显示状态，自动无缝切到新选中的文件或文件夹
            if QuickPreview.shared.isShowing {
                let current = orderedSelected().first ?? sel.first
                if let path = current,
                   let entry = visibleEntries.first(where: { $0.path == path }) {
                    QuickPreview.shared.show(entry.path)
                }
            }
        }
        .onChange(of: currentPath) { _ in reportContext() }
    }

    /// 多级面包屑：`根目录 > 子A > 子B`，点击任意祖先节点直接跳转。
    private var breadcrumbBar: some View {
        HStack(spacing: 4) {
            Button {
                goUp()
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 8, weight: .semibold))
                    Text("返回")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help("返回上一级 (⌘↑)")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(breadcrumbs.enumerated()), id: \.offset) { idx, crumb in
                        if idx > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 7)).foregroundStyle(.tertiary)
                        }
                        Button {
                            if crumb.path != currentPath {
                                let curNorm = normalizePath(currentPath)
                                let targetNorm = normalizePath(crumb.path)
                                if curNorm.hasPrefix(targetNorm) {
                                    let subPart = String(curNorm.dropFirst(targetNorm.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                                    let firstSeg = subPart.components(separatedBy: "/").first ?? ""
                                    if !firstSeg.isEmpty {
                                        pendingRestorePath = (targetNorm as NSString).appendingPathComponent(firstSeg)
                                    }
                                }
                                navigate(to: crumb.path)
                            }
                        } label: {
                            Text(crumb.label)
                                .font(.system(size: 10))
                                .foregroundStyle(idx == breadcrumbs.count - 1 ? Color.primary : Color.accentColor)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
    }

    /// 从根到当前路径的每一层（label, 完整 path）。
    private var breadcrumbs: [(label: String, path: String)] {
        var result: [(String, String)] = []
        let root = folderPath.isEmpty ? "/" : folderPath
        let rootName = (root as NSString).lastPathComponent.isEmpty ? "/" : (root as NSString).lastPathComponent
        result.append((rootName, root))
        guard currentPath != root, currentPath.hasPrefix(root) else { return result }
        let rel = currentPath.dropFirst(root.count)
        var acc = root
        for seg in rel.split(separator: "/") {
            acc = (acc as NSString).appendingPathComponent(String(seg))
            result.append((String(seg), acc))
        }
        return result
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button { cycleSort() } label: {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.up.arrow.down").font(.system(size: 8))
                    Text(sortLabel).font(.system(size: 10))
                    Image(systemName: sortOrder == "asc" ? "chevron.up" : "chevron.down").font(.system(size: 7))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("当前排序：\(sortLabel) \(sortOrder == "asc" ? "升序" : "降序")，点击切换排序方式")

            Button {
                sortOrder = sortOrder == "asc" ? "desc" : "asc"
                AppDelegate.shared?.updatePartition(id, key: "sortOrder", value: sortOrder)
                sortEntries()
            } label: {
                Image(systemName: sortOrder == "asc" ? "arrow.down" : "arrow.up")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("切换升序/降序")

            Button {
                AppDelegate.shared?.setViewMode(id, viewMode == "list" ? "grid" : "list")
            } label: {
                Image(systemName: viewMode == "list" ? "square.grid.2x2" : "list.bullet")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("切换网格/列表视图")

            SearchField(text: $search, onSubmit: { handleSearchSubmit() }).frame(maxWidth: 110)

            Button { showingNewFolder = true } label: {
                Image(systemName: "folder.badge.plus").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("新建文件夹")

            Button { AppDelegate.shared?.openFile(currentPath) } label: {
                Image(systemName: "arrow.up.right.square").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("在访达中打开当前目录")

            Button { load() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("即时刷新当前目录")

            if isBrowsingSub {
                Button { goUp() } label: {
                    Image(systemName: upGoesToRoot ? "house" : "chevron.left")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(upGoesToRoot ? "返回根目录" : "返回上一级")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private func handleSearchSubmit() {
        guard let first = visibleEntries.first else { return }
        openEntry(first)
    }

    private func highlightedName(_ name: String) -> AttributedString {
        var str = AttributedString(name)
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let range = str.range(of: q, options: .caseInsensitive) else {
            return str
        }
        str[range].foregroundColor = .accentColor
        str[range].inlinePresentationIntent = .stronglyEmphasized
        return str
    }

    private var selectionActionBar: some View {
        let targets = orderedSelected()
        let count = targets.count
        let totalSize: Int64 = targets.compactMap { entry(for: $0)?.size }.reduce(0, +)
        let sizeText = ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)

        return HStack(spacing: 8) {
            Text("已选 \(count) 项\(totalSize > 0 ? " · " + sizeText : "")")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)

            Rectangle()
                .fill(Color.primary.opacity(0.18))
                .frame(width: 1, height: 12)

            Button {
                AppDelegate.shared?.copyToClipboard(targets)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .help("拷贝")

            Button {
                AppDelegate.shared?.compressPaths(targets, in: id)
            } label: {
                Image(systemName: "archivebox")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .help("压缩为 ZIP")

            Button {
                AppDelegate.shared?.trashPaths(targets, in: id)
                load()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundStyle(.red.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help("移到废纸篓")

            Button {
                selection.clear()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("取消选中 (Esc)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.2), radius: 6, y: 3)
    }

    /// 内容本体：空态 / 列表 / 网格三选一。
    ///
    /// ⚠️ 为什么从 `content` 里拆出来：`@ViewBuilder` 内部写 `let` + `return` 会触发
    /// 「result builder 'ViewBuilder' disabled by explicit 'return' statement」警告，
    /// 等于整个闭包退化成普通函数、不再走 ViewBuilder。拆开后 `content` 只有一个表达式。
    private var baseContent: AnyView {
        if visibleEntries.isEmpty {
            // 空文件夹也要能吃拖放：这正是「把一个空分区当收件篮」的典型用法，
            // 没有文件可点时如果还拒绝落点，用户会以为这个功能坏了。
            return AnyView(emptyState.onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                loadDroppedPaths(providers) { importFiles($0, into: currentPath) }
                return true
            })
        } else if viewMode == "list" {
            return AnyView(list)
        } else {
            return AnyView(grid)
        }
    }

    @ViewBuilder
    private var content: some View {
        baseContent
            // 拖入时给一圈高亮：不然「松手到底会不会生效」全靠猜
            .overlay(alignment: .center) {
                // ⚠️ 与文件夹条目的高亮**互斥**：两个一起亮等于没区分，
                // 又回到「看不出到底落在当前目录还是子目录」的老问题。
                if isDropTargeted && dropTargetPath == nil {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 2)
                        .padding(4)
                }
            }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if !search.isEmpty {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                Text("未找到与“\(search)”匹配的项目")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Button("清除搜索 (Esc)") {
                    search = ""
                }
                .font(.system(size: 11))
                .buttonStyle(.link)
            } else {
                Image(systemName: "folder")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary.opacity(0.6))
                Text("此文件夹为空")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("可将文件拖拽至此处，或右键新建")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: clearSelection)
        .contextMenu { blankMenu }
    }

    // MARK: - 右键菜单

    /// 右键菜单的**操作目标** —— 对齐访达：多选之后菜单作用于**整个选区**，
    /// 而不是右键戳到的那一个。
    ///
    /// ⚠️ 点在「没选中」的条目上时只操作它自己：否则「右键别的文件顺手删一下」
    /// 会连坐一堆不相干的东西。访达也是这样判的。
    private func menuTargets(_ e: Entry) -> [String] {
        selection.menuTargets(clicked: e.path, visible: visibleEntries.map(\.path))
    }

    /// 选区按**当前显示顺序**排好（判据在 `FileSelection`，三端同源且有断言）。
    private func orderedSelected() -> [String] {
        selection.orderedSelection(visible: visibleEntries.map(\.path))
    }

    private func entry(for path: String) -> Entry? { entries.first { $0.path == path } }

    private func fileMenu(_ e: Entry) -> some View {
        let targets = menuTargets(e)
        return Group {
            if targets.count <= 1, let one = targets.first, let found = entry(for: one) {
                singleItemMenu(found)
            } else {
                multiItemMenu(targets)
            }
        }
    }

    private func singleItemMenu(_ e: Entry) -> some View {
        Group {
            // 【第 1 组】：打开方式
            if e.isDir {
                Button("在分区内展开浏览") { enterSub(e.path) }
            } else {
                Button(primaryOpenLabel(isDir: false, isPackage: e.isPackage, fileType: e.fileType)) {
                    AppDelegate.shared?.openFile(e.path)
                }
                if e.isPackage {
                    Button("显示包内容（在分区内展开）") { enterSub(e.path) }
                }
            }
            Button("在访达中显示") { AppDelegate.shared?.revealInFinder(e.path) }
            if e.isDir {
                Button("在终端中打开") { AppDelegate.shared?.openInTerminal(e.path) }
                if AppDelegate.shared?.isVSCodeAvailable == true {
                    Button("在 VS Code 中打开") { AppDelegate.shared?.openInVSCode(e.path) }
                }
            } else if AppDelegate.shared?.isVSCodeAvailable == true {
                Button("在 VS Code 中打开") { AppDelegate.shared?.openInVSCode(e.path) }
            }

            Divider()

            // 【第 2 组】：废纸篓
            Button("移到废纸篓", role: .destructive) {
                AppDelegate.shared?.trashPaths([e.path], in: id)
                load()
            }

            Divider()

            // 【第 3 组】：文件管理核心动作（对齐访达原生）
            Button("显示简介") { AppDelegate.shared?.showGetInfo([e.path]) }
            Button("重新命名") {
                AppDelegate.shared?.activatePartition(id)
                renaming = e
                renameText = e.name
            }
            if FileKinds.isArchive(e.path) {
                Button("解压“\(e.name)”") { AppDelegate.shared?.unarchivePath(e.path, in: id) }
            }
            Button("压缩“\(e.name)”") { AppDelegate.shared?.compressPaths([e.path], in: id) }
            Button("复制") { AppDelegate.shared?.duplicatePaths([e.path], in: id) }
            Button("快速查看") { AppDelegate.shared?.quickLook(e.path) }

            Divider()

            // 【第 4 组】：剪贴板
            Button("拷贝") { AppDelegate.shared?.copyToClipboard([e.path]) }
            Button("剪切") { AppDelegate.shared?.cutToClipboard([e.path]) }
        }
    }

    /// 多选菜单：只保留**对每个选中项都说得通**的动作。
    private func multiItemMenu(_ paths: [String]) -> some View {
        let n = paths.count
        let dirs = paths.compactMap { entry(for: $0) }.filter(\.isDir)
        let files = paths.compactMap { entry(for: $0) }.filter { !$0.isDir }
        let archives = paths.filter { FileKinds.isArchive($0) }
        return Group {
            // 【第 1 组】：打开
            if dirs.count == 1 && files.isEmpty {
                Button("在分区内展开浏览") { enterSub(dirs[0].path) }
            } else {
                Button("打开（\(n) 项）") {
                    for f in files { AppDelegate.shared?.performDoubleClick(path: f.path, isDirectory: false) }
                    for d in dirs { AppDelegate.shared?.openFile(d.path) }
                }
            }
            Button("在访达中显示（\(n) 项）") { AppDelegate.shared?.revealInFinderAll(paths) }

            Divider()

            // 【第 2 组】：废纸篓
            Button("移到废纸篓（\(n) 项）", role: .destructive) {
                AppDelegate.shared?.trashPaths(paths, in: id)
                load()
            }

            Divider()

            // 【第 3 组】：文件管理
            Button("显示简介（\(n) 项）") { AppDelegate.shared?.showGetInfo(paths) }
            if !archives.isEmpty {
                Button(archives.count == 1 ? "解压归档文件" : "解压归档文件（\(archives.count) 项）") {
                    for arch in archives {
                        AppDelegate.shared?.unarchivePath(arch, in: id)
                    }
                }
            }
            Button("压缩 \(n) 项") { AppDelegate.shared?.compressPaths(paths, in: id) }
            Button("复制（\(n) 项）") { AppDelegate.shared?.duplicatePaths(paths, in: id) }
            if let first = paths.first {
                Button("快速查看") { AppDelegate.shared?.quickLook(first) }
            }

            Divider()

            // 【第 4 组】：剪贴板
            Button("拷贝（\(n) 项）") { AppDelegate.shared?.copyToClipboard(paths) }
            Button("剪切（\(n) 项）") { AppDelegate.shared?.cutToClipboard(paths) }
        }
    }

    /// **空白处**的右键菜单 —— 访达 / 资源管理器里点空白处就是这一组动作，
    /// 缺了它用户会以为「这个分区不支持右键」。
    private var blankMenu: some View {
        let canPaste = !FileClipboard.shared.isEmpty
        let hasSelection = !selection.selected.isEmpty
        let isVSCode = AppDelegate.shared?.isVSCodeAvailable ?? false
        return Group {
            Button("新建文件夹") {
                AppDelegate.shared?.activatePartition(id)
                showingNewFolder = true
            }
            Button("新建文本文档") {
                AppDelegate.shared?.activatePartition(id)
                if let newFile = AppDelegate.shared?.createFileInPortal(id, path: currentPath) {
                    load()
                    selection.click(newFile, visible: visibleEntries.map(\.path))
                    targetScrollPath = newFile
                }
            }
            Button("粘贴") { AppDelegate.shared?.pasteClipboard(into: currentPath, in: id) }
                .disabled(!canPaste)
            Divider()
            Button("全选") { selectAllVisible() }
            Button("取消选中") { selection.clear() }
                .disabled(!hasSelection)
            Divider()
            Button("在访达中打开当前目录") { AppDelegate.shared?.openFile(currentPath) }
            Button("在终端中打开当前目录") { AppDelegate.shared?.openInTerminal(currentPath) }
            if isVSCode {
                Button("在 VS Code 中打开当前目录") { AppDelegate.shared?.openInVSCode(currentPath) }
            }
            Button("立即刷新") { load() }
        }
    }

    /// ⌘A / 空白菜单的「全选」：选中**当前可见**的全部条目。
    ///
    /// ⚠️ 必须是 visibleEntries（已经过搜索过滤）而不是 entries：用户按 ⌘A 的意图是
    /// 「选我看到的这些」，把被过滤掉的也选进去等于篡改了他的意图。
    private func selectAllVisible() {
        let all = visibleEntries.map(\.path)
        guard let first = all.first else { return }
        selection.click(first, visible: all)
        for p in all.dropFirst() { selection.click(p, visible: all, command: true) }
    }

    /// Enter / F2：给**唯一**选中项弹重命名框。
    private func renameSingleSelection() {
        let chosen = orderedSelected()
        guard chosen.count == 1, let e = entry(for: chosen[0]) else { return }
        renaming = e
        renameText = e.name
    }

    /// 把当前可见集合 / 选区 / 目录上报给 AppDelegate —— 键盘意图判据的输入。
    /// ⚠️ 传 visibleEntries 而不是 entries：搜索过滤掉的条目不该参与全选与批量操作。
    private func reportContext() {
        AppDelegate.shared?.syncPortalContext(id,
                                              visible: visibleEntries.map(\.path),
                                              selected: orderedSelected(),
                                              cwd: currentPath)
    }

    private func handleQuickSelect(char: String) {
        lastTapTime = .distantPast
        lastTapPath = ""
        let now = Date().timeIntervalSince1970
        let candidates = visibleEntries.map { (name: $0.name, path: $0.path) }
        let currentSelected = orderedSelected().first

        let (newBuf, matched) = TypeToSelect.resolve(
            char: char,
            currentBuffer: quickSearchBuffer,
            lastInputTime: lastQuickSearchTime,
            now: now,
            candidates: candidates,
            currentSelectedPath: currentSelected
        )
        quickSearchBuffer = newBuf
        lastQuickSearchTime = now

        if let target = matched {
            selection.click(target, visible: visibleEntries.map(\.path))
            targetScrollPath = target
        }
    }

    private func handleArrowNavigate(direction: String, shift: Bool) {
        lastTapTime = .distantPast
        lastTapPath = ""
        let dir: TypeToSelect.Direction = {
            switch direction {
            case "up": return .up
            case "down": return .down
            case "left": return .left
            case "right": return .right
            default: return .down
            }
        }()

        let allPaths = visibleEntries.map(\.path)
        guard !allPaths.isEmpty else { return }

        let currentSelected = orderedSelected()
        let currentIdx: Int?
        if let first = currentSelected.first, let idx = allPaths.firstIndex(of: first) {
            currentIdx = idx
        } else {
            currentIdx = nil
        }

        let columns = viewMode == "list" ? 1 : max(1, Int((containerWidth - 20 + 8) / 82))
        let nextIdx = TypeToSelect.nextIndex(
            currentIndex: currentIdx,
            direction: dir,
            count: allPaths.count,
            columns: columns
        )
        guard nextIdx >= 0 && nextIdx < allPaths.count else { return }
        let target = allPaths[nextIdx]

        if shift {
            selection.click(target, visible: allPaths, shift: true)
        } else {
            selection.click(target, visible: allPaths)
        }
        targetScrollPath = target
    }

    private var grid: some View {
        GeometryReader { geo in
            ScrollViewReader { scrollProxy in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        // 空白区（至少铺满一屏高度）：点它取消选中 —— 与访达 / 资源管理器一致。
                        // ⚠️ 必须是**背景层**：放在最底下才能让条目自己吃掉点击，
                        // 否则「点文件」会连着触发一次「点空白」把刚选中的又清掉。
                        Color.clear
                            .frame(maxWidth: .infinity, minHeight: geo.size.height)
                            .contentShape(Rectangle())
                            .onTapGesture(perform: clearSelection)
                            // 空白处的右键菜单（新建 / 粘贴 / 全选 / 刷新）—— 访达里点空白就是这个
                            .contextMenu { blankMenu }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 8)], spacing: 10) {
                            ForEach(visibleEntries, id: \.path) { e in
                                gridItem(e)
                                    .id(e.path)
                            }
                        }
                        .padding(10)
                    }
                }
                .onAppear { containerWidth = geo.size.width }
                .onChange(of: geo.size.width) { containerWidth = $0 }
                .onChange(of: targetScrollPath) { path in
                    if let p = path {
                        withAnimation(.easeOut(duration: 0.15)) {
                            scrollProxy.scrollTo(p, anchor: .center)
                        }
                    }
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            springLoadWork?.cancel()
            springLoadWork = nil
            loadDroppedPaths(providers) { importFiles($0, into: currentPath) }
            return true
        }
    }

    private func gridItem(_ e: Entry) -> some View {
        VStack(spacing: 4) {
            entryThumb(path: e.path, isDir: e.isDir, isPackage: e.isPackage,
                       fileType: e.fileType, size: 22)
            // 文件名恒为一行，超出用省略号；悬停用系统 tooltip 显示完整名称；搜索时高亮匹配
            Text(highlightedName(e.name))
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .help(e.name)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 64)
        .background(
            selectionChrome(selection.isSelected(e.path), radius: 8)
                // 高亮比条目本身略大一圈，视觉上才是「框住」而不是「压住」
                .padding(-3)
        )
        .contentShape(Rectangle())
        // 单击 = 选中（画高亮），双击 = 打开 / 进入目录。
        // ⚠️ 双击用手动检测（handleTap）而非 `.onTapGesture(count: 2)`：
        // 后者与同视图的 `.onDrag` 共存时会被拖拽手势吞掉、双击失灵。
        .onTapGesture { handleTap(e) }
        // 拖出用自建的 NSDraggingSource（见 FileDragSource.swift）：
        // SwiftUI 的 `.onDrag` 拿不到拖拽结束回执，拖出去就永远只是「复制」，
        // 原件留在映射文件夹里 —— 表现为「移出了但文件还在」。
        .overlay(FileDragSource(paths: dragPaths(for: e), partitionID: id).allowsHitTesting(false))
        // 被拖入的文件指着这个文件夹时画出来 —— 访达里此时文件夹会高亮。
        // ⚠️ 没有它，「落进这个子目录」与「落在当前目录」在屏幕上长得一模一样，
        // 用户只能靠松手后的结果反推落点（真事故：两个文件夹被静默塞进了子层）。
        .overlay(
            ZStack {
                if dropTargetPath == e.path {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(0.18))
                    // ⚠️ strokeBorder 必须直接作用在 Shape 上：接在 .fill() 之后就变成
                    // View 修饰器，那个重载要 macOS 14+，比项目部署目标新。
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            .allowsHitTesting(false)
            .padding(-3)
        )
        // 拖到**文件夹图标上** = 放进去（内层优先于整个内容区的落点）
        .onDrop(of: [.fileURL], isTargeted: isFolderTargeted(e)) { providers in
            springLoadWork?.cancel()
            springLoadWork = nil
            dropTargetPath = nil
            guard e.isDir else { return false }
            if FileDrag.isDropTargetForbidden(for: e.path) { return false }
            loadDroppedPaths(providers) { dropped in
                let valid = dropped.filter { !FileMove.isSelfOrDescendant(e.path, of: $0) }
                guard !valid.isEmpty else { return }
                importFiles(valid, into: e.path)
            }
            return true
        }
        .contextMenu { fileMenu(e) }
    }

    /// 本次要拖出去的路径：与访达一致 —— 拖的是**选中的那批**，不是只有光标下这一个。
    ///
    /// 只选中了一个、或拖的那一项并不在选区里，就只拖它自己。
    private func dragPaths(for e: Entry) -> [String] {
        let sel = selection.orderedSelection(visible: visibleEntries.map(\.path))
        return sel.count > 1 && sel.contains(e.path) ? sel : [e.path]
    }

    /// 单个文件夹条目的 `isTargeted` 绑定：所有条目共用 `dropTargetPath`，靠路径区分谁被指着。
    /// 包含 macOS 原生 Spring-loaded Folders 特性：拖拽文件悬停在文件夹上 0.65 秒自动展开进入子目录。
    ///
    /// 为什么不让每个条目各持一个 `@State`：条目是 `gridItem` / `listRow` 这样的函数而
    /// 非独立 `View`（`ForEach` 里直接用），没有自己的状态存储；共用一个状态反而天然
    /// 保证「同一时刻只有一个条目亮」。
    private func isFolderTargeted(_ e: Entry) -> Binding<Bool> {
        Binding(
            get: { dropTargetPath == e.path },
            set: { targeted in
                if targeted {
                    // ⚠️ 如果当前正在拖拽的条目包含本条目自身、或是本条目的祖先目录，
                    // 绝不能将自身作为落点，也绝不能触发 Spring-loaded 自动展开！
                    if FileDrag.isDropTargetForbidden(for: e.path) {
                        if dropTargetPath == e.path {
                            dropTargetPath = nil
                            springLoadWork?.cancel()
                            springLoadWork = nil
                        }
                        return
                    }

                    dropTargetPath = e.path
                    if e.isDir {
                        springLoadWork?.cancel()
                        let targetPath = e.path
                        let work = DispatchWorkItem {
                            if dropTargetPath == targetPath {
                                enterSub(targetPath)
                                dropTargetPath = nil
                            }
                        }
                        springLoadWork = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: work)
                    }
                } else {
                    if dropTargetPath == e.path {
                        dropTargetPath = nil
                        springLoadWork?.cancel()
                        springLoadWork = nil
                    }
                }
            }
        )
    }

    private var list: some View {
        GeometryReader { geo in
            ScrollViewReader { scrollProxy in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        // 与网格视图同一口径：点空白取消选中
                        Color.clear
                            .frame(maxWidth: .infinity, minHeight: geo.size.height)
                            .contentShape(Rectangle())
                            .onTapGesture(perform: clearSelection)
                            // 与网格视图同一口径：空白处右键菜单
                            .contextMenu { blankMenu }
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(visibleEntries, id: \.path) { e in
                                listRow(e)
                                    .id(e.path)
                            }
                        }
                        // 与网格视图一致：内容距分区顶部/底部各留 10pt
                        .padding(.vertical, 10)
                    }
                }
                .onChange(of: targetScrollPath) { path in
                    if let p = path {
                        withAnimation(.easeOut(duration: 0.15)) {
                            scrollProxy.scrollTo(p, anchor: .center)
                        }
                    }
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            springLoadWork?.cancel()
            springLoadWork = nil
            loadDroppedPaths(providers) { importFiles($0, into: currentPath) }
            return true
        }
    }

    private func listRow(_ e: Entry) -> some View {
        HStack(spacing: 8) {
            entryThumb(path: e.path, isDir: e.isDir, isPackage: e.isPackage,
                       fileType: e.fileType, size: 14)
            Text(highlightedName(e.name)).font(.system(size: 12)).foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(e.name)          // 悬停显示完整文件名
            Spacer(minLength: 6)
            if !e.isDir {
                Text(ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .layoutPriority(1)  // 大小列优先，长文件名先被截断
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(selectionChrome(selection.isSelected(e.path), radius: 6).padding(-1))
        .contentShape(Rectangle())
        .onTapGesture { handleTap(e) }
        // 与网格视图同一口径：自建拖拽源，拿到系统的 move / copy 回执
        .overlay(FileDragSource(paths: dragPaths(for: e), partitionID: id).allowsHitTesting(false))
        // 与网格视图同一口径：被指着的文件夹要画出来（否则看不出会落进子层）
        .overlay(
            ZStack {
                if dropTargetPath == e.path {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(0.18))
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            .allowsHitTesting(false)
            .padding(-1)
        )
        // 与网格视图同一口径：拖到文件夹条目上 = 放进那个文件夹
        .onDrop(of: [.fileURL], isTargeted: isFolderTargeted(e)) { providers in
            springLoadWork?.cancel()
            springLoadWork = nil
            dropTargetPath = nil
            guard e.isDir else { return false }
            if FileDrag.isDropTargetForbidden(for: e.path) { return false }
            loadDroppedPaths(providers) { dropped in
                let valid = dropped.filter { !FileMove.isSelfOrDescendant(e.path, of: $0) }
                guard !valid.isEmpty else { return }
                importFiles(valid, into: e.path)
            }
            return true
        }
        .contextMenu { fileMenu(e) }
    }

    /// 把拖进来的文件搬进 `directory`，完事刷新列表并给一条 Toast。
    ///
    /// ⚠️ 是**移动**不是复制 —— 用户拖进来的意图就是「把这个文件收进这个分区」，
    /// 留在原地会变成两份，反而要回头去删。同名冲突按访达习惯自动加「 2」后缀，
    /// 绝不静默覆盖（覆盖是不可撤销的）。
    private func importFiles(_ paths: [String], into directory: String) {
        guard !paths.isEmpty else { return }
        // ⚠️ 告诉拖出方「这次是应用内部接的」：文件由下面自己搬走，
        // 拖拽结束回执里若也收到 .move，绝不能再删一次原件（那会删掉刚搬过去的新位置）。
        FileDrag.handledInsideApp = true
        let validPaths = paths.filter { !FileMove.isSelfOrDescendant(directory, of: $0) }
        guard !validPaths.isEmpty else { return }
        let result = AppDelegate.shared?.moveFilesIntoPortal(id, paths: validPaths, directory: directory)
        load()
        guard let r = result else { return }
        if r.moved > 0 {
            Toast.shared.show("已移入 \(r.moved) 个文件",
                              detail: "→ \(dropDetail(directory))",
                              icon: "tray.and.arrow.down.fill",
                              emphasized: false)
        }
        if !r.failed.isEmpty {
            Toast.shared.show("\(r.failed.count) 个文件没能移入",
                              detail: r.failed.prefix(2).joined(separator: "、"),
                              icon: "exclamationmark.triangle.fill",
                              emphasized: true)
        }
    }

    /// 落点提示文字：家目录缩写成 `~`，过长只留末几段。
    ///
    /// 为什么不能像以前那样只给 `lastPathComponent`（只显示 "ioc"）：同名子目录到处都是，
    /// 只看末段根本判断不出文件进了哪一层 —— 这正是「文件夹拖不见了」的加重因素。
    /// 落点写得清楚，即使真放错了，用户也能立刻看出该去哪儿找回来。
    private func dropDetail(_ directory: String) -> String {
        let home = NSHomeDirectory()
        var d = FileMove.normalize(directory)
        if d.hasPrefix(home) { d = "~" + d.dropFirst(home.count) }
        let parts = d.split(separator: "/").map(String.init)
        // 太长就只留尾巴：用户要知道的是「进了哪一层」，不是完整前缀
        if parts.count > 3 { return "…/" + parts.suffix(3).joined(separator: "/") }
        return d
    }

    private func cycleSort() {
        let modes = ["name", "time", "size", "type"]
        let idx = modes.firstIndex(of: sortBy) ?? 0
        sortBy = modes[(idx + 1) % modes.count]
        AppDelegate.shared?.updatePartition(id, key: "sortBy", value: sortBy)
        sortEntries()
    }

    private func enterSub(_ path: String) { navigate(to: path) }

    /// 双击条目：先按类型分派。**portal 里目录 = 进入**，其余走 `FileKinds` 判据。
    ///
    /// 判据本身在 `FileKinds.doubleClickAction`（三端同源 + 单测），这里只做 portal
    /// 特有的一步：目录要在**本分区内浏览**，而不是丢给访达。
    private func openEntry(_ e: Entry) {
        if e.isDir { enterSub(e.path); return }
        AppDelegate.shared?.performDoubleClick(path: e.path, isDirectory: false)
    }

    private func navigate(to path: String) {
        springLoadWork?.cancel()
        springLoadWork = nil
        // 换目录 = 换了一批条目，旧选区里的路径全部失效
        selection.clear()
        lastTapTime = .distantPast
        lastTapPath = ""
        currentPath = path
        let subToSave = (path == folderPath || folderPath.isEmpty) ? "" : path
        AppDelegate.shared?.updatePartition(id, key: "currentSubPath", value: subToSave)
        load()
    }

    // MARK: - 选中（点击高亮）

    /// 单击条目：⌘ 切换 / ⇧ 区间 / 直接点替换。判据全在 `FileSelection`，这里只负责取修饰键。
    ///
    /// ⚠️ 用 `NSEvent.modifierFlags` 而不是 SwiftUI 的 `EventModifiers`：
    /// 后者要按类型逐个声明手势，写不出「同一个点击、四种语义」。
    /// 单击 / 双击统一入口：用手动计时替代 SwiftUI 脆弱的 `.onTapGesture(count: 2)`。
    ///
    /// - 两次点击落在**同一路径**且间隔小于系统双击阈值（`NSEvent.doubleClickInterval`）→ 双击，打开 / 进入目录；
    /// - 否则 → 单击，选中（⌘ 切换 / ⇧ 区间）。
    ///
    /// ⚠️ 之所以不用 SwiftUI 的双击手势：它与同视图的 `.onDrag` 共存时会被拖拽手势吞掉，
    /// 表现就是「双击没反应」。这里只保留一个单击手势，双击靠计时判定，彻底避开冲突。
    private func handleTap(_ e: Entry) {
        let now = Date()
        let isDouble = e.path == lastTapPath && now.timeIntervalSince(lastTapTime) < NSEvent.doubleClickInterval
        lastTapTime = now
        lastTapPath = e.path
        if isDouble {
            lastTapTime = .distantPast   // 消费掉，避免三连击误判成又一轮双击
            openEntry(e)
        } else {
            handleSelect(e)
        }
    }

    private func handleSelect(_ e: Entry) {
        AppDelegate.shared?.activatePartition(id)
        let flags = NSEvent.modifierFlags
        selection.click(e.path,
                        visible: visibleEntries.map(\.path),
                        command: flags.contains(.command),
                        shift: flags.contains(.shift))
    }

    private func clearSelection() {
        selection.clear()
        lastTapTime = .distantPast
        lastTapPath = ""
        if QuickPreview.shared.isShowing {
            QuickPreview.shared.close()
        }
    }

    /// 选中态的背景 + 描边。
    ///
    /// ⚠️ 描边用 `Color.accentColor`（跟随系统强调色），**不要**写死白/蓝：
    /// 分区背景色是可配的（`style.bgColor`），浅色背景上白边等于隐形。
    ///
    /// 窗口不是 key 时适度平缓降透明度，但依然保持明确可见的高亮形态（对齐 macOS 访达原生非活动选中），
    /// 避免在快速预览浮层弹起或焦点切换瞬间条目选中效果“消失”。
    /// ⚠️ 降级**只改透明度、不动几何**：条目位置宽度完全不变，跨窗口不会有半像素抖动。
    @ViewBuilder
    private func selectionChrome(_ selected: Bool, radius: CGFloat) -> some View {
        let strong = keyWatcher.isKey
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(selected ? Color.accentColor.opacity(strong ? 0.28 : 0.18) : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(strong ? 0.9 : 0.60) : Color.clear,
                                  lineWidth: 1.5)
            )
    }

    /// 当前「返回上一级」是否会落到根（用于切换 house / chevron 图标）。
    private var upGoesToRoot: Bool {
        let cur = normalizePath(currentPath)
        let root = normalizePath(folderPath)
        let parent = normalizePath((cur as NSString).deletingLastPathComponent)
        return parent == root || !parent.hasPrefix(root)
    }

    private func goUp() {
        guard isBrowsingSub else { return }
        let cur = normalizePath(currentPath)
        let root = normalizePath(folderPath)
        let parent = normalizePath((cur as NSString).deletingLastPathComponent)
        pendingRestorePath = cur
        navigate(to: upGoesToRoot ? root : parent)
    }

    private func enterSelected() {
        let targetPath = orderedSelected().first ?? selection.selected.first ?? visibleEntries.first?.path
        guard let path = targetPath,
              let entry = visibleEntries.first(where: { $0.path == path }) else { return }
        if entry.isDir {
            enterSub(entry.path)
        } else {
            let targets = orderedSelected().isEmpty ? [entry.path] : orderedSelected()
            for p in targets {
                AppDelegate.shared?.openFile(p)
            }
        }
    }

    /// 纯排序（不碰状态）：既服务「重排当前列表」，也服务「扫描回来先排好再决定要不要赋值」。
    private func sortedEntries(_ list: [Entry]) -> [Entry] {
        list.sorted { a, b in
            FileSorting.areInIncreasingOrder(
                aIsDir: a.isDir, aName: a.name, aSize: a.size, aModDate: a.modDate, aFileType: a.fileType,
                bIsDir: b.isDir, bName: b.name, bSize: b.size, bModDate: b.modDate, bFileType: b.fileType,
                sortBy: sortBy,
                sortOrder: sortOrder
            )
        }
    }

    private func sortEntries() {
        entries = sortedEntries(entries)
        // 排序后同步刷新可见缓存：切换排序方式时 entries 顺序变了，
        // visibleEntries 必须跟着更新，否则键盘导航等读 visibleEntries 的地方会用旧顺序。
        recomputeVisible()
    }

    /// 目录扫描的**串行队列**：同一时刻只跑一次扫描。
    /// 目录被反复改动（例如「下载」正在下载）时轮询会不断触发 load，
    /// 串行化可以避免扫描任务堆叠。
    private static let scanQueue = DispatchQueue(label: "deskisle.portal.scan", qos: .userInitiated)

    /// 目录变化通知的合并窗口（秒）。
    ///
    /// `FolderWatcher` 已经有 0.2s 事件合流 + 0.3s 最小回报间隔，但「事件」与「轮询兜底」
    /// 是两条独立链路，仍可能各报一次；大目录持续变动时也会连着报。
    /// 扫描本来就是全量读，早一轮的结果必被后一轮覆盖，所以合并窗口内只跑最后一次。
    private static let reloadCoalesce: TimeInterval = 0.25

    /// 待执行的重载任务（合并用）。
    @State private var reloadWork: DispatchWorkItem?

    private func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { load() }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reloadCoalesce, execute: work)
    }

    private func load() {
        var base = currentPath.isEmpty ? folderPath : currentPath
        guard !base.isEmpty else { return }

        // 容错：若当前正在浏览的子目录已被外部删除或不再存在，自动回退到分区根目录
        if !currentPath.isEmpty && currentPath != folderPath {
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: currentPath, isDirectory: &isDir) || !isDir.boolValue {
                currentPath = folderPath
                base = folderPath
                selection.clear()
                Toast.shared.show("当前浏览的子目录已不存在", detail: "已自动返回根目录", icon: "folder.badge.gearshape")
            }
        }

        // 上报当前浏览目录：子文件夹浏览是视图内状态，主进程侧看不到；
        // 「自适应宽高」要按用户当前看到的内容度量，必须知道这里正停在哪个目录
        //（进入子文件夹 / 面包屑跳转 / 返回上级都会经过 load）。
        AppDelegate.shared?.setPortalBrowsePath(id, base)
        // 列表要重读了 → 徽标（= 这份列表的条目数）也必须重算。
        // ⚠️ 必须排在 browsePath 上报**之后**：徽标数的是「当前浏览目录」，
        // 顺序反了会拿上一轮的目录去数。
        AppDelegate.shared?.refreshPortalBadge(id)

        scanGeneration += 1
        let generation = scanGeneration

        // **扫描丢到后台线程**：`scanDirectory` 要遍历目录、并对每个条目做一次
        // `FileKinds.meta`（一次 `resourceValues` 系统调用）。目录大（数万条）时
        // 这在主线程上就是几百毫秒到秒级的冻结，而 load 由 2s 的目录轮询驱动、
        // 可能反复触发 —— 表现成「整个桌面每隔几秒卡一下」。
        // 放到后台后主线程只负责最后赋值，滚动与输入不再被卡住。
        PortalView.scanQueue.async {
            let list = PortalView.scanDirectory(base)
            DispatchQueue.main.async {
                // 期间又切了目录 / 又触发了一次 load → 这份结果已经过期，丢弃
                guard generation == scanGeneration else { return }

                // 先排好序再与当前列表比一次：**条目完全一致就别赋值**。
                // `Entry` 是 Equatable（含 size / modDate），一次 O(n) 比较就能判定。
                // 省掉的是 SwiftUI 对整份 ForEach 的 diff —— 大目录每轮几千次比较，
                // 而 FSEvents 常因「某个文件被写大了一点」这类与列表无关的原因回报，
                // 扫出来的结果其实一模一样。
                let next = sortedEntries(list)
                if next != entries {
                    entries = next
                    // entries 更新后立即同步可见缓存，后续所有读 visibleEntries 的地方
                    // 拿到的都是本轮最新结果（reportContext / selection.retain 等）。
                    recomputeVisible()
                    // 刷新后清掉已经不在磁盘上的选中项：留着幽灵路径，
                    // 之后任何「对选中项操作」都会打到不存在的路径上。
                    selection.retain(alive: Set(list.map(\.path)))
                }

                // 若有从子目录返回的待恢复焦点路径，自动恢复高亮并居中滚动
                if let restore = pendingRestorePath {
                    pendingRestorePath = nil
                    let normRestore = normalizePath(restore)
                    if let match = entries.first(where: { normalizePath($0.path) == normRestore }) {
                        selection.click(match.path, visible: visibleEntries.map(\.path))
                        targetScrollPath = match.path
                    }
                }

                // 目录内容变了 → 可见集合与选区都可能跟着变，同步给键盘判据
                reportContext()
            }
        }
    }

    /// 纯函数：只读文件系统、不触碰任何 View 状态，因此可以安全地在后台线程跑。
    private static func scanDirectory(_ base: String) -> [Entry] {
        let fm = FileManager.default
        // 隐藏文件过滤走 `DirectoryScan`（唯一一份口径）：标题栏徽标与自适应高度
        // 都按同一份规则计数，这里再写一遍 `hasPrefix(".")` 就是分叉的开始。
        let names = DirectoryScan.visibleNames(in: base)
        var list: [Entry] = []
        list.reserveCapacity(names.count)
        for name in names {
            let full = (base as NSString).appendingPathComponent(name)
            // 统一取数：一次 resourceValues 拿到「是否目录 / 是否包 / 大小 / 修改时间」。
            // ⚠️ 关键点：`.app` 在 stat 上是目录，但它是**包**，必须当文件对待，
            // 否则它会显示成蓝色文件夹、双击钻进去停在 Foo.app/Contents/MacOS。
            let meta = FileKinds.meta(ofPath: full, fileManager: fm)
            let ext = (name as NSString).pathExtension
            list.append(Entry(name: name, isDir: meta.isDirectory, isPackage: meta.isPackage,
                              size: meta.size, path: full,
                              modDate: meta.modDate, fileType: ext))
        }
        return list
    }
}

// MARK: - 共用：条目图标与菜单措辞（portal 各处复用）

/// 「非目录」条目的 SF Symbol 图标。
///
/// 映射文件夹里原本多处各维护一份**完全相同**的表，改一处漏一处；
/// 这里合并为唯一一份（包的两行是后加的，见 `entryThumb` 的说明）。
private func fileKindIcon(_ ext: String) -> String {
    switch ext.lowercased() {
    case "jpg", "jpeg", "png", "gif", "webp", "heic", "svg", "bmp": return "photo"
    case "pdf": return "doc.richtext"
    case "mp3", "wav", "m4a", "aac", "flac": return "music.note"
    case "mp4", "mov", "avi", "mkv", "m4v": return "film"
    case "zip", "rar", "7z", "tar", "gz", "dmg": return "archivebox"
    case "doc", "docx", "txt", "md", "rtf", "pages": return "doc.text"
    case "xls", "xlsx", "csv", "numbers": return "tablecells"
    case "js", "ts", "tsx", "jsx", "json", "py", "swift", "go", "rs", "java", "c", "cpp", "h", "sh", "yml", "yaml":
        return "chevron.left.forwardslash.chevron.right"
    // 包的两行只是**兜底**：正常情况下包会走 `entryThumb` 取真实图标
    //（见 `AppIcons`），只有系统取不到图标时才落到这里。
    case "app", "appex": return "app.fill"
    case "bundle", "framework", "plugin", "kext", "prefpane", "qlgenerator",
         "mdimporter", "saver", "wdgt", "xpc", "scptd",
         "xcodeproj", "xcworkspace", "playground": return "shippingbox"
    default: return "doc"
    }
}

/// 一个文件条目的缩略图标 —— 映射文件夹的网格 / 列表视图**共用一份**。
///
/// 包（应用等）优先显示**真实图标**（`NSWorkspace`），这与访达一致：
/// 映射文件夹里常常排着一整列应用，用户是靠着应用图标一眼认出目标的 ——
/// 给个统一的方块符号等于把这块信息抹掉。非包文件仍用 SF Symbol，
/// 保持 DeskIsle 自己那套克制的视觉语言。
@ViewBuilder
private func entryThumb(path: String, isDir: Bool, isPackage: Bool,
                        fileType: String, size: CGFloat) -> some View {
    if isPackage, let icon = AppIcons.icon(forPath: path, size: size) {
        Image(nsImage: icon)
            .frame(width: size, height: size)
    } else {
        Image(systemName: isDir ? "folder.fill" : fileKindIcon(fileType))
            .font(.system(size: size))
            .foregroundStyle(isDir ? Color.blue : Color.secondary)
    }
}

/// 右键菜单第一项的措辞。
///
/// 分开措辞是有必要的：对 `.app` 说「打开文件」会让人以为只是预览、不敢点。
private func primaryOpenLabel(isDir: Bool, isPackage: Bool, fileType: String) -> String {
    if isDir { return "在访达中打开" }
    if isPackage { return fileType.lowercased() == "app" ? "打开应用" : "打开" }
    return "打开文件"
}

// MARK: - notes 便签

struct NotesView: View {
    let id: String
    @State private var text: String
    @State private var isTargeted = false

    init(id: String, initialText: String) {
        self.id = id
        _text = State(initialValue: initialText)
    }

    private var lineCount: Int {
        if text.isEmpty { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                NotesTextEditor(text: $text) {
                    AppDelegate.shared?.updateNote(id, text)
                }
                if text.isEmpty {
                    Text("在此输入便签内容…")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 8)
                        .padding(.top, 4)
                        .allowsHitTesting(false)
                }
            }
            .padding(4)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isTargeted ? Color.orange : Color.clear, lineWidth: 2)
            )

            HStack(spacing: 8) {
                Spacer()
                Text("\(text.count) 字符 · \(lineCount) 行")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary.opacity(0.8))

                if !text.isEmpty {
                    Button {
                        exportNote()
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 9))
                            Text("导出")
                                .font(.system(size: 10))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .help("导出为文本文档 (.txt)")
                }
            }
            .padding(.trailing, 8)
            .padding(.bottom, 2)
        }
        .contextMenu {
            Button("拷贝全文") {
                copyAll()
            }
            .disabled(text.isEmpty)

            Button("导出为文本文档 (.txt)...") {
                exportNote()
            }
            .disabled(text.isEmpty)

            Divider()

            Button("清空便签", role: .destructive) {
                clearNote()
            }
            .disabled(text.isEmpty)
        }
        // 拖入文件/文件夹 → 把路径追加进便签（与 Electron 一致）
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            appendDroppedPaths(providers)
            return true
        }
    }

    private func copyAll() {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Toast.shared.show("已拷贝便签全文", icon: "doc.on.doc")
    }

    private func clearNote() {
        guard !text.isEmpty else { return }
        text = ""
        AppDelegate.shared?.updateNote(id, "")
        Toast.shared.show("已清空便签", icon: "trash")
    }

    private func exportNote() {
        guard !text.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "导出便签"
        panel.nameFieldStringValue = "便签.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                Toast.shared.show("便签已成功导出", detail: url.lastPathComponent, icon: "doc.text.fill")
            } catch {
                Toast.shared.show("导出失败", detail: error.localizedDescription, icon: "exclamationmark.triangle.fill")
            }
        }
    }

    private func appendDroppedPaths(_ providers: [NSItemProvider]) {
        // 与 collectPaths 同口径：只把路径追加进便签，不搬文件 → 标记为「应用内已接手」。
        FileDrag.handledInsideApp = true
        var paths: [String] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    paths.append(url.path)
                } else if let url = item as? URL {
                    paths.append(url.path)
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard !paths.isEmpty else { return }
            let addition = (text.isEmpty ? "" : (text.hasSuffix("\n") ? "" : "\n")) + paths.joined(separator: "\n")
            text += addition
            AppDelegate.shared?.updateNote(id, text)
        }
    }
}

/// 支持 URL 与 IP 智能高亮识别、⌘-单击直达与右键快捷操作的原生便签文本编辑器
private struct NotesTextEditor: NSViewRepresentable {
    @Binding var text: String
    var onCommit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = NotesTextView()
        textView.delegate = context.coordinator
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isSelectable = true
        textView.isEditable = true
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.autoresizingMask = [.width]
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.controlAccentColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.updateText(text)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if !context.coordinator.isUpdating && textView.string != text {
            context.coordinator.updateText(text)
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NotesTextEditor
        weak var textView: NSTextView?
        var isUpdating = false

        init(_ parent: NotesTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            isUpdating = true
            parent.text = tv.string
            parent.onCommit()
            detectLinks(in: tv)
            isUpdating = false
        }

        func updateText(_ newText: String) {
            guard let tv = textView else { return }
            isUpdating = true
            tv.string = newText
            detectLinks(in: tv)
            isUpdating = false
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL {
                NSWorkspace.shared.open(url)
                return true
            } else if let str = link as? String, let url = URL(string: str) {
                NSWorkspace.shared.open(url)
                return true
            }
            return false
        }

        func detectLinks(in tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let fullText = storage.string
            let nsString = fullText as NSString
            let fullRange = NSRange(location: 0, length: nsString.length)
            guard fullRange.length > 0 else { return }

            storage.beginEditing()
            storage.removeAttribute(.link, range: fullRange)

            // 1. 系统数据探测器（识别标准 http/https/ftp 链接）
            if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
                let matches = detector.matches(in: fullText, options: [], range: fullRange)
                for match in matches {
                    if let url = match.url {
                        storage.addAttribute(.link, value: url, range: match.range)
                    }
                }
            }

            // 2. 正则探测裸 IPv4 地址与端口（如 192.168.102.193、127.0.0.1:8080）
            let ipPattern = #"\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?::[0-9]{1,5})?\b"#
            if let ipRegex = try? NSRegularExpression(pattern: ipPattern) {
                let ipMatches = ipRegex.matches(in: fullText, options: [], range: fullRange)
                for match in ipMatches {
                    var effectiveRange = NSRange()
                    if storage.attribute(.link, at: match.range.location, effectiveRange: &effectiveRange) == nil {
                        let ipStr = nsString.substring(with: match.range)
                        if let url = URL(string: "http://\(ipStr)") {
                            storage.addAttribute(.link, value: url, range: match.range)
                        }
                    }
                }
            }
            storage.endEditing()
        }
    }
}

private final class NotesTextView: NSTextView {
    override func mouseUp(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let pt = convert(event.locationInWindow, from: nil)
            let idx = characterIndexForInsertion(at: pt)
            if idx < (textStorage?.length ?? 0),
               let link = textStorage?.attribute(.link, at: idx, effectiveRange: nil) {
                let url = (link as? URL) ?? (link as? String).flatMap { URL(string: $0) }
                if let target = url {
                    NSWorkspace.shared.open(target)
                    return
                }
            }
        }
        super.mouseUp(with: event)
    }

    private static let menuTranslations: [String: String] = [
        "Cut": "剪切",
        "Copy": "拷贝",
        "Paste": "粘贴",
        "Paste and Match Style": "粘贴并匹配样式",
        "Delete": "删除",
        "Select All": "全选",
        "Open Link": "在浏览器中打开链接",
        "Open With": "打开方式",
        "Copy Link": "拷贝链接地址",
        "Share...": "共享...",
        "Share": "共享",
        "Font": "字体",
        "Show Fonts": "显示字体",
        "Bold": "粗体",
        "Italic": "斜体",
        "Underline": "下划线",
        "Outline": "轮廓",
        "Styles...": "样式...",
        "Show Colors": "显示颜色",
        "Copy Style": "拷贝样式",
        "Paste Style": "粘贴样式",
        "Bigger": "增大",
        "Smaller": "减小",
        "Kern": "字距",
        "Ligatures": "连字",
        "Baseline": "基线",
        "Use Default": "使用默认",
        "Use None": "不使用",
        "Tighten": "紧缩",
        "Loosen": "稀疏",
        "Use All": "全部使用",
        "Spelling and Grammar": "拼写和语法",
        "Show Spelling and Grammar": "显示拼写和语法",
        "Check Document Now": "立即检查文稿",
        "Check Spelling While Typing": "键入时检查拼写",
        "Check Grammar With Spelling": "检查拼写和语法",
        "Correct Spelling Automatically": "自动纠正拼写",
        "Substitutions": "替换",
        "Show Substitutions": "显示替换",
        "Smart Copy/Paste": "智能拷贝/粘贴",
        "Smart Quotes": "智能引号",
        "Smart Dashes": "智能破折号",
        "Smart Links": "智能链接",
        "Data Detectors": "数据检测器",
        "Text Replacement": "文本替换",
        "Transformations": "转换",
        "Make Upper Case": "大写",
        "Make Lower Case": "小写",
        "Capitalize": "首字母大写",
        "Speech": "语音",
        "Start Speaking": "开始朗读",
        "Stop Speaking": "停止朗读",
        "Layout Orientation": "文字方向",
        "Horizontal": "水平",
        "Vertical": "垂直",
        "AutoFill": "自动填充",
        "AutoFill Contact Info": "自动填充联系人信息",
        "AutoFill Passwords": "自动填充密码",
        "Services": "服务",
        "Quick Look Attachment": "快速查看附件",
        "Look Up": "查询",
        "Search with": "搜索"
    ]

    private static func localizeMenu(_ menu: NSMenu) {
        for item in menu.items {
            let t = item.title.trimmingCharacters(in: .whitespaces)
            if let zh = menuTranslations[t] {
                item.title = zh
            } else if t.hasPrefix("Search with ") {
                let engine = t.dropFirst("Search with ".count)
                item.title = "使用 \(engine) 搜索"
            } else if t.hasPrefix("Look Up ") {
                let term = t.dropFirst("Look Up ".count)
                item.title = "查询 \(term)"
            }
            if let sub = item.submenu {
                localizeMenu(sub)
            }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let pt = convert(event.locationInWindow, from: nil)
        let idx = characterIndexForInsertion(at: pt)
        let targetLink: URL? = {
            if idx < (textStorage?.length ?? 0),
               let link = textStorage?.attribute(.link, at: idx, effectiveRange: nil) {
                return (link as? URL) ?? (link as? String).flatMap { URL(string: $0) }
            }
            return nil
        }()

        let m = super.menu(for: event) ?? NSMenu()

        // 1. 如果右键落在链接上：剔除系统生成的重复英文项，并在顶部置入原生中文链接动作
        if let target = targetLink {
            m.items.removeAll { item in
                item.title == "Open Link" || item.title == "Copy Link" ||
                item.title == "打开链接" || item.title == "拷贝链接"
            }
            let openItem = NSMenuItem(title: "在浏览器中打开链接", action: #selector(openLinkAction(_:)), keyEquivalent: "")
            openItem.target = self
            openItem.representedObject = target
            m.insertItem(openItem, at: 0)

            let copyItem = NSMenuItem(title: "拷贝链接地址", action: #selector(copyLinkAction(_:)), keyEquivalent: "")
            copyItem.target = self
            copyItem.representedObject = target.absoluteString
            m.insertItem(copyItem, at: 1)

            m.insertItem(NSMenuItem.separator(), at: 2)
        }

        // 2. 注入便签核心功能（拷贝全文、导出、清空便签），紧随基础剪贴操作之后
        if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let insertIdx: Int = {
                if let pIdx = m.items.firstIndex(where: { $0.action == #selector(NSText.paste(_:)) }) {
                    return pIdx + 1
                }
                return m.items.count
            }()

            let noteItems: [NSMenuItem] = [
                NSMenuItem.separator(),
                NSMenuItem(title: "拷贝全文", action: #selector(copyAllAction(_:)), keyEquivalent: ""),
                NSMenuItem(title: "导出为文本文档 (.txt)...", action: #selector(exportNoteAction(_:)), keyEquivalent: ""),
                NSMenuItem.separator(),
                NSMenuItem(title: "清空便签", action: #selector(clearNoteAction(_:)), keyEquivalent: "")
            ]
            for (offset, item) in noteItems.enumerated() {
                item.target = self
                let dest = min(insertIdx + offset, m.items.count)
                m.insertItem(item, at: dest)
            }
        }

        // 3. 递归汉化所有原生系统菜单项（含 Font/Spelling/Speech/AutoFill 等全部子菜单）
        Self.localizeMenu(m)

        // 4. 去除多余与连续重复的分隔线
        var cleanedItems: [NSMenuItem] = []
        var prevWasSep = true
        for item in m.items {
            if item.isSeparatorItem {
                if !prevWasSep { cleanedItems.append(item) }
                prevWasSep = true
            } else {
                cleanedItems.append(item)
                prevWasSep = false
            }
        }
        if cleanedItems.last?.isSeparatorItem == true {
            cleanedItems.removeLast()
        }
        m.items = cleanedItems

        return m
    }

    @objc private func copyAllAction(_ sender: NSMenuItem) {
        guard !string.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        Toast.shared.show("已拷贝便签全文", icon: "doc.on.doc")
    }

    @objc private func clearNoteAction(_ sender: NSMenuItem) {
        guard !string.isEmpty else { return }
        string = ""
        didChangeText()
        Toast.shared.show("已清空便签", icon: "trash")
    }

    @objc private func openLinkAction(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func copyLinkAction(_ sender: NSMenuItem) {
        guard let str = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(str, forType: .string)
    }

    @objc private func exportNoteAction(_ sender: NSMenuItem) {
        let textContent = string
        guard !textContent.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "导出便签"
        panel.nameFieldStringValue = "便签.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try textContent.write(to: url, atomically: true, encoding: .utf8)
                Toast.shared.show("便签已成功导出", detail: url.lastPathComponent, icon: "doc.text.fill")
            } catch {
                Toast.shared.show("导出失败", detail: error.localizedDescription, icon: "exclamationmark.triangle.fill")
            }
        }
    }
}

// MARK: - todo 待办

struct TodoView: View {
    let id: String
    @ObservedObject var config: Config
    @State private var draft = ""
    @State private var isTargeted = false

    private var todos: [TodoVM] { config.todos(of: id) }
    private var uncompletedTodos: [TodoVM] { todos.filter { !$0.completed } }
    private var completedTodos: [TodoVM] { todos.filter { $0.completed } }
    private var hasCompleted: Bool { !completedTodos.isEmpty }
    private var isCompletedExpanded: Bool {
        config.bool("isCompletedExpanded", of: id)
    }
    private var filterMode: String {
        config.str("todoFilterMode", of: id) ?? "all"
    }

    private var filteredUncompleted: [TodoVM] {
        switch filterMode {
        case "high": return uncompletedTodos.filter { $0.priority == "high" }
        default: return uncompletedTodos
        }
    }

    private var filteredCompleted: [TodoVM] {
        switch filterMode {
        case "active": return []
        case "high": return completedTodos.filter { $0.priority == "high" }
        default: return completedTodos
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 添加待办输入框固定在顶部（所有待办列表之上）
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 10)).foregroundStyle(.tertiary)
                TextField("添加待办，回车确认", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit {
                        AppDelegate.shared?.addTodo(id, text: draft)
                        draft = ""
                    }
                if hasCompleted {
                    Button {
                        AppDelegate.shared?.clearCompletedTodos(id)
                    } label: {
                        Image(systemName: "checkmark.circle.badge.xmark")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("清除已完成待办")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            // 筛选视图（全部 / 未完成 / 高优）
            HStack(spacing: 4) {
                todoFilterButton("全部", mode: "all")
                todoFilterButton("未完成", mode: "active")
                todoFilterButton("高优", mode: "high")
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)

            Divider().opacity(0.5)
            if filteredUncompleted.isEmpty && filteredCompleted.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checklist").font(.system(size: 24)).foregroundStyle(.secondary)
                    Text("暂无待办").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(filteredUncompleted) { TodoRow(partitionId: id, todo: $0) }

                        if !filteredCompleted.isEmpty {
                            Button {
                                withAnimation(.easeInOut(duration: 0.16)) {
                                    let next = !isCompletedExpanded
                                    AppDelegate.shared?.updatePartition(id, key: "isCompletedExpanded", value: next)
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: isCompletedExpanded ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 9, weight: .bold))
                                    Text("已完成 (\(filteredCompleted.count))")
                                        .font(.system(size: 11, weight: .medium))
                                    Spacer()
                                }
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if isCompletedExpanded {
                                ForEach(filteredCompleted) { TodoRow(partitionId: id, todo: $0) }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .contextMenu {
                    if hasCompleted {
                        Button("清除已完成待办") {
                            AppDelegate.shared?.clearCompletedTodos(id)
                        }
                    }
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            addTodosFromFiles(providers)
            return true
        }
    }

    private func todoFilterButton(_ title: String, mode: String) -> some View {
        Button {
            AppDelegate.shared?.updatePartition(id, key: "todoFilterMode", value: mode)
        } label: {
            Text(title)
                .font(.system(size: 10, weight: filterMode == mode ? .semibold : .regular))
                .foregroundStyle(filterMode == mode ? Color.primary : Color.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(filterMode == mode ? Color.accentColor.opacity(0.18) : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    private func addTodosFromFiles(_ providers: [NSItemProvider]) {
        // 与 collectPaths 同口径：只凭文件生成待办，不搬文件 → 标记为「应用内已接手」。
        FileDrag.handledInsideApp = true
        var paths: [String] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    paths.append(url.path)
                } else if let url = item as? URL {
                    paths.append(url.path)
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            for p in paths {
                let name = (p as NSString).lastPathComponent
                AppDelegate.shared?.addTodo(id, text: "处理: \(name)")
            }
        }
    }
}

private struct TodoRow: View {
    let partitionId: String
    let todo: TodoVM
    @State private var hovering = false
    @State private var isEditing = false
    @State private var editText = ""
    @State private var isDropTargeted = false
    @FocusState private var editFocused: Bool

    private var priorityColor: Color {
        switch todo.priority {
        case "high": return .red
        case "low": return .secondary
        default: return .orange
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Button { AppDelegate.shared?.toggleTodo(partitionId, todo.id) } label: {
                Image(systemName: todo.completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(todo.completed ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)

            if isEditing {
                TextField("", text: $editText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($editFocused)
                    .onSubmit { commitEdit() }
                    .onExitCommand { cancelEdit() }
            } else {
                Text(todo.text)
                    .font(.system(size: 13))
                    .strikethrough(todo.completed)
                    .foregroundStyle(todo.completed ? Color.secondary : Color.primary)
                    .lineLimit(2)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { startEdit() }
            }

            Spacer(minLength: 0)

            // 优先级小圆点常驻展示（可直接点击切换优先级）
            Button { AppDelegate.shared?.cycleTodoPriority(partitionId, todo.id) } label: {
                Circle().fill(priorityColor).frame(width: 7, height: 7)
            }
            .buttonStyle(.plain)
            .help("优先级：\(todo.priority)，点击切换")

            if hovering {
                Button { AppDelegate.shared?.removeTodo(partitionId, todo.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("删除该条")
            }
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .overlay(
            VStack {
                if isDropTargeted {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(height: 2)
                }
                Spacer()
            }
        )
        .onHover { hovering = $0 }
        .onDrag {
            NSItemProvider(object: todo.id as NSString)
        }
        .onDrop(of: [.text], isTargeted: $isDropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { item, _ in
                if let sourceId = item as? String {
                    DispatchQueue.main.async {
                        AppDelegate.shared?.moveTodo(partitionId, from: sourceId, to: todo.id)
                    }
                }
            }
            return true
        }
        .contextMenu {
            Button(isEditing ? "完成编辑" : "编辑待办") {
                if isEditing { commitEdit() } else { startEdit() }
            }
            Button("切换完成状态") { AppDelegate.shared?.toggleTodo(partitionId, todo.id) }
            Menu("设置优先级") {
                Button("🔴 高优先级") { AppDelegate.shared?.setTodoPriority(partitionId, todo.id, priority: "high") }
                Button("🟠 中优先级") { AppDelegate.shared?.setTodoPriority(partitionId, todo.id, priority: "medium") }
                Button("⚪ 低优先级") { AppDelegate.shared?.setTodoPriority(partitionId, todo.id, priority: "low") }
            }
            Divider()
            Button("清除已完成待办") { AppDelegate.shared?.clearCompletedTodos(partitionId) }
            Divider()
            Button("删除该条", role: .destructive) { AppDelegate.shared?.removeTodo(partitionId, todo.id) }
        }
    }

    private func startEdit() {
        AppDelegate.shared?.activatePartition(partitionId)
        editText = todo.text
        isEditing = true
        DispatchQueue.main.async {
            editFocused = true
        }
    }

    private func commitEdit() {
        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != todo.text {
            AppDelegate.shared?.setTodoText(partitionId, todo.id, trimmed)
        }
        isEditing = false
    }

    private func cancelEdit() {
        isEditing = false
    }
}

// MARK: - 顶栏

/// 顶栏内容：新建 / 搜索 / 显隐 ｜ 顶部 / 左侧 / 右侧 ｜ 隐藏导航栏 / 设置 / 退出。
///
/// ⚠️ 「锁定」按钮已**刻意从顶栏移除**（2026-09-30）：它是个**状态型开关**（点了就长期生效，
/// 且按屏独立），却混在一排**动作型按钮**（新建 / 搜索 / 对齐）里 —— 用户不小心点到会以为
/// 「分区怎么突然拖不动了」，而且顶栏没有空间显示「本屏已锁定」这种持续状态。
/// 锁定功能本身**保留**，入口收敛到托盘菜单「锁定分区位置」（同样按屏、且菜单里能看到勾选态），
/// 分区标题栏也仍有一枚分区级锁定按钮。
struct TopBarView: View {
    @ObservedObject var config: Config
    /// 本顶栏所属显示器：显隐按钮与对齐高亮只反映**本屏**状态（多屏分别控制）。
    let screenID: CGDirectDisplayID
    let onToggleHide: () -> Void
    let onAlign: (String) -> Void
    let onAdd: () -> Void
    let onSettings: () -> Void
    let onHideTopBar: () -> Void
    let onQuit: () -> Void

    /// 本屏的对齐模式 —— 多显示器下每屏独立设置，顶栏高亮只反映本屏。
    private var alignMode: String { config.alignMode(forScreen: screenID) }
    /// 本屏分区的显隐态（幽灵模式，按屏独立）—— 读 @Published hiddenScreens，
    /// 眼睛按钮高亮随切换刷新；不同显示器的顶栏互不影响。
    private var hidden: Bool { config.isScreenHidden(screenID) }

    var body: some View {
        // spacing 12 → 10、左右各 16 → 14：顶栏按钮从 11 个增至 13 个后再按 12pt 排布，
        // 理想宽度会超过窗口固定宽度，SwiftUI 便去压缩品牌名 → "DeskIsle" 被拆成两行。
        // 这里先把内容收紧，窗口宽度另由 TopBarPanel 按内容自适应（见 refreshFit）。
        HStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(DeskFont.glyph)
                .foregroundStyle(Color.primary)
            Text("DeskIsle")
                .font(DeskFont.header)
                .monospacedDigit()
                // fixedSize(horizontal:) 是关键：不允许横向压缩，文本要么完整显示、
                // 要么由外层撑宽窗口 —— 但绝不会退化成换行/省略号。
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer()

            // 组 1：搜索 / 新建 / 显示隐藏
            // ⚠️ 搜索在新建**之前**（2026-09-30 用户要求）：这两个都是高频入口，
            // 但「先找到已有内容」的频次高于「新建一个」，把搜索放在最外侧更顺手。
            // （「锁定」已移除，理由见本类型文档注释：状态型开关不该混在动作型按钮里）
            topButton("magnifyingglass", "全局搜索（\(AppDelegate.shared?.searchShortcut.display ?? "⌘⌥F")）",
                      active: false) {
                AppDelegate.shared?.openGlobalSearch()
            }
            topButton("plus", "新建分区", active: false) { onAdd() }
            topButton(hidden ? "eye.slash" : "eye",
                      hidden ? "显示分区" : "隐藏分区（仅隐藏，不退出）",
                      active: !hidden) { onToggleHide() }

            divider

            // 组 2：分区排版对齐（顶部 / 左侧 / 右侧 / 网格规整）
            topButton("arrow.up.to.line", "顶部横向排序", active: alignMode == "top") { setAlign("top") }
            topButton("arrow.left.to.line", "左侧纵向对齐", active: alignMode == "left") { setAlign("left") }
            topButton("arrow.right.to.line", "右侧纵向对齐", active: alignMode == "right") { setAlign("right") }
            topButton("square.grid.2x2", "网格规整排列", active: alignMode == "grid") { setAlign("grid") }

            divider

            // 组 3：显示导航栏 / 设置 / 退出
            topButton("chevron.up", "隐藏顶部导航栏", active: false) { onHideTopBar() }
            topButton("gearshape", "全局设置", active: false) { onSettings() }
            topButton("power", "退出 DeskIsle", active: false) { onQuit() }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
        )
    }

    private func setAlign(_ mode: String) {
        // align(mode:) 会持久化 alignMode 到 config，@ObservedObject 自动刷新高亮态
        onAlign(mode)
    }

    /// 组间分割竖线。
    ///
    /// ⚠️ 必须用**语义色 `Color.primary`**，不能写 `Color.white.opacity(...)`：
    /// 胶囊背景是 `.ultraThinMaterial`（跟随系统外观），浅色外观下「白线叠浅底」等于隐形 ——
    /// 实测浅色下白 20% 只把底色从 237 抬到 240.5（+3/255 ≈ 1.2% 对比度），肉眼看不见，
    /// 于是四组按钮糊成一片。改用 primary 后：深色外观 = 白线（观感与原来完全一致），
    /// 浅色外观 = 一道深灰细线（237 → 190），两种外观下都真的「分开了」。
    private var divider: some View {
        Rectangle().fill(Color.primary.opacity(0.2))
            .frame(width: 1, height: 16)
            .fixedSize()   // 竖线被压缩会消失，导致两组按钮糊在一起
    }

    /// 顶栏图标按钮。
    ///
    /// `active`：高亮态（当前生效的对齐模式 / 分区是否可见 / 是否锁定）。
    private func topButton(_ icon: String, _ help: String, active: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(DeskFont.topIcon)
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .fixedSize()   // 图标不允许被压缩：宁可顶栏变宽，也不要图标叠在一起误点
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - 宿主窗口是否 key（选中高亮的强 / 弱两档）

/// 订阅某个 `NSWindow` 的 key 状态。
///
/// ⚠️ 不用 SwiftUI 的 `@Environment(\.controlActiveState)`：本应用是 **AppKit 宿主**
/// （SwiftUI 视图塞进 `NSPanel` 的 `NSHostingView`），没有 Scene 生命周期，那个环境值在
/// 这种托管方式下不会随窗口切换更新 —— 实测过，恒为 `.active`，等于没分档。
private final class WindowKeyWatcher: NSObject, ObservableObject {
    @Published private(set) var isKey = false
    private weak var bound: NSWindow?

    /// 幂等：同一个窗口绑一次就够（`updateNSView` 每次重绘都会回调）。
    func bind(_ w: NSWindow) {
        guard bound !== w else { return }
        bound = w
        isKey = w.isKeyWindow
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(becameKey(_:)),
                       name: NSWindow.didBecomeKeyNotification, object: w)
        nc.addObserver(self, selector: #selector(resignedKey(_:)),
                       name: NSWindow.didResignKeyNotification, object: w)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func becameKey(_: Notification) { isKey = true }
    @objc private func resignedKey(_: Notification) { isKey = false }
}

/// 零尺寸探针：只为把宿主 `NSWindow` 取出来一次。
private struct WindowKeyProbe: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        v.isHidden = true       // 不参与绘制，也不抢任何点击
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // 第一帧视图可能还没挂进宿主窗口，下一轮 RunLoop 再试一次。
        if let w = nsView.window {
            onResolve(w)
        } else {
            DispatchQueue.main.async { [weak nsView] in
                guard let w = nsView?.window else { return }
                onResolve(w)
            }
        }
    }
}
