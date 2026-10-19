import Carbon.HIToolbox
import SwiftUI

/// Records a shortcut through the global event tap, so Fn and system-reserved chords can be captured too.
/// Like Voxt, a captured shortcut stays pending until the user confirms it.
final class ShortcutRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var pending: Hotkey?
    @Published private(set) var liveModifiers: SidedModifiers = []

    private var peak: SidedModifiers = []

    func begin() {
        pending = nil
        peak = []
        liveModifiers = []
        isRecording = true
        HotkeyManager.shared.captureHandler = { [weak self] event in self?.handle(event) }
    }

    func cancel() {
        end()
        pending = nil
    }

    func confirm() {
        pending?.save()
        pending = nil
        HotkeyManager.shared.reloadConfig()
    }

    private func end() {
        isRecording = false
        liveModifiers = []
        HotkeyManager.shared.captureHandler = nil
    }

    private func handle(_ event: HotkeyManager.KeyEvent) {
        switch event.kind {
        case .flagsChanged:
            liveModifiers = event.modifiers
            if !event.modifiers.isEmpty {
                peak.formUnion(event.modifiers)
            } else if !peak.isEmpty {
                // All modifiers released with no key in between: a modifier-only shortcut.
                pending = Hotkey(keyCode: nil, modifiers: peak)
                end()
            }
        case .keyDown:
            if event.keyCode == UInt16(kVK_Escape), event.modifiers.subtracting(.function).isEmpty {
                cancel()
                return
            }
            pending = Hotkey(keyCode: event.keyCode, modifiers: event.modifiers)
            end()
        case .keyUp:
            break
        }
    }

    deinit {
        if isRecording { HotkeyManager.shared.captureHandler = nil }
    }
}

struct HotkeySettingsPage: View {
    @AppStorage(Prefs.hotkeyBehavior) private var behavior = HotkeyBehavior.longPress.rawValue
    @AppStorage(Prefs.hotkey) private var hotkeyData = Data()
    @StateObject private var recorder = ShortcutRecorder()

    private var current: Hotkey {
        (try? JSONDecoder().decode(Hotkey.self, from: hotkeyData)) ?? .defaultHotkey
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: L10n.t("Dictation Shortcut")) {
                SettingsRow(title: L10n.t("Shortcut"), caption: recorderCaption) {
                    shortcutField
                }
                if let warning = (recorder.pending ?? current).conflictWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.orange)
                }
                SettingsDivider()
                SettingsRow(
                    title: L10n.t("Trigger"),
                    caption: behavior == HotkeyBehavior.longPress.rawValue
                        ? L10n.t("Hold the shortcut while you speak; release to transcribe.")
                        : L10n.t("Tap once to start and tap again to transcribe.")
                ) {
                    Picker("", selection: $behavior) {
                        ForEach(HotkeyBehavior.allCases) { option in
                            Text(option.displayName).tag(option.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
            }

            SettingsCard(title: L10n.t("Tips")) {
                tip("escape", L10n.t("Press Esc while recording to cancel without pasting anything."))
                tip("globe", L10n.t("Using fn? Set System Settings → Keyboard → “Press 🌐 key to” to “Do Nothing”, or macOS will also open the emoji picker or dictation."))
                tip("hand.raised", L10n.t("Modifier-only shortcuts tell left and right apart, so Right ⌘ leaves Left ⌘ free for normal shortcuts."))
            }
        }
        .onDisappear { if recorder.isRecording { recorder.cancel() } }
    }

    private var recorderCaption: String? {
        if !HotkeyManager.shared.isTapInstalled {
            return L10n.t("Grant Accessibility first; the shortcut and the recorder both need it.")
        }
        if recorder.isRecording {
            return L10n.t("Type your shortcut now. Press Esc to cancel recording.")
        }
        if recorder.pending != nil {
            return L10n.t("Shortcut captured. Press another shortcut to replace it, or choose Confirm / Cancel.")
        }
        return nil
    }

    private var shortcutField: some View {
        HStack(spacing: 8) {
            Text(fieldText)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(recorder.isRecording ? Color.accentColor : Color.primary)
                .frame(width: 200, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: SettingsStyle.controlRadius, style: .continuous)
                        .fill(SettingsStyle.controlFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: SettingsStyle.controlRadius, style: .continuous)
                        .strokeBorder(recorder.isRecording ? Color.accentColor : Color.clear, lineWidth: 1.5)
                )
                .onTapGesture { if !recorder.isRecording { recorder.begin() } }

            if recorder.pending != nil {
                Button(L10n.t("Confirm")) { recorder.confirm() }
                    .buttonStyle(SettingsCompactButtonStyle(prominent: true))
                Button(L10n.t("Cancel")) { recorder.cancel() }
                    .buttonStyle(SettingsCompactButtonStyle())
            } else if recorder.isRecording {
                Button(L10n.t("Cancel")) { recorder.cancel() }
                    .buttonStyle(SettingsCompactButtonStyle())
            } else {
                Button(L10n.t("Record")) { recorder.begin() }
                    .buttonStyle(SettingsCompactButtonStyle())
                    .disabled(!HotkeyManager.shared.isTapInstalled)
                Button {
                    Hotkey.defaultHotkey.save()
                    HotkeyManager.shared.reloadConfig()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(SettingsCompactButtonStyle())
                .help(L10n.t("Reset to fn"))
            }
        }
    }

    private var fieldText: String {
        if recorder.isRecording {
            return recorder.liveModifiers.isEmpty ? L10n.t("Press shortcut…") : recorder.liveModifiers.symbols(sided: true)
        }
        return (recorder.pending ?? current).displayString
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
