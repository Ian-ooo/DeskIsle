import SwiftUI
import AppKit
import DeskIsleCore
import DeskIsleLayout   // PartitionLook：分区外观的默认/值域/模糊档位（三端同口径）

// MARK: - 模态面板统一尺寸

/// 「新建分区」与「全局设置（偏好设置）」两个面板统一使用的宽高。
///
/// 此前两者不一致（新建分区 420×580、全局设置 440×560），同一入口下的面板大小不一，
/// 切换时会有明显的尺寸跳变。这里收敛为**唯一常量**，窗口与内容两侧都从它取值，
/// 避免以后再各自漂移。
enum ModalPanelSize {
    static let width: CGFloat = 460
    static let height: CGFloat = 620
}

// MARK: - 基础视觉原子组件

/// 现代 macOS 风格的分组卡片容器
private struct FormCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

/// 现代 macOS 设置项行组件
private struct FormRow<Content: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(iconColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                if let sub = subtitle {
                    Text(sub)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// 分组大标题
private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
    }
}

/// 设置面板「功能块」：小标题 + 卡片区域的标准组合。
/// 统一封装以保证各块标题与区域的间距、对齐、层级完全一致 ——
/// 曾经各块自行写 `VStack { SectionHeader; FormCard }`，导致内边距漏加在某一块上、
/// 出现「只有最后一块有左右边距」的错位。
private struct SettingsBlock<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: title)
            FormCard { content }
        }
    }
}

/// 分区外观的**滑杆行**（背景不透明度 / 圆角 / 模糊共用）。
///
/// 滑杆右侧的数值标签必须即时显示当前值：不给反馈的话用户拖到一半松手，
/// 只能靠肉眼估计「大概 60%」，而这类视觉参数是「看着差一点就难受」的。
private struct SliderStyleRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var display: (Double) -> String

    var body: some View {
        FormRow(icon: icon, iconColor: iconColor, title: title, subtitle: subtitle) {
            Slider(value: $value, in: range)
                .frame(width: 150)
            Text(display(value))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
    }
}

/// 分区外观的**取色行**：一块当前色预览 + 十六进制输入框 + 常用色板。
///
/// 为什么两个入口都要有：色板解决「随便来个顺眼的」（80% 场景），
/// hex 框解决「和另一个分区完全同色」—— 后者没有精确入口就只能靠记。
private struct ColorStyleRow: View {
    let title: String
    @Binding var value: String
    /// 值为空时色板的预览色（正文色允许「跟随系统」，此时不能画成黑色误导用户）。
    var fallbackPreview: String = "#cccccc"
    /// 空值时输入框的占位文案。
    var placeholder: String = "#RRGGBB"

    /// 三端共享的常用色板（顺序一致，见 `PartitionLook.palette`）。
    private static let palette = PartitionLook.palette

    private var trimmed: String { value.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        FormRow(icon: "paintpalette.fill",
                iconColor: trimmed.isEmpty ? Color.secondary : Color(hex: trimmed),
                title: title,
                subtitle: trimmed.isEmpty ? placeholder : nil) {
            HStack(spacing: 4) {
                ForEach(Self.palette, id: \.self) { hex in
                    Button {
                        value = hex
                    } label: {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 14, height: 14)
                            .overlay(Circle()
                                .strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help(hex)
                }
            }

            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(trimmed.isEmpty
                      ? Color(hex: fallbackPreview).opacity(0.35)
                      : Color(hex: trimmed))
                .frame(width: 26, height: 18)
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))

            TextField(placeholder, text: $value)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .frame(width: 86)
        }
    }
}

