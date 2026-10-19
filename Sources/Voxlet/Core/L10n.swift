import Foundation

enum InterfaceLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return L10n.t("Follow System")
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }
}

/// English-keyed lookups against the app bundle's .lproj tables, switchable at runtime.
enum L10n {
    private static var cachedBundle: (String, Bundle)?

    static func t(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), arguments: args)
    }

    private static var bundle: Bundle {
        let code = resolvedLanguageCode
        if let cachedBundle, cachedBundle.0 == code { return cachedBundle.1 }
        let resolved = Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)) ?? Bundle.main
        cachedBundle = (code, resolved)
        return resolved
    }

    static var resolvedLanguageCode: String {
        let raw = UserDefaults.standard.string(forKey: Prefs.interfaceLanguage) ?? InterfaceLanguage.system.rawValue
        if let language = InterfaceLanguage(rawValue: raw), language != .system { return language.rawValue }
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("zh") ? "zh-Hans" : "en"
    }
}
