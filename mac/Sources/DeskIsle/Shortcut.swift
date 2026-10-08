import AppKit
import Carbon
import SwiftUI

/// 全局快捷键的组合键模型。
///
/// 持久化格式沿用 Electron 版（`CommandOrControl+Alt+D`），保证两边配置互通；
/// Carbon 注册需要 keyCode + 修饰键位掩码，展示需要 `⌘⌥D` 这类符号串。
struct Shortcut: Equatable {
    var keyCode: UInt32
    var carbonMods: UInt32

    static let `default` = Shortcut(keyCode: UInt32(kVK_ANSI_D), carbonMods: UInt32(cmdKey | optionKey))

    /// 全局搜索的默认快捷键 ⌘⌥F。
    /// 选 F 是因为它不与「显示/隐藏」的默认 ⌘⌥D 冲突，且 F = Find 好记。
    static let searchDefault = Shortcut(keyCode: UInt32(kVK_ANSI_F), carbonMods: UInt32(cmdKey | optionKey))

    // MARK: - 持久化字符串 ↔ 组合键

    /// 例如 `CommandOrControl+Alt+D`。
    var persisted: String {
        var parts: [String] = []
        if carbonMods & UInt32(cmdKey) != 0 { parts.append("CommandOrControl") }
        if carbonMods & UInt32(controlKey) != 0 { parts.append("Control") }
        if carbonMods & UInt32(optionKey) != 0 { parts.append("Alt") }
        if carbonMods & UInt32(shiftKey) != 0 { parts.append("Shift") }
        parts.append(keyName)
        return parts.joined(separator: "+")
    }

    /// 解析失败返回 nil（调用方应回退到默认键）。
    init?(persisted string: String) {
        let parts = string.split(separator: "+").map(String.init)
        guard let last = parts.last, let code = Self.keyCode(for: last) else { return nil }
        var mods: UInt32 = 0
        for p in parts.dropLast() {
            switch p.lowercased() {
            case "commandorcontrol", "command", "cmd", "meta", "super": mods |= UInt32(cmdKey)
            case "control", "ctrl":                                    mods |= UInt32(controlKey)
            case "alt", "option", "opt":                               mods |= UInt32(optionKey)
            case "shift":                                              mods |= UInt32(shiftKey)
            default: break
            }
        }
        // 只允许 Command/Control/Option/Shift/Fn 之外的裸键当快捷键太容易误触
        guard mods != 0 || Self.isFunctionKey(code) else { return nil }
        self.keyCode = code
        self.carbonMods = mods
    }

    init(keyCode: UInt32, carbonMods: UInt32) {
        self.keyCode = keyCode
        self.carbonMods = carbonMods
    }

    /// 从一次按键事件构造。
    init?(event: NSEvent) {
        let mods = Self.carbonFlags(from: event.modifierFlags)
        // 必须带修饰键，或是独立 F1–F12（Electron 的 ShortcutRecorder 同样限制）
        guard mods != 0 || Self.isFunctionKey(UInt32(event.keyCode)) else { return nil }
        self.keyCode = UInt32(event.keyCode)
        self.carbonMods = mods
    }

    // MARK: - 展示

    var display: String {
        var s = ""
        if carbonMods & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonMods & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonMods & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonMods & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyName
    }

    var keyName: String { Self.name(for: keyCode) }

    /// 托盘菜单用的等价字符（非字母数字键返回空串，避免误设成奇怪的快捷键）。
    var character: String {
        if let hit = Self.letterCodes.first(where: { $0.value == keyCode }) { return hit.key.lowercased() }
        if let hit = Self.digitCodes.first(where: { $0.value == keyCode }) { return hit.key }
        return ""
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if carbonMods & UInt32(cmdKey) != 0 { f.insert(.command) }
        if carbonMods & UInt32(controlKey) != 0 { f.insert(.control) }
        if carbonMods & UInt32(optionKey) != 0 { f.insert(.option) }
        if carbonMods & UInt32(shiftKey) != 0 { f.insert(.shift) }
        return f
    }

    // MARK: - 键名 / 键码表

