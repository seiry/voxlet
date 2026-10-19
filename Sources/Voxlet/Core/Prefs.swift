import Foundation

enum OverlayPosition: String, CaseIterable, Identifiable {
    case bottom
    case top

    var id: String { rawValue }
}

/// UserDefaults keys. Views bind them with @AppStorage; non-UI code reads them through `Prefs`.
enum Prefs {
    static let provider = "provider"
    static let vertexProject = "vertexProject"
    static let vertexLocation = "vertexLocation"
    static let model = "model"
    static let endpointOverride = "endpointOverride"
    static let recognitionLanguage = "recognitionLanguage"

    static let hotkey = "hotkey"
    static let hotkeyBehavior = "hotkeyBehavior"

    static let inputDeviceUID = "inputDeviceUID"
    static let interactionSounds = "interactionSounds"
    static let showRealtimeText = "showRealtimeText"
    static let keepResultInClipboard = "keepResultInClipboard"
    static let showInDock = "showInDock"
    static let interfaceLanguage = "interfaceLanguage"

    static let overlayOpacity = "overlayOpacity"
    static let overlayCornerRadius = "overlayCornerRadius"
    static let overlayEdgeDistance = "overlayEdgeDistance"
    static let overlayPosition = "overlayPosition"

    static let priceAudioInputPerMillion = "priceAudioInputPerMillion"
    static let priceTextOutputPerMillion = "priceTextOutputPerMillion"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            provider: GeminiProvider.agentPlatform.rawValue,
            vertexLocation: GeminiLiveConfig.defaultLocation,
            model: GeminiLiveConfig.defaultModel,
            hotkeyBehavior: HotkeyBehavior.longPress.rawValue,
            interactionSounds: true,
            showRealtimeText: true,
            keepResultInClipboard: false,
            showInDock: false,
            interfaceLanguage: InterfaceLanguage.system.rawValue,
            overlayOpacity: 82.0,
            overlayCornerRadius: 24.0,
            overlayEdgeDistance: 30.0,
            overlayPosition: OverlayPosition.bottom.rawValue,
            priceAudioInputPerMillion: Pricing.defaultAudioInputPerMillion,
            priceTextOutputPerMillion: Pricing.defaultTextOutputPerMillion,
        ])
    }

    static var defaults: UserDefaults { .standard }

    static func string(_ key: String) -> String { defaults.string(forKey: key) ?? "" }
    static func bool(_ key: String) -> Bool { defaults.bool(forKey: key) }
    static func double(_ key: String) -> Double { defaults.double(forKey: key) }

    static func liveConfig() -> GeminiLiveConfig {
        GeminiLiveConfig(
            provider: GeminiProvider(rawValue: string(provider)) ?? .agentPlatform,
            apiKey: Keychain.apiKey ?? "",
            model: string(model),
            project: string(vertexProject),
            location: string(vertexLocation),
            endpointOverride: string(endpointOverride),
            languageCodes: RecognitionLanguage.codes(for: string(recognitionLanguage))
        )
    }
}

/// Presets for Gemini's languageCodes; auto-detect handles Chinese/English code-mixing well.
enum RecognitionLanguage: String, CaseIterable, Identifiable {
    case auto = ""
    case chinese = "zh-CN"
    case english = "en-US"
    case japanese = "ja-JP"
    case chineseEnglish = "zh-CN,en-US"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return L10n.t("Auto Detect")
        case .chinese: return L10n.t("Chinese")
        case .english: return L10n.t("English")
        case .japanese: return L10n.t("Japanese")
        case .chineseEnglish: return L10n.t("Chinese + English")
        }
    }

    static func codes(for raw: String) -> [String] {
        raw.split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty }
    }
}
