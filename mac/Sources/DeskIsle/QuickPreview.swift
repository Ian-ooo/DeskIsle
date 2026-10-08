import SwiftUI
import AppKit
import PDFKit
import DeskIsleCore

/// 预览内容载荷类型（图片 / PDF / 纯文本代码 / 文件夹 / 通用文件）
enum PreviewPayload {
    case image(NSImage, pixelSize: NSSize)
    case pdf(NSImage, pageCount: Int, pixelSize: NSSize)
    case text(content: String, lines: Int)
    case folder(name: String, itemCount: Int, icon: NSImage)
    case generic(icon: NSImage, kindDescription: String)
}

/// 预览数据模型
struct PreviewItem: Equatable {
    let path: String
    let name: String
    let bytes: Int64
    let payload: PreviewPayload
    let modifiedDate: Date?

    static func == (lhs: PreviewItem, rhs: PreviewItem) -> Bool {
        lhs.path == rhs.path
    }
}

/// 快速预览动态数据源（支持在原有窗口内就地热替换与平滑动画）
final class QuickPreviewModel: ObservableObject {
    @Published var item: PreviewItem?
}

/// 快速预览浮层 Panel
final class QuickPreviewPanel: NSPanel {

    private var keyMonitor: Any?
    var onClose: (() -> Void)?

    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .modalPanel
        isMovableByWindowBackground = true
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            // Esc（53）/ 空格键（49）都可关闭
            if ev.keyCode == 53 || ev.keyCode == 49 {
                self?.close()
                return nil
            }
            // 方向键（123 左, 124 右, 125 下, 126 上）连续浏览上一个/下一个文件
            let dir: String? = {
                switch ev.keyCode {
                case 126: return "up"
                case 125: return "down"
                case 123: return "left"
                case 124: return "right"
                default:  return nil
                }
            }()
            if let direction = dir {
                if let partID = QuickPreview.shared.activePartitionID ?? AppDelegate.shared?.raisedPanelID {
                    NotificationCenter.default.post(
                        name: .portalArrowNavigate,
                        object: partID,
                        userInfo: ["direction": direction, "shift": false]
                    )
                    return nil
                }
            }
            return ev
        }
    }

    override func close() {
        super.close()
        onClose?()
    }

    deinit {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 快速预览管理器（支持图片、PDF 文档、文本与代码、文件夹及通用文件的原生全能预览）
final class QuickPreview {

    static let shared = QuickPreview()
    private init() {}

    private let model = QuickPreviewModel()
    private var panel: QuickPreviewPanel?
    private var loadGeneration = 0
    public private(set) var activePartitionID: String? = nil

    var isShowing: Bool { panel != nil && panel?.isVisible == true }
    var panelFrame: NSRect? { panel?.frame }
    var hostPath: String { model.item?.path ?? "" }

    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "json", "js", "jsx", "ts", "tsx", "swift",
        "py", "sh", "bash", "zsh", "c", "cpp", "h", "hpp", "css", "scss",
        "html", "htm", "xml", "yaml", "yml", "log", "csv", "conf", "ini",
        "sql", "env", "toml", "properties", "gradle", "dart", "rs", "go",
        "java", "kt", "rb", "php", "strings", "gitignore", "lock", "plist"
    ]

    /// 切换预览（若已打开该文件则关闭，对齐原生空格快速查看）
    func toggle(_ path: String, partitionID: String? = nil) {
        if let pid = partitionID { self.activePartitionID = pid }
        if isShowing && hostPath == path {
            close()
        } else {
            show(path, partitionID: partitionID)
        }
    }

    /// 预览文件或文件夹
    @discardableResult
    func show(_ path: String, partitionID: String? = nil) -> Bool {
        if let pid = partitionID { self.activePartitionID = pid }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return false }

        let name = (path as NSString).lastPathComponent
        let ext = (path as NSString).pathExtension.lowercased()
        let url = URL(fileURLWithPath: path)
        var bytes: Int64 = 0
        var modDate: Date?
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
            if let n = attrs[.size] as? NSNumber { bytes = n.int64Value }
            modDate = attrs[.modificationDate] as? Date
        }

        loadGeneration += 1
        let gen = loadGeneration

        // 1. 文件夹与应用程序包预览
        if isDir.boolValue {
            let isApp = ext == "app"
            let icon = NSWorkspace.shared.icon(forFile: path)
            if isApp {
                let item = PreviewItem(path: path, name: name, bytes: bytes,
                                       payload: .generic(icon: icon, kindDescription: "应用程序"),
                                       modifiedDate: modDate)
                self.present(item)
                return true
            }

            DispatchQueue.global(qos: .userInitiated).async {
                let count = DirectoryScan.visibleNames(in: path).count
                let item = PreviewItem(path: path, name: name, bytes: bytes,
                                       payload: .folder(name: name, itemCount: count, icon: icon),
                                       modifiedDate: modDate)
                DispatchQueue.main.async {
                    guard gen == self.loadGeneration else { return }
                    self.present(item)
                }
            }
            return true
        }

        // 2. PDF 文档原生快速查看
        if ext == "pdf" {
            DispatchQueue.global(qos: .userInitiated).async {
                guard let doc = PDFDocument(url: url),
                      let page = doc.page(at: 0) else {
                    let icon = NSWorkspace.shared.icon(forFile: path)
                    let item = PreviewItem(path: path, name: name, bytes: bytes,
                                           payload: .generic(icon: icon, kindDescription: "PDF 文档"),
                                           modifiedDate: modDate)
                    DispatchQueue.main.async {
                        guard gen == self.loadGeneration else { return }
                        self.present(item)
                    }
                    return
                }
                let box = page.bounds(for: .mediaBox)
                let renderSize = NSSize(width: max(400, min(800, box.width * 1.5)),
                                        height: max(500, min(1000, box.height * 1.5)))
                let thumb = page.thumbnail(of: renderSize, for: .mediaBox)
                let item = PreviewItem(path: path, name: name, bytes: bytes,
                                       payload: .pdf(thumb, pageCount: doc.pageCount, pixelSize: box.size),
                                       modifiedDate: modDate)
                DispatchQueue.main.async {
                    guard gen == self.loadGeneration else { return }
                    self.present(item)
                }
            }
            return true
        }

        // 3. 文本与代码文件快速查看
        if Self.textExtensions.contains(ext) {
            DispatchQueue.global(qos: .userInitiated).async {
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                      let str = String(data: data.prefix(256 * 1024), encoding: .utf8) ??
                                String(data: data.prefix(256 * 1024), encoding: .ascii) else {
                    let icon = NSWorkspace.shared.icon(forFile: path)
                    let item = PreviewItem(path: path, name: name, bytes: bytes,
                                           payload: .generic(icon: icon, kindDescription: "文本文件"),
                                           modifiedDate: modDate)
                    DispatchQueue.main.async {
                        guard gen == self.loadGeneration else { return }
                        self.present(item)
                    }
                    return
                }
                let lineCount = str.split(separator: "\n", omittingEmptySubsequences: false).count
                let item = PreviewItem(path: path, name: name, bytes: bytes,
                                       payload: .text(content: str, lines: lineCount),
                                       modifiedDate: modDate)
                DispatchQueue.main.async {
                    guard gen == self.loadGeneration else { return }
                    self.present(item)
                }
            }
            return true
        }

        // 4. 图片文件快速查看
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "ico", "icns", "svg"]
        if imageExts.contains(ext) {
            DispatchQueue.global(qos: .userInitiated).async {
                guard let img = NSImage(contentsOfFile: path), img.isValid else {
                    let icon = NSWorkspace.shared.icon(forFile: path)
                    let item = PreviewItem(path: path, name: name, bytes: bytes,
                                           payload: .generic(icon: icon, kindDescription: "图像文件"),
                                           modifiedDate: modDate)
                    DispatchQueue.main.async {
                        guard gen == self.loadGeneration else { return }
                        self.present(item)
                    }
                    return
                }
                let size = img.size
                let item = PreviewItem(path: path, name: name, bytes: bytes,
                                       payload: .image(img, pixelSize: size),
                                       modifiedDate: modDate)
                DispatchQueue.main.async {
                    guard gen == self.loadGeneration else { return }
                    self.present(item)
                }
            }
            return true
        }

        // 5. 通用其他文件（视频/音频/压缩包/Office等，展示完整文件信息卡）
        let icon = NSWorkspace.shared.icon(forFile: path)
        let kind = (try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey]))?.localizedTypeDescription ?? "文件"
        let item = PreviewItem(path: path, name: name, bytes: bytes,
                               payload: .generic(icon: icon, kindDescription: kind),
                               modifiedDate: modDate)
        present(item)
        return true
    }

    func close() {
        panel?.close()
        panel = nil
        model.item = nil
        if let pid = activePartitionID {
            AppDelegate.shared?.activatePartition(pid)
        }
        activePartitionID = nil
    }

    private func present(_ item: PreviewItem) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let limit = screen.visibleFrame.insetBy(dx: 60, dy: 60).size

        let winSize: NSSize
        switch item.payload {
        case .image(_, let pixelSize):
            winSize = Self.fittedWindow(pixelSize: pixelSize, limit: limit)
        case .pdf(_, _, let pixelSize):
            winSize = Self.fittedWindow(pixelSize: pixelSize, limit: limit)
        case .text:
            winSize = NSSize(width: min(640, limit.width), height: min(480, limit.height))
        case .folder:
            winSize = NSSize(width: 380, height: 230)
        case .generic:
            winSize = NSSize(width: 400, height: 250)
        }

        // 若当前预览窗口已处于显示状态：就地热更新数据源并平滑重调尺寸，绝不销毁重造窗口导致闪烁
        if let p = panel, p.isVisible {
            model.item = item
            let curFrame = p.frame
            let newX = curFrame.midX - winSize.width / 2
            let newY = curFrame.midY - winSize.height / 2
            let vf = screen.visibleFrame
            let clampedX = max(vf.minX + 16, min(newX, vf.maxX - winSize.width - 16))
            let clampedY = max(vf.minY + 16, min(newY, vf.maxY - winSize.height - 16))
            let newFrame = NSRect(x: clampedX, y: clampedY, width: winSize.width, height: winSize.height)
            p.setFrame(newFrame, display: true, animate: true)
            // ⚠️ 实时连播时只更新画面并置于前台（orderFront），绝不强制抢夺 Key Window，
            // 确保用户正在操作的分区保持激活、选中高亮完整展示。
            p.orderFront(nil)
            return
        }

        // 首次打开：创建窗口并居中展示
        model.item = item
        let view = QuickPreviewView(model: model) { [weak self] in self?.close() }
        let p = QuickPreviewPanel(size: winSize)
        p.contentView = NSHostingView(rootView: view)
        p.onClose = { [weak self] in
            self?.panel = nil
            self?.model.item = nil
            self?.activePartitionID = nil
        }
        let origin = NSPoint(x: screen.visibleFrame.midX - winSize.width / 2,
                             y: screen.visibleFrame.midY - winSize.height / 2)
        p.setFrameOrigin(origin)
        panel = p
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func fittedWindow(pixelSize: NSSize, limit: NSSize) -> NSSize {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return NSSize(width: 420, height: 300) }
        let chrome = NSSize(width: 48, height: 96)
        let availW = max(320, limit.width - chrome.width)
        let availH = max(240, limit.height - chrome.height)
        let scale = min(availW / pixelSize.width, availH / pixelSize.height, 1.0)
        let w = max(320, min(pixelSize.width * scale, availW))
        let h = max(240, min(pixelSize.height * scale, availH))
        return NSSize(width: w + chrome.width, height: h + chrome.height)
    }
}