/// 顶端美学 Header
private struct ModernModalHeader: View {
    let icon: String
    let iconColor: Color
    let title: String
    var subtitle: String? = nil
    var onClose: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [iconColor.opacity(0.28), iconColor.opacity(0.12)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 36, height: 36)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(iconColor.opacity(0.35), lineWidth: 1)
                    )
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(iconColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("关闭 (Esc)")
            }
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 2)
    }
}

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >> 8) & 0xFF) / 255
        let b = Double(v & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - 新建分区（4 种类型）

struct NewPartitionView: View {
    let onSelectFolder: () -> String?
    let onCreate: (_ type: String, _ folderPath: String?, _ title: String?, _ extensions: [String]) -> Void
    let onClose: () -> Void

    @State private var selectedType = "portal"
    @State private var folderPath = ""
    @State private var customTitle = "映射文件夹"

    private let types: [(key: String, icon: String, label: String, emoji: String, color: Color)] = [
        ("portal", "folder.fill", "映射文件夹", "📁 ", .blue),
        ("todo", "checkmark.circle.fill", "待办清单", "✅ ", .green),
        ("notes", "note.text", "随手便签", "📝 ", .orange)
    ]

    private var currentTypeInfo: (key: String, icon: String, label: String, emoji: String, color: Color) {
        types.first(where: { $0.key == selectedType }) ?? types[0]
    }

    private var needsFolder: Bool { selectedType == "portal" }

    var body: some View {
        VStack(spacing: 16) {
            ModernModalHeader(
                icon: "sparkles.rectangle.stack.fill",
                iconColor: .accentColor,
                title: "新建桌面浮岛分区"
            )

            // 1. 类型选择卡片
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: "分区形态")
                HStack(spacing: 6) {
                    ForEach(types, id: \.key) { t in
                        let isSelected = selectedType == t.key
                        Button {
                            let oldLabel = currentTypeInfo.label
                            selectedType = t.key
                            if customTitle.isEmpty || customTitle == oldLabel {
                                customTitle = t.label
                            }
                        } label: {
                            VStack(spacing: 4) {
                                ZStack {
                                    Circle()
                                        .fill(t.color.opacity(isSelected ? 0.25 : 0.12))
                                        .frame(width: 26, height: 26)
                                    Image(systemName: t.icon)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(t.color)
                                }
                                Text(t.label)
                                    .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor).opacity(0.5))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.06),
                                                  lineWidth: isSelected ? 1.5 : 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // 2. 基本信息卡片
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: "基础配置")
                FormCard {
                    let isTitleEmpty = customTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    FormRow(icon: "pencil.line", iconColor: .blue, title: "分区名称") {
                        VStack(alignment: .trailing, spacing: 3) {
                            HStack(spacing: 5) {
                                Text(currentTypeInfo.emoji)
                                    .font(.system(size: 13))
                                TextField(currentTypeInfo.label, text: Binding(
                                    get: { customTitle },
                                    set: { customTitle = String($0.prefix(10)) }
                                ))
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .frame(width: 170)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(isTitleEmpty ? Color.red.opacity(0.85) : Color.primary.opacity(0.12), lineWidth: 1)
                            )

                            if isTitleEmpty {
                                Text("名称不允许为空")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.red)
                            }
                        }
                    }

                    if needsFolder {
                        Divider().opacity(0.4).padding(.leading, 54)
                        FormRow(icon: "folder", iconColor: .indigo,
                                title: "映射文件夹",
                                subtitle: folderPath.isEmpty ? "尚未选择路径" : (folderPath as NSString).lastPathComponent) {
                            Button {
                                if let p = onSelectFolder() { folderPath = p }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "folder.badge.plus")
                                    Text("选择文件夹")
                                }
                                .font(.system(size: 11, weight: .medium))
                                .frame(minWidth: 92)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        // 快捷路径选择胶囊
                        HStack(spacing: 6) {
                            Text("快捷路径:")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            let home = FileManager.default.homeDirectoryForCurrentUser.path
                            ForEach([("桌面", "desktopcomputer", home + "/Desktop"),
                                     ("下载", "arrow.down.circle", home + "/Downloads"),
                                     ("文稿", "doc.text", home + "/Documents")], id: \.2) { d in
                                Button {
                                    folderPath = d.2
                                } label: {
                                    HStack(spacing: 3) {
                                        Image(systemName: d.1).font(.system(size: 9))
                                        Text(d.0).font(.system(size: 10))
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2.5)
                                    .background(
                                        Capsule()
                                            .fill(folderPath == d.2 ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05))
                                    )
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(folderPath == d.2 ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                    }
                }
            }

            Spacer(minLength: 0)

            // 4. 底部操作栏
            HStack {
                Spacer()
                Button("取消") { onClose() }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .keyboardShortcut(.cancelAction)

                let isTitleEmpty = customTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let isFolderMissing = needsFolder && folderPath.isEmpty

                Button("创建分区") {
                    let clean = customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !clean.isEmpty else { return }
                    let finalTitle = currentTypeInfo.emoji + String(clean.prefix(10))
                    onCreate(selectedType,
                             needsFolder ? folderPath : nil,
                             finalTitle,
                             [])
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
                .disabled(isFolderMissing || isTitleEmpty)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: ModalPanelSize.width)
    }
}

// MARK: - 分区级设置

/// 单个分区的设置面板：修改已创建分区的标题 / 映射目录 / 默认视图。
///
/// 补的是三端一致性缺口 —— Electron 版有「分区个性化设置」（可改 `folderPath`），
/// mac 版此前这些只能在**新建时**设定，建好之后无法修改。
struct PartitionSettingsView: View {
    let id: String
    let onSelectFolder: () -> String?
    let onSave: (_ title: String, _ folderPath: String?, _ extensions: [String]?,
                 _ viewMode: String,
                 _ width: Int, _ height: Int, _ style: [String: Any]) -> Void
    let onDelete: () -> Void
    let onClose: () -> Void

    /// ⚠️ 必须留引用的原因：外观里「背景不透明度」的缺省值跟着**全局设置**走
    /// （`settings.partitionBgOpacity`），而全局滑杆可以在面板开着的时候被改；
    /// 面板里的「恢复默认外观」也要读它。这是个 `@ObservedObject` 而非普通 let ——
    /// 用 let 存下来的话，全局值变了面板还在拿旧值写回，会把用户刚调的全局设置顶掉。
    @ObservedObject var config: Config

    @State private var titleText: String
    @State private var folderPath: String
    @State private var viewMode: String
    /// 分区宽高（pt）。面板里的 +/− 与输入框共用这两个值，保存时写回配置并立即改窗口。
    @State private var width: Int
    @State private var height: Int

    // MARK: - 外观（per-partition style）
    //
    // 六个键与 `Config.styleKeys` / `PartitionLook` 同名，写入时成套写进分区的 `style` 字典。
    // **缺省值必须来自 `PartitionLook`** —— 面板显示的值如果和 `PartitionView` 实际渲染用的
    // 默认不一致，用户会看到「面板写着 16pt、分区实际是 12pt」这种无从排查的差。
    @State private var bgColor: String
    @State private var bgOpacity: Double
    @State private var cornerRadius: Double
    @State private var blurAmount: Double
    @State private var headerColor: String
    @State private var textColor: String

    /// 尺寸可调范围。
    /// - 下限：宽 160pt 是「标题 + 两个按钮」还能放下的近似值；高 44pt = 标题栏高度，
    ///   再小就连标题都看不见了（折叠态另走 `isCollapsed`，不走这里）。
    /// - 上限：3000pt 只是防手输天文数字，真正越界的位置由 `ensurePartitionsInBounds` 夹回。
    static let widthRange: ClosedRange<Int> = 160...3000
    static let heightRange: ClosedRange<Int> = 44...3000
    /// 步进档位：宽 20pt / 高 20pt —— 与拖拽边框的手感接近，点几下就能看出差别。
    static let widthStep = 20
    static let heightStep = 20

    private let type: String

    /// 与 `PartitionView.titleParts` 使用**同一份** emoji 表。两处规则必须一致，
    /// 否则会出现「在设置面板改完标题，标题栏的图标丢了」或「图标叠加两次」。
    static let typeEmojis = ["📁 ", "✅ ", "📝 ", "📥 ", "📁", "✅", "📝", "📥"]

    /// 类型元信息（SF Symbol / 名称 / emoji 前缀 / 主题色），与新建面板同源。
    static let typeMeta: [String: (icon: String, label: String, emoji: String, color: Color)] = [
        "portal": ("folder.fill", "映射文件夹", "📁 ", .blue),
        "todo": ("checkmark.circle.fill", "待办清单", "✅ ", .green),
        "notes": ("note.text", "随手便签", "📝 ", .orange)
    ]

    init(id: String,
         config: Config,
         onSelectFolder: @escaping () -> String?,
         onSave: @escaping (String, String?, [String]?, String, Int, Int, [String: Any]) -> Void,
         onDelete: @escaping () -> Void,
         onClose: @escaping () -> Void) {
        self.id = id
        self.onSelectFolder = onSelectFolder
        self.onSave = onSave
        self.onDelete = onDelete
        self.onClose = onClose

        // config 是 `@ObservedObject` 的引用类型属性，必须在尾 closure 之前赋值完。
        self.config = config

        let t = config.str("type", of: id) ?? "portal"
        self.type = t

        // 标题：先剥掉类型 emoji 前缀再放进输入框（保存时补回），
        // 否则会变成「📁 📁 原名称」。
        let full = config.str("title", of: id) ?? ""
        var nameBody = full
        for emoji in Self.typeEmojis where full.hasPrefix(emoji) {
            nameBody = String(full.dropFirst(emoji.count)).trimmingCharacters(in: .whitespaces)
            break
        }

        _titleText = State(initialValue: nameBody)
        _folderPath = State(initialValue: config.str("folderPath", of: id) ?? "")
        _viewMode = State(initialValue: config.str("viewMode", of: id) ?? "grid")

        // 尺寸：配置里存的是 Double，先四舍五入再夹进可调范围。
        // 夹取是必须的 —— 老配置可能缺 width/height（读出来是 0），
        // 面板若显示「宽 0」而用户直接点保存，分区会当场缩成一条线。
        let w = Int(config.num("width", of: id).rounded())
        let h = Int(config.num("height", of: id).rounded())
        _width = State(initialValue: min(max(w > 0 ? w : 200, Self.widthRange.lowerBound),
                                         Self.widthRange.upperBound))
        _height = State(initialValue: min(max(h > 0 ? h : 200, Self.heightRange.lowerBound),
                                          Self.heightRange.upperBound))

        // 外观：缺 key 时 `config.style` 直接返回传入的默认值，这里给的必须与渲染端同源
        // （见 `PartitionLook`）—— 注意 bgOpacity 的缺省跟随全局设置，与其它键不同。
        _bgColor = State(initialValue: config.styleStr("bgColor", of: id,
                                                       default: PartitionLook.defaultBgColor))
        _bgOpacity = State(initialValue: config.style("bgOpacity", of: id,
                                                      default: config.partitionBgOpacity))
        _cornerRadius = State(initialValue: config.style("borderRadius", of: id,
                                                         default: Look.cornerRadius))
        _blurAmount = State(initialValue: config.style("blurAmount", of: id,
                                                       default: PartitionLook.defaultBlurAmount))
        _headerColor = State(initialValue: config.styleStr("headerColor", of: id,
                                                           default: PartitionLook.defaultHeaderColor))
        _textColor = State(initialValue: config.styleStr("textColor", of: id,
                                                         default: PartitionLook.defaultContentTextColor))
    }

    /// 面板当前值 → 待写入的 `style` 字典。
    ///
    /// 全部等于默认值时返回**空字典**（=「删掉 style，跟随全局」），而不是把默认值写死进配置 ——
    /// 否则以后调整 `PartitionLook` 的默认值时，老分区会被自己当年写死的旧值钉住，永远升不了级。
    private func stylePayload() -> [String: Any] {
        var out: [String: Any] = [:]
        let vBgColor = bgColor.trimmingCharacters(in: .whitespaces)
        if Color(hex: vBgColor) != Color(hex: PartitionLook.defaultBgColor) { out["bgColor"] = vBgColor }
        if bgOpacity != config.partitionBgOpacity { out["bgOpacity"] = bgOpacity }
        if cornerRadius != Look.cornerRadius { out["borderRadius"] = cornerRadius }
        if blurAmount != PartitionLook.defaultBlurAmount { out["blurAmount"] = blurAmount }
        let vHeader = headerColor.trimmingCharacters(in: .whitespaces)
        if Color(hex: vHeader) != Color(hex: PartitionLook.defaultHeaderColor) { out["headerColor"] = vHeader }
        // 正文色：留空 = 跟随系统。
        let vText = textColor.trimmingCharacters(in: .whitespaces)
        if !vText.isEmpty { out["textColor"] = vText }
        return out
    }

    private var meta: (icon: String, label: String, emoji: String, color: Color) {
        Self.typeMeta[type] ?? ("square", type, "", .gray)
    }
    private var usesFolder: Bool { type == "portal" }
    private var usesViewMode: Bool { type == "portal" }

    /// 尺寸调节行：`−  [数值]  ＋ pt`。
    /// 中间的数值可直接键入（步进按钮只是快捷方式，不替代输入）；
    /// 越界值统一在保存时夹取 —— 输入中途就强行改写会让「想输 500、刚打完 5 就被弹回」。
    private func sizeField(_ label: String, value: Binding<Int>,
                           step: Int, range: ClosedRange<Int>) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Button {
                value.wrappedValue = max(range.lowerBound, value.wrappedValue - step)
            } label: {
                Image(systemName: "minus").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .disabled(value.wrappedValue <= range.lowerBound)
            .help("减小 \(step)pt")

            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .frame(width: 52)

            Button {
                value.wrappedValue = min(range.upperBound, value.wrappedValue + step)
            } label: {
                Image(systemName: "plus").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .disabled(value.wrappedValue >= range.upperBound)
            .help("增大 \(step)pt")

            Text("pt")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            ModernModalHeader(icon: meta.icon, iconColor: meta.color, title: "分区设置")

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // 1. 分区类型（只读：改类型等于重建分区，会丢内容）
                    HStack(spacing: 8) {
                        Image(systemName: meta.icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(meta.color)
                        Text(meta.label)
                            .font(.system(size: 12, weight: .medium))
                        Text("类型不可更改")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(meta.color.opacity(0.08)))

                    // 2. 分区名称
                    VStack(alignment: .leading, spacing: 6) {
                        SectionHeader(title: "分区名称（最多 10 字）")
                        HStack(spacing: 8) {
                            if !meta.emoji.isEmpty {
                                Text(meta.emoji.trimmingCharacters(in: .whitespaces))
                                    .font(.system(size: 13))
                            }
                            TextField("分区名称", text: Binding(
                                get: { titleText },
                                set: { titleText = String($0.prefix(10)) }
                            ))
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor)))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                        }
                    }

                    // 3. 映射 / 来源目录
                    if usesFolder {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionHeader(title: "映射文件夹")
                            HStack(spacing: 8) {
                                Text(folderPath.isEmpty ? "（未设置 — 分区将显示为空）" : folderPath)
                                    .font(.system(size: 11))
                                    .foregroundStyle(folderPath.isEmpty ? Color.orange : Color.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(folderPath)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Button("选择…") {
                                    if let picked = onSelectFolder() { folderPath = picked }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }

                    // 5. 默认视图
                    if usesViewMode {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionHeader(title: "默认视图")
                            Picker("", selection: $viewMode) {
                                Text("网格").tag("grid")
                                Text("列表").tag("list")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                    }

                    // 6. 分区尺寸（宽 / 高）
                    //
                    // 此前只能靠拖边框或「自适应宽高」间接调整 —— 想把两个分区调成一样大，
                    // 只能靠手感一点点拖。这里给出可直接键入、也可步进的数值入口。
                    VStack(alignment: .leading, spacing: 6) {
                        SectionHeader(title: "分区尺寸")
                        HStack(spacing: 16) {
                            sizeField("宽", value: $width,
                                      step: Self.widthStep, range: Self.widthRange)
                            sizeField("高", value: $height,
                                      step: Self.heightStep, range: Self.heightRange)
                            Spacer()
                        }
                        Text("保存后立即生效，分区左上角位置不变；高度最小 \(Self.heightRange.lowerBound)pt（仅剩标题栏）。")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }

                    // 6.5 外观（per-partition）
                    //
                    // 此前这些键**只存在于配置格式里**（`Config.styleKeys`），没有任何 UI 能写它们 ——
                    // 想要一个红色便签只能手动编辑 JSON。现在给到的是「够用且不迷失」的一组：
                    // 背景色 + 不透明度 + 圆角 + 模糊 + 标题色 + 正文色，外加一键恢复默认。
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "外观")
                        FormCard {
                            ColorStyleRow(title: "背景色", value: $bgColor,
                                          fallbackPreview: PartitionLook.defaultBgColor)
                            Divider().opacity(0.4).padding(.leading, 54)
                            SliderStyleRow(icon: "circle.lefthalf.filled", iconColor: .gray,
                                           title: "背景不透明度",
                                           subtitle: "叠在毛玻璃上的颜色浓度",
                                           value: $bgOpacity,
                                           range: PartitionLook.bgOpacityRange,
                                           display: { String(format: "%.0f%%", $0 * 100) })
                            Divider().opacity(0.4).padding(.leading, 54)
                            SliderStyleRow(icon: "rectangle", iconColor: .indigo,
                                           title: "圆角",
                                           subtitle: "0pt = 直角",
                                           value: $cornerRadius,
                                           range: Double(PartitionLook.cornerRadiusRange.lowerBound)...Double(PartitionLook.cornerRadiusRange.upperBound),
                                           display: { String(format: "%.0fpt", $0) })
                            Divider().opacity(0.4).padding(.leading, 54)
                            SliderStyleRow(icon: "aqi.medium", iconColor: .cyan,
                                           title: "背景模糊",
                                           subtitle: "0 = 纯色背景，其余按系统材质档位生效",
                                           value: $blurAmount,
                                           range: Double(PartitionLook.blurRange.lowerBound)...Double(PartitionLook.blurRange.upperBound),
                                           display: { String(format: "%.0f", $0) })
                            Divider().opacity(0.4).padding(.leading, 54)
                            ColorStyleRow(title: "标题色", value: $headerColor,
                                          fallbackPreview: PartitionLook.defaultHeaderColor)
                            Divider().opacity(0.4).padding(.leading, 54)
                            ColorStyleRow(title: "正文色", value: $textColor,
                                          fallbackPreview: "#ffffff", placeholder: "跟随系统")
                        }
                        HStack(spacing: 10) {
                            Button("恢复默认外观") {
                                bgColor = PartitionLook.defaultBgColor
                                bgOpacity = config.partitionBgOpacity
                                cornerRadius = Look.cornerRadius
                                blurAmount = PartitionLook.defaultBlurAmount
                                headerColor = PartitionLook.defaultHeaderColor
                                textColor = PartitionLook.defaultContentTextColor
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            Text("等于把本分区的 style 整段删掉，重新跟随全局设置。")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }

                }
                .padding(.bottom, 4)
            }

            Spacer(minLength: 0)

            // 底部操作栏
            HStack(spacing: 10) {
                Button(role: .destructive) { onDelete() } label: {
                    Label("删除分区", systemImage: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("取消") { onClose() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)

                Button("保存") {
                    onSave(titleText.trimmingCharacters(in: .whitespacesAndNewlines),
                           usesFolder ? folderPath : nil,
                           nil,
                           viewMode,
                           min(max(width, Self.widthRange.lowerBound), Self.widthRange.upperBound),
                           min(max(height, Self.heightRange.lowerBound), Self.heightRange.upperBound),
                           stylePayload())
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(titleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: ModalPanelSize.width)
    }
}

// MARK: - 全局搜索

/// 跨分区搜索面板：一次查询覆盖所有映射文件夹 / 待办 / 便签。
struct GlobalSearchView: View {
    @ObservedObject var config: Config
    var onClose: () -> Void

    @State private var query = ""
    @State private var results: [SearchHit] = []
    @State private var selectedIndex: Int = 0
    /// 防抖：边打边搜需要让上一次列举先结束，否则在几千文件的目录上会明显卡手。
    @State private var pending: DispatchWorkItem?
    @FocusState private var fieldFocused: Bool
    @State private var eventMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            ModernModalHeader(icon: "magnifyingglass", iconColor: .indigo,
                              title: "全局搜索",
                              subtitle: "映射文件夹 · 待办 · 便签")
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

            // 搜索框
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("输入文件名、待办或便签内容…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($fieldFocused)
                    .onSubmit { invokeSelected() }
                if !query.isEmpty {
                    Button {
                        query = ""
                        results = []
                        selectedIndex = 0
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("清空")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            .padding(.horizontal, 20)

            Divider().opacity(0.4).padding(.top, 12)

            // 结果
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if query.trimmingCharacters(in: .whitespaces).isEmpty {
                            emptyHint(icon: "text.magnifyingglass",
                                      text: "输入关键词开始搜索")
                        } else if results.isEmpty {
                            emptyHint(icon: "questionmark.folder",
                                      text: "没有匹配的文件、待办或便签")
                        } else {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, hit in
                                row(hit, index: index)
                                    .id(hit.id)
                                Divider().opacity(0.18).padding(.leading, 46)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: .infinity)
                .onChange(of: selectedIndex) { newIndex in
                    if newIndex >= 0 && newIndex < results.count {
                        withAnimation(.easeInOut(duration: 0.1)) {
                            proxy.scrollTo(results[newIndex].id, anchor: nil)
                        }
                    }
                }
            }

            Divider().opacity(0.4)

            HStack {
                Text(results.isEmpty ? "—" : "\(results.count) 条结果 · ↑↓ 选择 · 回车打开 · Esc 关闭")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("完成") { onClose() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: ModalPanelSize.width)
        .onAppear {
            fieldFocused = true
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // 若正在输入法拼音/选词组字，交给输入法处理
                if let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
                   textView.hasMarkedText() {
                    return event
                }
                switch event.keyCode {
                case 126: // Up arrow
                    moveSelection(-1)
                    return nil
                case 125: // Down arrow
                    moveSelection(1)
                    return nil
                case 36:  // Return / Enter
                    if event.modifierFlags.contains(.command) {
                        revealSelected()
                    } else {
                        invokeSelected()
                    }
                    return nil
                case 53:  // Escape
                    onClose()
                    return nil
                default:
                    return event
                }
            }
        }
        .onDisappear {
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
                eventMonitor = nil
            }
        }
        .onChange(of: query) { _ in scheduleSearch() }
    }

    // MARK: - 子视图

    private func emptyHint(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private func row(_ hit: SearchHit, index: Int) -> some View {
        let isSelected = selectedIndex == index
        return HStack(spacing: 10) {
            Image(systemName: hit.kind.icon)
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(hit.title)
                    .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(hit.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(hit.path ?? hit.detail)
            }

            Spacer(minLength: 8)

            // 文件类：打开 / 在访达中显示；待办与便签：把对应分区顶到前面来
            if hit.path != nil {
                Button("打开") { invokeHit(hit) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button {
                    revealHit(hit)
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("在访达中显示")
            } else {
                Button("定位分区") { invokeHit(hit) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            selectedIndex = index
        })
        .highPriorityGesture(TapGesture(count: 2).onEnded {
            selectedIndex = index
            invokeHit(hit)
        })
    }

    // MARK: - 动作执行

    private func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        var next = selectedIndex + delta
        if next < 0 { next = results.count - 1 }
        if next >= results.count { next = 0 }
        selectedIndex = next
    }

    private func invokeSelected() {
        guard selectedIndex >= 0 && selectedIndex < results.count else { return }
        invokeHit(results[selectedIndex])
    }

    private func revealSelected() {
        guard selectedIndex >= 0 && selectedIndex < results.count else { return }
        revealHit(results[selectedIndex])
    }

    private func invokeHit(_ hit: SearchHit) {
        if hit.path != nil {
            AppDelegate.shared?.openSearchHit(hit)
        } else {
            AppDelegate.shared?.focusPartition(hit.partitionID)
        }
        onClose()
    }

    private func revealHit(_ hit: SearchHit) {
        if hit.path != nil {
            AppDelegate.shared?.revealSearchHit(hit)
            onClose()
        }
    }

    // MARK: - 搜索调度

    private func scheduleSearch() {
        pending?.cancel()
        let work = DispatchWorkItem { runSearch() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func runSearch() {
        pending?.cancel()
        pending = nil
        let q = query
        DispatchQueue.global(qos: .userInitiated).async {
            let hits = GlobalSearch.search(query: q, in: config)
            DispatchQueue.main.async {
                if self.query == q {
                    self.results = hits
                    self.selectedIndex = hits.isEmpty ? -1 : 0
                }
            }
        }
    }
}

// MARK: - 全局设置

struct GlobalSettingsView: View {
    @ObservedObject var config: Config
    var onClose: (() -> Void)? = nil

    @State private var shortcut: Shortcut = .default
    /// 全局搜索热键（默认 ⌘⌥F）。与「显示 / 隐藏热键」分开录制，互不干扰。
    @State private var searchSc: Shortcut = .searchDefault
    @State private var hint: String?
    @State private var hintOK = true
    /// 「保存布局预设」输入框的内容
    @State private var presetName = ""
    /// 辅助功能授权状态。`AXIsProcessTrusted()` 是一次进程外查询，
    /// 不能在 body 里每次重算 → 只在 struct 初始化与用户点过「去授权」后刷新。
    @State private var axTrusted = AXIsProcessTrusted()

    /// 本屏（光标所在屏 —— 弹窗与托盘菜单都以此为准）的布局预设。
    ///
    /// 依赖 `config.revision` 而不是自己缓存：`config` 是 `@ObservedObject`，
    /// 保存/删除预设都会走 `updateUI` 递增 revision，body 自然重算。
    private var presets: [LayoutPreset] {
        guard let app = AppDelegate.shared else { return [] }
        return app.config.layoutPresets(forScreen: app.activeScreen().displayID)
    }

    private func presetSubtitle(_ p: LayoutPreset) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm"
        let when = p.savedAt.timeIntervalSince1970 > 0 ? " · \(fmt.string(from: p.savedAt))" : ""
        return "\(p.entries.count) 个分区 · \(alignLabel(p.alignMode))\(when)"
    }

    private func alignLabel(_ mode: String) -> String {
        switch mode {
        case "left": return "左侧纵向"
        case "right": return "右侧纵向"
        case "grid": return "网格平铺"
        default: return "顶部横向"
        }
    }

    /// 申请辅助功能授权：先弹系统授权对话框，再打开对应的系统设置页面。
    ///
    /// ⚠️ 勾选后不会在本进程里即时生效 —— 全局鼠标监视器必须**重装**才会开始派发
    /// （见 `AppDelegate.installGlobalMouseMonitor` 的注释）。因此这里隔 1.5s 复查一次，
    /// 并调用 `refreshMouseMonitoring()` 完成「重装 + 关轮询」。
    private func requestAccessibilityTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            axTrusted = AXIsProcessTrusted()
            AppDelegate.shared?.refreshMouseMonitoring()
        }
    }

    private func savePreset() {
        guard let app = AppDelegate.shared else { return }
        if app.saveLayoutPreset(named: presetName, onScreenID: app.activeScreen().displayID) != nil {
            presetName = ""     // 成功才清空，失败（空名/本屏无分区）保留用户输入便于改
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ModernModalHeader(
                icon: "gearshape.2.fill",
                iconColor: .accentColor,
                title: "全局偏好设置"
            )
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider().opacity(0.4)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    // 1. 系统与启动
                    SettingsBlock(title: "系统常驻") {
                        FormRow(icon: "power", iconColor: .blue,
                                title: "开机自动启动") {
                            Toggle("", isOn: Binding(
                                get: { (config.settings["autoStart"] as? Bool) ?? false },
                                set: { AppDelegate.shared?.updateSetting("autoStart", value: $0) }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        }

                        Divider().opacity(0.4).padding(.leading, 54)

                        // 拿到授权 = 光标命中裁决转纯事件驱动，轮询兜底自动关闭（省电 + 响应更快）；
                        // 没拿到 = 退化为自适应轮询（静止 1s / 活动 100ms），功能一致，只是耗电略高。
                        FormRow(icon: "hand.raised.fill", iconColor: axTrusted ? .green : .orange,
                                title: "辅助功能授权",
                                subtitle: axTrusted ? "命中裁决走事件驱动，空闲零轮询"
                                                    : "未授权 → 光标命中改用轮询，耗电略高") {
                            Button(axTrusted ? "已开启" : "去授权") { requestAccessibilityTrust() }
                                .controlSize(.small)
                                .disabled(axTrusted)
                        }
                    }

                // 2. 布局与外观（原名「横排布局与分区宽度」——块内还含默认高度与背景不透明度，
                //    故改用更简洁的统称；三端标题保持一致）
                SettingsBlock(title: "布局与外观") {
                        // 横排最大显示分区数
                        FormRow(icon: "rectangle.split.3x1", iconColor: .cyan,
                                title: "横排最大显示分区数") {
                            Picker("", selection: Binding(
                                get: { config.maxColumns },
                                set: { AppDelegate.shared?.updateSetting("maxColumns", value: $0) }
                            )) {
                                Text("4 个").tag(4)
                                Text("5 个 (默认)").tag(5)
                                Text("6 个").tag(6)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 170)
                        }

                        Divider().opacity(0.4).padding(.leading, 54)

                        // 横排列高方向（只影响「顶部横向排序」）
                        FormRow(icon: "chart.bar.xaxis", iconColor: .teal,
                                title: "横排列高方向") {
                            Picker("", selection: Binding(
                                get: { config.topHeightOrder },
                                set: { AppDelegate.shared?.updateSetting("topHeightOrder", value: $0) }
                            )) {
                                Text("从左到右").tag("leftToRight")
                                Text("从右到左").tag("rightToLeft")
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 170)
                            .help("只影响「顶部横向排序」：\n"
                                  + "从左到右 = 最高的列在最左，向右依次递减或相等；\n"
                                  + "从右到左 = 最高的列在最右，向左依次递减或相等。\n"
                                  + "各列按列高排列，因此列的左右顺序不一定等于分区列表顺序。")
                        }

                        Divider().opacity(0.4).padding(.leading, 54)

                        // 默认与恢复宽度方式
                        FormRow(icon: "arrow.left.and.right", iconColor: .indigo,
                                title: "默认与恢复宽度方式") {
                            Picker("", selection: Binding(
                                get: { config.partitionWidthMode },
                                set: { AppDelegate.shared?.updateSetting("partitionWidthMode", value: $0) }
                            )) {
                                Text("自适应均分").tag("auto")
                                Text("固定宽度").tag("custom")
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 150)
                        }

                        ZStack(alignment: .leading) {
                            if config.partitionWidthMode == "auto" {
                                HStack {
                                    Text("按当前屏幕宽度自动计算 (间距 16pt):")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    let curW = Int(AppDelegate.shared?.defaultPartitionWidth ?? 280)
                                    Text("\(curW) pt")
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Color.accentColor)
                                }
                                .padding(.horizontal, 12)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                            } else {
                                HStack(spacing: 8) {
                                    Text("常用宽度备选:")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    ForEach([280, 320, 360, 400], id: \.self) { w in
                                        let isChosen = (Int(config.customPartitionWidth) == w)
                                        Button {
                                            AppDelegate.shared?.updateSetting("partitionWidthMode", value: "custom")
                                            AppDelegate.shared?.updateSetting("customPartitionWidth", value: w)
                                        } label: {
                                            Text("\(w)pt")
                                                .font(.system(size: 10, weight: isChosen ? .semibold : .regular, design: .monospaced))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 3)
                                                .background(
                                                    Capsule().fill(isChosen ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
                                                )
                                                .overlay(
                                                    Capsule().strokeBorder(isChosen ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1)
                                                )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                            }
                        }
                        .frame(height: 30)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)

                        Divider().opacity(0.4).padding(.leading, 54)

                        // 分区默认高度
                        FormRow(icon: "arrow.up.and.down", iconColor: .teal,
                                title: "分区默认高度") {
                            HStack(spacing: 4) {
                                TextField("高度", value: Binding(
                                    get: { Int(config.defaultPartitionHeight) },
                                    // 与「分区最小高度」同一套夹取（含上限 = 屏幕可用高 - 60），
                                    // 否则填 5000 会出现「最小高度 990 / 默认高度 5000」的自相矛盾
                                    set: { AppDelegate.shared?.setDefaultPartitionHeight($0) }
                                ), formatter: NumberFormatter())
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 55)
                                Text("pt")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        HStack(spacing: 8) {
                            Text("常用高度备选:")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            ForEach([(140, "140 (下限)"), (160, "160"), (200, "200 (默认)"), (260, "260")], id: \.0) { h, label in
                                let isChosen = (Int(config.defaultPartitionHeight) == h)
                                Button {
                                    AppDelegate.shared?.setDefaultPartitionHeight(h)
                                } label: {
                                    Text(label)
                                        .font(.system(size: 10, weight: isChosen ? .semibold : .regular))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(
                                            Capsule().fill(isChosen ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
                                        )
                                        .overlay(
                                            Capsule().strokeBorder(isChosen ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)

                        // 分区最小高度
                        FormRow(icon: "arrow.down.to.line", iconColor: .teal,
                                title: "分区最小高度") {
                            HStack(spacing: 4) {
                                TextField("高度", value: Binding(
                                    get: { Int(config.minPartitionHeight) },
                                    set: { AppDelegate.shared?.setMinPartitionHeight($0) }
                                ), formatter: NumberFormatter())
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 55)
                                Text("pt")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .help("新建分区的初始高度与「自适应宽高」的下限。\n"
                                  + "未设置时跟随「分区默认高度」。")
                        }

                        HStack(spacing: 8) {
                            Text("常用高度备选:")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            ForEach([(140, "140 (下限)"), (160, "160"), (200, "200 (默认)"), (260, "260")], id: \.0) { h, label in
                                let isChosen = (Int(config.minPartitionHeight) == h)
                                Button {
                                    AppDelegate.shared?.setMinPartitionHeight(h)
                                } label: {
                                    Text(label)
                                        .font(.system(size: 10, weight: isChosen ? .semibold : .regular))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(
                                            Capsule().fill(isChosen ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
                                        )
                                        .overlay(
                                            Capsule().strokeBorder(isChosen ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)

                        Divider().opacity(0.4).padding(.leading, 54)

                        // 分区背景不透明度（全局，滑动调整）
                        FormRow(icon: "circle.lefthalf.filled", iconColor: .gray,
                                title: "分区背景不透明度") {
                            HStack(spacing: 8) {
                                Slider(value: Binding(
                                    get: { config.partitionBgOpacity },
                                    set: { AppDelegate.shared?.updateSetting("partitionBgOpacity", value: $0) }
                                ), in: 0...1)
                                .controlSize(.small)
                                .frame(width: 132)
                                Text(String(format: "%.0f%%", config.partitionBgOpacity * 100))
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 40, alignment: .trailing)
                            }
                        }
                    }

                // 3. 交互与快捷键
                SettingsBlock(title: "热键与交互") {
                        FormRow(icon: "command", iconColor: .purple,
                                title: "显示 / 隐藏热键") {
                            HStack(spacing: 6) {
                                ShortcutRecorderView(shortcut: $shortcut) { ok, msg in
                                    if ok {
                                        let r = AppDelegate.shared?.setGlobalShortcut(shortcut)
                                        hintOK = r?.ok ?? false
                                        hint = r?.message
                                    } else {
                                        hintOK = false
                                        hint = msg
                                    }
                                }
                                .frame(width: 92, height: 26)

                                Button("默认") {
                                    let r = AppDelegate.shared?.setGlobalShortcut(.default)
                                    shortcut = AppDelegate.shared?.currentShortcut ?? .default
                                    hintOK = r?.ok ?? false
                                    hint = r?.message
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }

                        if let h = hint {
                            HStack {
                                Image(systemName: hintOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                Text(h)
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(hintOK ? Color.green : Color.orange)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 6)
                        }

                        Divider().opacity(0.4).padding(.leading, 54)

                        FormRow(icon: "magnifyingglass", iconColor: .indigo,
                                title: "全局搜索热键") {
                            HStack(spacing: 6) {
                                ShortcutRecorderView(shortcut: $searchSc) { ok, msg in
                                    if ok {
                                        let r = AppDelegate.shared?.setSearchShortcut(searchSc)
                                        hintOK = r?.ok ?? false
                                        hint = r?.message
                                    } else {
                                        hintOK = false
                                        hint = msg
                                    }
                                }
                                .frame(width: 92, height: 26)

                                Button("默认") {
                                    let r = AppDelegate.shared?.setSearchShortcut(.searchDefault)
                                    searchSc = AppDelegate.shared?.searchShortcut ?? .searchDefault
                                    hintOK = r?.ok ?? false
                                    hint = r?.message
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }

                        Divider().opacity(0.4).padding(.leading, 54)

                        FormRow(icon: "magnet", iconColor: .orange,
                                title: "拖拽边缘磁吸对齐") {
                            Toggle("", isOn: Binding(
                                get: { (config.settings["snapToEdges"] as? Bool) ?? true },
                                set: { AppDelegate.shared?.updateSetting("snapToEdges", value: $0) }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        }

                        Divider().opacity(0.4).padding(.leading, 54)

                        FormRow(icon: "eye", iconColor: .teal,
                                title: "折叠分区悬停展开") {
                            Toggle("", isOn: Binding(
                                get: { (config.settings["hoverPeekCollapsed"] as? Bool) ?? true },
                                set: { AppDelegate.shared?.updateSetting("hoverPeekCollapsed", value: $0) }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        }
                    }

                // 4. 显示器参数
                SettingsBlock(title: "显示器参数 (已连接 \(NSScreen.screens.count) 台)") {
                        ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { idx, scr in
                            if idx > 0 {
                                Divider().opacity(0.4).padding(.leading, 54)
                            }
                            let isMain = (scr == NSScreen.main)
                            let w = Int(scr.frame.width)
                            let h = Int(scr.frame.height)
                            let scale = scr.backingScaleFactor
                            let name = scr.localizedName.isEmpty ? "显示器 \(idx + 1)" : scr.localizedName
                            FormRow(icon: isMain ? "display.2" : "display",
                                    iconColor: isMain ? .blue : .secondary,
                                    title: name,
                                    subtitle: "\(w) × \(h) pt · \(String(format: "%.1f", scale))x 缩放") {
                                if isMain {
                                    Text("主显示器")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.blue)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.blue.opacity(0.12)))
                                }
                            }
                        }
                    }

                // 5. 布局预设（按屏保存；应用即把分区搬回记录的位置与尺寸）
                SettingsBlock(title: "布局预设") {
                        FormRow(icon: "rectangle.3.group", iconColor: .purple,
                                title: "保存当前布局",
                                subtitle: "记录本屏所有分区的位置、尺寸与对齐方式") {
                            HStack(spacing: 8) {
                                TextField("预设名称", text: $presetName)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11))
                                    .frame(width: 104)
                                    .onSubmit { savePreset() }
                                Button {
                                    savePreset()
                                } label: {
                                    Label("保存", systemImage: "plus")
                                        .font(.system(size: 11))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }

                        if !presets.isEmpty {
                            Divider().opacity(0.4).padding(.leading, 54)
                            ForEach(presets, id: \.key) { p in
                                FormRow(icon: "rectangle.on.rectangle.angled", iconColor: .secondary,
                                        title: p.name,
                                        subtitle: presetSubtitle(p)) {
                                    HStack(spacing: 6) {
                                        Button("应用") {
                                            AppDelegate.shared?.applyLayoutPreset(p)
                                            if let onClose { onClose() }
                                            else { AppDelegate.shared?.closeSettings() }
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)

                                        Button {
                                            AppDelegate.shared?.deleteLayoutPreset(p)
                                        } label: {
                                            Image(systemName: "trash")
                                                .font(.system(size: 11))
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .help("删除该预设（不影响分区本身）")
                                    }
                                }
                            }
                        }
                    }

                // 6. 配置备份与迁移
                SettingsBlock(title: "数据与备份") {
                        FormRow(icon: "externaldrive.badge.timemachine", iconColor: .green,
                                title: "配置存储") {
                            HStack(spacing: 8) {
                                Button {
                                    AppDelegate.shared?.exportConfigBackup()
                                } label: {
                                    Label("导出配置", systemImage: "square.and.arrow.up")
                                        .font(.system(size: 11))
                                        .frame(minWidth: 78)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Button {
                                    AppDelegate.shared?.importConfigBackup()
                                } label: {
                                    Label("导入配置", systemImage: "square.and.arrow.down")
                                        .font(.system(size: 11))
                                        .frame(minWidth: 78)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }

                        FormRow(icon: "clock.arrow.circlepath", iconColor: .teal,
                                title: "历史快照",
                                subtitle: "每次保存配置时自动留存，最多 20 份") {
                            HStack(spacing: 8) {
                                Text("\(AppDelegate.shared?.config.availableHistory().count ?? 0) 份")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 28, alignment: .trailing)

                                Button {
                                    AppDelegate.shared?.restoreLatestHistory()
                                } label: {
                                    Label("恢复最近一份", systemImage: "arrow.uturn.backward")
                                        .font(.system(size: 11))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider().opacity(0.4)

            // 底部操作栏
            HStack {
                Spacer()
                Button("完成") {
                    if let onClose { onClose() }
                    else { AppDelegate.shared?.closeSettings() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: ModalPanelSize.width)
        .onAppear {
            shortcut = AppDelegate.shared?.currentShortcut ?? .default
            searchSc = AppDelegate.shared?.searchShortcut ?? .searchDefault
        }
    }
}
}
