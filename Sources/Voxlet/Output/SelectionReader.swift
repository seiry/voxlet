import AppKit
import ApplicationServices
import Carbon.HIToolbox
import OSLog

/// Reads the frontmost app's selected text, adapted from Voxt's SelectedTextProbe (Apache-2.0).
/// Order: focused element, caret-only short-circuit (skipped for apps that misreport it), AXSelectedText,
/// AXStringForRange, AXTextMarker, then a guarded ⌘C. Voxt's browser AppleScript path is left out: Firefox has no
/// JavaScript bridge, and Chrome and Safari need Automation rights plus a developer menu switch.
enum SelectionReader {
    private static let focusTimeout: Float = 0.2
    private static let fallbackTimeout: Float = 0.05
    private static let copyWait: TimeInterval = 0.15

    private static let log = Logger(subsystem: "dev.seiry.voxlet", category: "selection")

    static func selectedText() -> String? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else {
            log.notice("probe skipped: accessibility not trusted or no frontmost app")
            return nil
        }
        let bundleID = app.bundleIdentifier
        let appID = bundleID ?? "unknown"
        // Obsidian reports stale selections, so Voxt skips it entirely.
        guard bundleID != "md.obsidian" else { return nil }

        let (focused, windowCount) = resolveFocus(processID: app.processIdentifier)
        let range = focused.flatMap { selectedRange(of: $0) }
        let role = focused.flatMap { stringAttribute(kAXRoleAttribute, of: $0) } ?? "nil"
        log.notice("probe app=\(appID, privacy: .public) focused=\(focused != nil) role=\(role, privacy: .public) range=\(range.map { "\($0.location),\($0.length)" } ?? "nil", privacy: .public) windows=\(windowCount)")
        let unreliable = axSelectionUnreliable(bundleID: bundleID)
        // Terminals, browsers and code editors report a caret-only range even with text selected, so only
        // trust that answer elsewhere.
        if let range, range.length == 0, !unreliable {
            log.notice("result: caret only")
            return nil
        }

        if let focused {
            if let text = stringAttribute(kAXSelectedTextAttribute, of: focused) {
                log.notice("result: AXSelectedText chars=\(text.count)")
                return text
            }
            if let range, let text = string(for: range, of: focused) {
                log.notice("result: AXStringForRange chars=\(text.count)")
                return text
            }
            if let text = textMarkerSelection(startingAt: focused) {
                log.notice("result: text marker chars=\(text.count)")
                return text
            }
        }