/// 快速预览视图
struct QuickPreviewView: View {
    @ObservedObject var model: QuickPreviewModel
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.95))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: Color.black.opacity(0.24), radius: 24, x: 0, y: 8)

            if let item = model.item {
                VStack(spacing: 10) {
                    content(for: item)

                    VStack(spacing: 3) {
                        Text(item.name)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        footer(for: item)
                    }
                    .padding(.bottom, 2)
                }
                .padding(16)
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.primary.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .padding(12)
            .help("关闭预览 (Esc / Space)")
        }
    }

    @ViewBuilder
    private func content(for item: PreviewItem) -> some View {
        switch item.payload {
        case .image(let image, _):
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

        case .pdf(let image, let pageCount, _):
            VStack(spacing: 6) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        Text("PDF · 共 \(pageCount) 页")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(8)
                    }
            }

        case .text(let content, let lines):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(lines) 行文本")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(content, forType: .string)
                        Toast.shared.show("已复制文本内容", icon: "doc.on.doc")
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "doc.on.doc").font(.system(size: 9))
                            Text("复制全部").font(.system(size: 10))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 4)

                ScrollView([.horizontal, .vertical]) {
                    Text(content)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(10)
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .folder(_, let itemCount, let icon):
            VStack(spacing: 10) {
                Spacer()
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 68, height: 68)
                Text("\(itemCount) 个项目")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 12) {
                    Button("在访达中显示") {
                        AppDelegate.shared?.revealInFinder(item.path)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .generic(let icon, let kindDesc):
            VStack(spacing: 10) {
                Spacer()
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 68, height: 68)
                Text(FileKinds.isArchive(item.path) ? "压缩归档文件" : kindDesc)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 12) {
                    if FileKinds.isArchive(item.path) {
                        Button("解压缩到当前目录") {
                            let partID = QuickPreview.shared.activePartitionID ?? AppDelegate.shared?.raisedPanelID ?? ""
                            AppDelegate.shared?.unarchivePath(item.path, in: partID)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    } else {
                        Button("用默认应用打开") {
                            AppDelegate.shared?.openFile(item.path)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }

                    Button("在访达中显示") {
                        AppDelegate.shared?.revealInFinder(item.path)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func footer(for item: PreviewItem) -> some View {
        switch item.payload {
        case .image(_, let pixelSize):
            Text("\(Int(pixelSize.width)) × \(Int(pixelSize.height))　·　\(Self.sizeText(item.bytes))")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        case .pdf(_, let pageCount, let pixelSize):
            Text("\(Int(pixelSize.width)) × \(Int(pixelSize.height))　·　\(pageCount) 页　·　\(Self.sizeText(item.bytes))")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        case .text(_, let lines):
            Text("\(lines) 行　·　\(Self.sizeText(item.bytes))")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        case .folder(_, let itemCount, _):
            Text("\(itemCount) 项\(dateString(item.modifiedDate))")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        case .generic:
            Text("\(Self.sizeText(item.bytes))\(dateString(item.modifiedDate))")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func dateString(_ date: Date?) -> String {
        guard let d = date else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "　·　修改于 " + formatter.string(from: d)
    }

    private static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
