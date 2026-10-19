import AppKit
import Carbon.HIToolbox

/// Pastes text into the focused app the way Voxt does: pasteboard plus a synthesized ⌘V, then restores the
/// previous clipboard text if nothing else touched the pasteboard in the meantime.
enum TextInserter {
    private static let restoreDelay: TimeInterval = 0.8
    private static let activationDelay: TimeInterval = 0.04

    enum Outcome {
        case pasted
        case copiedOnly
    }

    @discardableResult
    static func insert(_ text: String, target: NSRunningApplication?) -> Outcome {
        let keepInClipboard = Prefs.bool(Prefs.keepResultInClipboard)
        let pasteboard = NSPasteboard.general

        guard AXIsProcessTrusted() else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return .copiedOnly
        }

        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let changeCount = pasteboard.changeCount

        let paste = {
            postCommandV()
            guard !keepInClipboard else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
                guard pasteboard.changeCount == changeCount else { return }
                pasteboard.clearContents()
                if let previous { pasteboard.setString(previous, forType: .string) }
            }
        }

        if let target, target != NSWorkspace.shared.frontmostApplication, !target.isTerminated {
            target.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + activationDelay, execute: paste)
        } else {
            paste()
        }
        return .pasted
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyCode = CGKeyCode(kVK_ANSI_V)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else { continue }
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: HotkeyManager.injectedMarker)
            event.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}