        let copiesLine = copiesCurrentLineWhenSelectionEmpty(bundleID: bundleID)
        // ⌘C is safe where AX confirmed a non-empty range, where AX is dead, and in apps whose AX answer cannot
        // be trusted. Editors that copy the whole line on an empty selection get their line copies filtered out.
        let allowCopy: Bool
        if unreliable || focused == nil {
            allowCopy = true
        } else {
            allowCopy = (range?.length ?? 0) > 0
        }
        if allowCopy, let raw = simulatedCopy() {
            if copiesLine, looksLikeLineCopy(raw) {
                log.notice("result: rejected line copy")
                return nil
            }
            let text = raw.trimmed
            if !text.isEmpty {
                log.notice("result: simulated copy chars=\(text.count)")
                return text
            }
        }
        log.notice("result: nothing (allowCopy=\(allowCopy) copiesLine=\(copiesLine))")
        return nil
    }

    /// Apps whose AX selection is missing or always reports a caret: terminals (their selection is not a text
    /// selection), browsers (web content is often not exposed), and editors in copiesCurrentLineWhenSelectionEmpty.
    private static func axSelectionUnreliable(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        if copiesCurrentLineWhenSelectionEmpty(bundleID: bundleID) { return true }
        let terminals: Set<String> = [
            "com.mitchellh.ghostty", "com.googlecode.iterm2", "com.apple.Terminal", "dev.warp.Warp-Stable",
            "dev.warp.Warp", "io.alacritty", "org.alacritty", "net.kovidgoyal.kitty", "com.github.wez.wezterm",
            "co.zeit.hyper", "com.raphaelamorim.rio",
        ]
        let browsers: Set<String> = [
            "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly", "app.zen-browser.zen",
            "com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.beta", "com.google.Chrome.dev",
            "org.chromium.Chromium", "company.thebrowser.Browser", "com.microsoft.edgemac", "com.brave.Browser",
            "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        ]
        return terminals.contains(bundleID) || browsers.contains(bundleID)
    }

    // MARK: - Focus

    private static func resolveFocus(processID: pid_t) -> (AXUIElement?, Int) {
        if let element = focusedElement(in: AXUIElementCreateSystemWide()) { return (element, 0) }
        let appElement = AXUIElementCreateApplication(processID)
        if let element = focusedElement(in: appElement) { return (element, 0) }

        var windows: [AXUIElement] = []
        func append(_ window: AXUIElement?) {
            guard let window, !windows.contains(where: { CFEqual($0, window) }) else { return }
            windows.append(window)
        }
        append(elementAttribute(kAXFocusedWindowAttribute, of: appElement, timeout: fallbackTimeout))
        append(elementAttribute(kAXMainWindowAttribute, of: appElement, timeout: fallbackTimeout))
        for window in elementArrayAttribute(kAXWindowsAttribute, of: appElement).prefix(3) { append(window) }

        for window in windows {
            if let element = focusedDescendant(in: window, depth: 6) { return (element, windows.count) }
        }
        return (nil, windows.count)
    }

    private static func focusedElement(in root: AXUIElement) -> AXUIElement? {
        elementAttribute(kAXFocusedUIElementAttribute, of: root, timeout: focusTimeout)
    }

    private static func focusedDescendant(in element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth > 0 else { return nil }
        for child in elementArrayAttribute(kAXChildrenAttribute, of: element) {
            var focused: CFTypeRef?
            if AXUIElementCopyAttributeValue(child, kAXFocusedAttribute as CFString, &focused) == .success,
               (focused as? Bool) == true {
                return child
            }
            if let found = focusedDescendant(in: child, depth: depth - 1) { return found }
        }
        return nil
    }

    // MARK: - Readers

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        AXUIElementSetMessagingTimeout(element, focusTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    private static func string(for range: CFRange, of element: AXUIElement) -> String? {
        var mutableRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &value
        ) == .success else { return nil }
        return nonBlank(value)
    }

    private static func textMarkerSelection(startingAt element: AXUIElement) -> String? {
        var current: AXUIElement? = element
        for _ in 0..<6 {
            guard let node = current else { break }
            AXUIElementSetMessagingTimeout(node, focusTimeout)
            var markerRange: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, "AXSelectedTextMarkerRange" as CFString, &markerRange) == .success,
               let markerRange {
                for attribute in ["AXStringForTextMarkerRange", "AXAttributedStringForTextMarkerRange"] {
                    var value: CFTypeRef?
                    if AXUIElementCopyParameterizedAttributeValue(node, attribute as CFString, markerRange, &value) == .success,
                       let text = nonBlank(value) {
                        return text
                    }
                }
            }
            current = elementAttribute(kAXParentAttribute, of: node, timeout: focusTimeout)
        }
        return nil
    }

    /// Posts ⌘C, waits briefly for the pasteboard to change, then puts every previous item back, not just text.
    private static func simulatedCopy() -> String? {
        let pasteboard = NSPasteboard.general
        let snapshot = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        let changeCount = pasteboard.changeCount
        let source = CGEventSource(stateID: .hidSystemState)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: keyDown)
            else { return nil }
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: HotkeyManager.injectedMarker)
            event.post(tap: .cgAnnotatedSessionEventTap)
        }
        let deadline = Date().addingTimeInterval(copyWait)
        while pasteboard.changeCount == changeCount, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        guard pasteboard.changeCount != changeCount else { return nil }
        let copied = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        let restored = snapshot.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
        return copied
    }

    // MARK: - Policies (from Voxt's SelectedTextSystemSelectionSupport)

    /// Editors where ⌘C with nothing selected copies the whole line, so a simulated copy would invent a selection.
    private static func copiesCurrentLineWhenSelectionEmpty(bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        let exact: Set<String> = [
            "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.microsoft.VSCodeExploration",
            "com.visualstudio.code.oss", "com.visualstudio.code", "com.vscodium", "com.google.antigravity",
            "com.sublimetext.3", "com.sublimetext.4", "dev.zed.Zed", "dev.zed.Zed-Preview",
            "com.trae.app", "com.trae.solo.app", "cn.trae.app", "com.qoder.app", "md.obsidian",
        ]
        if exact.contains(bundleID) { return true }
        let prefixes = ["com.todesktop.", "com.jetbrains.", "com.exafunction.", "com.trae.", "cn.trae.", "com.qoder."]
        if prefixes.contains(where: bundleID.hasPrefix) { return true }
        let lowered = bundleID.lowercased()
        return lowered.contains("vscode") || lowered.contains("vscodium")
    }

    /// A line copy is exactly one line with a trailing newline; real selections rarely end that way.
    private static func looksLikeLineCopy(_ raw: String) -> Bool {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.trimmed.isEmpty else { return true }
        guard normalized.hasSuffix("\n") else { return false }
        return !normalized.dropLast().contains("\n")
    }

    // MARK: - AX helpers

    private static func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        AXUIElementSetMessagingTimeout(element, focusTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return nonBlank(value)
    }

    private static func elementAttribute(_ name: String, of element: AXUIElement, timeout: Float) -> AXUIElement? {
        AXUIElementSetMessagingTimeout(element, timeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func elementArrayAttribute(_ name: String, of element: AXUIElement) -> [AXUIElement] {
        AXUIElementSetMessagingTimeout(element, fallbackTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    private static func nonBlank(_ value: CFTypeRef?) -> String? {
        let text = (value as? String) ?? (value as? NSAttributedString)?.string
        guard let text, !text.trimmed.isEmpty else { return nil }
        return text
    }
}
