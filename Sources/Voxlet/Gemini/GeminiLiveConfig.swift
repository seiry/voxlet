import Foundation

enum GeminiProvider: String, CaseIterable, Identifiable {
    case agentPlatform
    case aiStudio

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .agentPlatform: return L10n.t("Agent Platform (Vertex AI)")
        case .aiStudio: return L10n.t("Google AI Studio")
        }
    }
}

struct GeminiLiveConfig {
    static let defaultModel = "gemini-3.5-transcribe-live"
    static let defaultLocation = "global"
    static let aiStudioEndpoint =
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
    static let agentPlatformEndpoint =
        "wss://aiplatform.googleapis.com/ws/google.cloud.aiplatform.v1.LlmBidiService/BidiGenerateContent"

    var provider: GeminiProvider
    var apiKey: String
    var model: String
    var project: String
    var location: String
    var endpointOverride: String
    var languageCodes: [String]
    var vocabulary: [String] = []

    var endpoint: String {
        let custom = endpointOverride.trimmed
        if !custom.isEmpty { return custom }
        return provider == .agentPlatform ? Self.agentPlatformEndpoint : Self.aiStudioEndpoint
    }

    /// Agent Platform rejects `models/...` and bare `publishers/...` with 1007; it needs the full resource path.
    var qualifiedModel: String {
        let name = model.trimmed.isEmpty ? Self.defaultModel : model.trimmed
        switch provider {
        case .aiStudio:
            return name.hasPrefix("models/") ? name : "models/\(name)"
        case .agentPlatform:
            if name.hasPrefix("projects/") { return name }
            let bare = name.replacingOccurrences(of: "models/", with: "")
            let loc = location.trimmed.isEmpty ? Self.defaultLocation : location.trimmed
            return "projects/\(project.trimmed)/locations/\(loc)/publishers/google/models/\(bare)"
        }
    }

    var validationError: String? {
        if apiKey.trimmed.isEmpty { return L10n.t("Enter your Gemini API key in Settings → Model first.") }
        if provider == .agentPlatform, project.trimmed.isEmpty, !model.trimmed.hasPrefix("projects/") {
            return L10n.t("Agent Platform needs a project ID or number.")
        }
        if url == nil { return L10n.t("The endpoint URL is invalid.") }
        return nil
    }

    var url: URL? {
        guard var components = URLComponents(string: endpoint) else { return nil }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        case "wss", "ws": break
        default: return nil
        }
        var items = (components.queryItems ?? []).filter { $0.name != "key" }
        items.append(URLQueryItem(name: "key", value: apiKey.trimmed))
        components.queryItems = items
        return components.url
    }

    func setupPayload() -> [String: Any] {
        // An empty language list asks Gemini to auto-detect, which also keeps code-mixing working.
        var transcription: [String: Any] = [
            "languageCodes": languageCodes,
            "mode": "SMART",
        ]
        if !vocabulary.isEmpty {
            transcription["customVocabulary"] = Array(vocabulary.prefix(VocabularyStore.maxTermsSent))
        }
        return [
            "setup": [
                "model": qualifiedModel,
                "generationConfig": ["responseModalities": ["TEXT"]],
                "inputAudioTranscription": transcription,
            ] as [String: Any],
        ]
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
