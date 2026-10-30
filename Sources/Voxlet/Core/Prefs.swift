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
    static let transcriptionStyle = "transcriptionStyle"

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

    static let meetingFolder = "meetingFolder"
    static let meetingGatewayURL = "meetingGatewayURL"
    static let meetingNotesModel = "meetingNotesModel"
    static let meetingBrowsers = "meetingBrowsers"
    /// "auto" (on unless headphones), "on" or "off".
    static let meetingEchoCancellation = "meetingEchoCancellation"
    static let meetingPanelFrame = "meetingPanelFrame"
    static let meetingPanelCollapsed = "meetingPanelCollapsed"
    static let meetingPanelTab = "meetingPanelTab"

    static let defaultMeetingBrowsers = [
        "org.mozilla.firefoxdeveloperedition", "org.mozilla.firefox", "com.google.Chrome", "company.thebrowser.Browser",
        "com.microsoft.edgemac",
    ].joined(separator: "\n")

    static var meetingBrowserBundleIDs: [String] {
        string(meetingBrowsers).split(whereSeparator: { $0 == "\n" || $0 == "," }).map { String($0).trimmed }.filter { !$0.isEmpty }
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            provider: GeminiProvider.agentPlatform.rawValue,
            vertexLocation: GeminiLiveConfig.defaultLocation,
            model: GeminiLiveConfig.defaultModel,
            transcriptionStyle: TranscriptionStyle.verbatimClean.rawValue,
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
            meetingFolder: "~/Meetings",
            meetingGatewayURL: "https://ai.sgp1.seiry.eu",
            meetingNotesModel: "gemini-3.8-flash",
            meetingBrowsers: defaultMeetingBrowsers,
            meetingEchoCancellation: "auto",
            meetingPanelTab: "live",
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
            languageCodes: RecognitionLanguage.codes(for: string(recognitionLanguage)),
            vocabulary: VocabularyStore.shared.terms,
            mode: TranscriptionStyle.current.geminiMode
        )
    }
}

/// How Gemini shapes the transcript. SMART also resolves what it takes for self-corrections, which can drop whole
/// clauses, so the default is VERBATIM with only standalone fillers removed locally.
enum TranscriptionStyle: String, CaseIterable, Identifiable {
    case verbatimClean
    case smart
    case verbatim

    var id: String { rawValue }

    static var current: TranscriptionStyle {
        TranscriptionStyle(rawValue: Prefs.string(Prefs.transcriptionStyle)) ?? .verbatimClean
    }

    var geminiMode: String { self == .smart ? "SMART" : "VERBATIM" }

    var displayName: String {
        switch self {
        case .verbatimClean: return L10n.t("Verbatim, Fillers Removed")
        case .smart: return L10n.t("Smart Cleanup")
        case .verbatim: return L10n.t("Fully Verbatim")
        }
    }

    var caption: String {
        switch self {
        case .verbatimClean:
            return L10n.t("Keeps every sentence and only drops standalone fillers such as 嗯, 呃, um and uh.")
        case .smart:
            return L10n.t("Gemini also resolves self-corrections and formats lists, which can drop whole clauses.")
        case .verbatim:
            return L10n.t("Exactly what was said, fillers and false starts included.")
        }
    }

    func apply(to text: String) -> String {
        self == .verbatimClean ? FillerFilter.clean(text) : text
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