    static func carbonFlags(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    static func isFunctionKey(_ code: UInt32) -> Bool { (96...111).contains(Int(code)) }

    private static let names: [UInt32: String] = [
        UInt32(kVK_Space): "Space", UInt32(kVK_Return): "↩", UInt32(kVK_Delete): "⌫",
        UInt32(kVK_Escape): "⎋", UInt32(kVK_Tab): "⇥",
        UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12"
    ]

    static func name(for code: UInt32) -> String {
        if let n = names[code] { return n }
        for (c, k) in Self.letterCodes where k == code { return c }
        for (c, k) in Self.digitCodes where k == code { return c }
        return "Key\(code)"
    }

    static func keyCode(for name: String) -> UInt32? {
        if let hit = names.first(where: { $0.value.caseInsensitiveCompare(name) == .orderedSame }) { return hit.key }
        if let k = letterCodes[name.uppercased()] { return k }
        if let k = digitCodes[name] { return k }
        return nil
    }

    static let letterCodes: [String: UInt32] = {
        var d: [String: UInt32] = [:]
        let table: [String: UInt32] = [
            "A": UInt32(kVK_ANSI_A), "B": UInt32(kVK_ANSI_B), "C": UInt32(kVK_ANSI_C), "D": UInt32(kVK_ANSI_D),
            "E": UInt32(kVK_ANSI_E), "F": UInt32(kVK_ANSI_F), "G": UInt32(kVK_ANSI_G), "H": UInt32(kVK_ANSI_H),
            "I": UInt32(kVK_ANSI_I), "J": UInt32(kVK_ANSI_J), "K": UInt32(kVK_ANSI_K), "L": UInt32(kVK_ANSI_L),
            "M": UInt32(kVK_ANSI_M), "N": UInt32(kVK_ANSI_N), "O": UInt32(kVK_ANSI_O), "P": UInt32(kVK_ANSI_P),
            "Q": UInt32(kVK_ANSI_Q), "R": UInt32(kVK_ANSI_R), "S": UInt32(kVK_ANSI_S), "T": UInt32(kVK_ANSI_T),
            "U": UInt32(kVK_ANSI_U), "V": UInt32(kVK_ANSI_V), "W": UInt32(kVK_ANSI_W), "X": UInt32(kVK_ANSI_X),
            "Y": UInt32(kVK_ANSI_Y), "Z": UInt32(kVK_ANSI_Z)
        ]
        d = table
        return d
    }()

    static let digitCodes: [String: UInt32] = [
        "0": UInt32(kVK_ANSI_0), "1": UInt32(kVK_ANSI_1), "2": UInt32(kVK_ANSI_2), "3": UInt32(kVK_ANSI_3),
        "4": UInt32(kVK_ANSI_4), "5": UInt32(kVK_ANSI_5), "6": UInt32(kVK_ANSI_6), "7": UInt32(kVK_ANSI_7),
        "8": UInt32(kVK_ANSI_8), "9": UInt32(kVK_ANSI_9)
    ]
}

/// 快捷键录制器：点击后进入录制态，捕获下一次按键（含修饰键），Esc 取消。
struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var shortcut: Shortcut
    var onCommit: ((Bool, String) -> Void)?   // (是否成功, 提示文案)

    func makeNSView(context: Context) -> CaptureView {
        let v = CaptureView()
        v.onCapture = { sc in
            shortcut = sc
            onCommit?(true, "")
        }
        v.onReject = { onCommit?(false, $0) }
        return v
    }

    func updateNSView(_ nsView: CaptureView, context: Context) {
        nsView.shortcut = shortcut
    }

    final class CaptureView: NSView {
        var shortcut: Shortcut = .default
        var onCapture: ((Shortcut) -> Void)?
        var onReject: ((String) -> Void)?
        @objc private(set) var isRecording = false

        override var acceptsFirstResponder: Bool { true }
        override var intrinsicContentSize: NSSize { NSSize(width: 92, height: 26) }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            wantsLayer = true
            layer?.cornerRadius = 6
        }

        func startRecording() {
            isRecording = true
            window?.makeFirstResponder(self)
            needsDisplay = true
        }

        override func mouseDown(with event: NSEvent) {
            startRecording()
        }

        override func keyDown(with event: NSEvent) {
            guard isRecording else { super.keyDown(with: event); return }
            if event.keyCode == UInt16(kVK_Escape) {
                isRecording = false
                needsDisplay = true
                return
            }
            guard let sc = Shortcut(event: event) else {
                onReject?("请带上 ⌘ / ⌥ / ⌃ / ⇧ 修饰键，或使用 F1–F12")
                return
            }
            isRecording = false
            needsDisplay = true
            onCapture?(sc)
        }

        override func draw(_ dirtyRect: NSRect) {
            let bg = isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.18)
                                 : NSColor.controlBackgroundColor
            bg.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
            NSColor.separatorColor.setStroke()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6).stroke()

            let text = isRecording ? "按下快捷键…" : shortcut.display
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: isRecording ? NSColor.controlAccentColor : NSColor.labelColor
            ]
            let size = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                                y: (bounds.height - size.height) / 2),
                                    withAttributes: attrs)
        }
    }
}
