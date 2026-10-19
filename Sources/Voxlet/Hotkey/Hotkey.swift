import AppKit
import Carbon.HIToolbox

enum HotkeyBehavior: String, CaseIterable, Identifiable {
    /// Hold to talk, release to finish.
    case longPress
    /// Tap to start, tap again to finish.
    case tap

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .longPress: return L10n.t("Hold to Talk")
        case .tap: return L10n.t("Tap to Toggle")
        }
    }
}

/// Modifier state with left and right keys kept apart, plus Fn.
struct SidedModifiers: OptionSet, Codable, Hashable {
    let rawValue: UInt32

    static let leftControl = SidedModifiers(rawValue: 1 << 0)
    static let rightControl = SidedModifiers(rawValue: 1 << 1)
    static let leftOption = SidedModifiers(rawValue: 1 << 2)
    static let rightOption = SidedModifiers(rawValue: 1 << 3)
    static let leftShift = SidedModifiers(rawValue: 1 << 4)
    static let rightShift = SidedModifiers(rawValue: 1 << 5)
    static let leftCommand = SidedModifiers(rawValue: 1 << 6)
    static let rightCommand = SidedModifiers(rawValue: 1 << 7)
    static let function = SidedModifiers(rawValue: 1 << 8)

    static let control: SidedModifiers = [.leftControl, .rightControl]
    static let option: SidedModifiers = [.leftOption, .rightOption]
    static let shift: SidedModifiers = [.leftShift, .rightShift]
    static let command: SidedModifiers = [.leftCommand, .rightCommand]

    /// Reads the device-dependent bits CGEventFlags carries for each physical modifier key.
    init(cgFlags: CGEventFlags, function: Bool) {
        let raw = cgFlags.rawValue
        var value: SidedModifiers = []
        if raw & 0x0000_0001 != 0 { value.insert(.leftControl) }
        if raw & 0x0000_2000 != 0 { value.insert(.rightControl) }
        if raw & 0x0000_0020 != 0 { value.insert(.leftOption) }
        if raw & 0x0000_0040 != 0 { value.insert(.rightOption) }
        if raw & 0x0000_0002 != 0 { value.insert(.leftShift) }
        if raw & 0x0000_0004 != 0 { value.insert(.rightShift) }
        if raw & 0x0000_0008 != 0 { value.insert(.leftCommand) }
        if raw & 0x0000_0010 != 0 { value.insert(.rightCommand) }
        if function { value.insert(.function) }
        self = value
    }

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Side-insensitive form, used to match key chords.
    var unsided: SidedModifiers {
        var value: SidedModifiers = []
        if !intersection(.control).isEmpty { value.insert(.leftControl) }
        if !intersection(.option).isEmpty { value.insert(.leftOption) }
        if !intersection(.shift).isEmpty { value.insert(.leftShift) }
        if !intersection(.command).isEmpty { value.insert(.leftCommand) }
        if contains(.function) { value.insert(.function) }
        return value
    }

    func symbols(sided: Bool) -> String {
        var parts: [String] = []
        func add(_ left: SidedModifiers, _ right: SidedModifiers, _ symbol: String) {
            let hasLeft = contains(left)
            let hasRight = contains(right)
            guard hasLeft || hasRight else { return }
            if sided && hasRight && !hasLeft {
                parts.append(L10n.t("Right") + " " + symbol)
            } else if sided && hasLeft && !hasRight {
                parts.append(L10n.t("Left") + " " + symbol)
            } else {
                parts.append(symbol)
            }
        }
        if contains(.function) { parts.append("fn") }
        add(.leftControl, .rightControl, "⌃")
        add(.leftOption, .rightOption, "⌥")
        add(.leftShift, .rightShift, "⇧")
        add(.leftCommand, .rightCommand, "⌘")
        return parts.joined(separator: " ")
    }
}

/// A modifier-only trigger (`keyCode == nil`, matched side-sensitively) or a key chord (matched side-insensitively).
struct Hotkey: Codable, Equatable {
    var keyCode: UInt16?
    var modifiers: SidedModifiers

    static let defaultHotkey = Hotkey(keyCode: nil, modifiers: .function)

    var isModifierOnly: Bool { keyCode == nil }

    var displayString: String {
        guard let keyCode else { return modifiers.symbols(sided: true) }
        let mods = modifiers.symbols(sided: false)
        let key = Self.keyName(keyCode)
        return mods.isEmpty ? key : "\(mods) \(key)"
    }

    static func load() -> Hotkey {
        guard let data = UserDefaults.standard.data(forKey: Prefs.hotkey),
              let hotkey = try? JSONDecoder().decode(Hotkey.self, from: data)
        else { return .defaultHotkey }
        return hotkey
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Prefs.hotkey)
    }

    /// System shortcuts that a chord would collide with.
    var conflictWarning: String? {
        guard let keyCode else { return nil }
        let mods = modifiers.unsided
        let reserved: [(Int, SidedModifiers)] = [
            (kVK_Space, .leftCommand), (kVK_Space, .function), (kVK_Tab, .leftCommand),
            (kVK_ANSI_Q, .leftCommand), (kVK_ANSI_V, .leftCommand), (kVK_ANSI_C, .leftCommand),
            (kVK_ANSI_W, .leftCommand), (kVK_Space, [.leftControl, .leftCommand]),
        ]
        if reserved.contains(where: { UInt16($0.0) == keyCode && $0.1 == mods }) {
            return L10n.t("This shortcut is used by macOS or most apps and may not work reliably.")
        }
        if mods.isEmpty || mods == .leftShift {
            return L10n.t("A shortcut without modifiers swallows that key in every app.")
        }
        return nil
    }

    static func keyName(_ keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_Space: return L10n.t("Space")
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_F13: return "F13"
        case kVK_F14: return "F14"
        case kVK_F15: return "F15"
        case kVK_F16: return "F16"
        case kVK_F17: return "F17"
        case kVK_F18: return "F18"
        case kVK_F19: return "F19"
        default: return printableName(keyCode) ?? "#\(keyCode)"
        }
    }

    /// Resolves the character the current keyboard layout puts on this key.
    private static func printableName(_ keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPtr).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars
            )
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}
