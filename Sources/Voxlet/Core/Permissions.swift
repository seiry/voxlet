import AppKit
import ApplicationServices
import AVFoundation

enum PermissionKind: String, CaseIterable, Identifiable {
    case microphone
    case accessibility

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: return L10n.t("Microphone")
        case .accessibility: return L10n.t("Accessibility")
        }
    }

    var caption: String {
        switch self {
        case .microphone: return L10n.t("Records your voice while the shortcut is active.")
        case .accessibility: return L10n.t("Listens for the global shortcut and pastes the result into the focused app.")
        }
    }

    var settingsURL: URL {
        switch self {
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        }
    }
}

enum Permissions {
    static func isGranted(_ kind: PermissionKind) -> Bool {
        switch kind {
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .accessibility: return AXIsProcessTrusted()
        }
    }

    static var allGranted: Bool { PermissionKind.allCases.allSatisfy(isGranted) }

    static func request(_ kind: PermissionKind, completion: @escaping (Bool) -> Void = { _ in }) {
        switch kind {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async { completion(granted) }
                }
            case .authorized:
                completion(true)
            default:
                openSettings(kind)
                completion(false)
            }
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            let trusted = AXIsProcessTrustedWithOptions(options)
            if !trusted { openSettings(kind) }
            completion(trusted)
        }
    }

    static func openSettings(_ kind: PermissionKind) {
        NSWorkspace.shared.open(kind.settingsURL)
    }
}
