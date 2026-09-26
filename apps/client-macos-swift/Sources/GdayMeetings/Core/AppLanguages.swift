import Foundation

/// Stable meeting choices. Provider catalogs describe support, not the app's menu.
/// Existing stored codes remain unchanged; adapters resolve them at the boundary.
enum AppLanguages {
    static let all: [ProviderLanguage] = [
        .init(code: "en", name: "English"),
        .init(code: "zh-cn", name: "Chinese (Simplified)"),
        .init(code: "zh-tw", name: "Chinese (Traditional)"),
        .init(code: "yue", name: "Cantonese"),
        .init(code: "ja", name: "Japanese"),
        .init(code: "ko", name: "Korean"),
        .init(code: "es", name: "Spanish"),
        .init(code: "fr", name: "French"),
        .init(code: "de", name: "German"),
        .init(code: "it", name: "Italian"),
        .init(code: "pt", name: "Portuguese"),
        .init(code: "ru", name: "Russian"),
        .init(code: "ar", name: "Arabic"),
    ]
    static func normalized(_ code: String) -> String {
        code.replacingOccurrences(of: "_", with: "-").lowercased()
    }
    static func canonicalCode(for code: String) -> String? {
        let value = normalized(code)
        if all.contains(where: { $0.code == value }) { return value }
        let parts = value.split(separator: "-").map(String.init)
        guard let base = parts.first else { return nil }
        if base == "zh" {
            if parts.contains("hans") { return "zh-cn" }
            if parts.contains("hant") { return "zh-tw" }
            if parts.contains("cn") || parts.contains("sg") { return "zh-cn" }
            if parts.contains("tw") || parts.contains("hk") || parts.contains("mo") { return "zh-tw" }
            // Bare zh does not specify an output script. Keep the original choice.
            return nil
        }
        return all.contains(where: { $0.code == base }) ? base : nil
    }
    static func name(for code: String) -> String {
        guard TranscriptionLanguage.isExplicit(code) else { return "Choose a Language" }
        return all.first { $0.code == canonicalCode(for: code) }?.name
            ?? Locale.current.localizedString(forIdentifier: code) ?? code
    }
    /// Ordered explicit batch equivalents; never erase Chinese script intent or
    /// silently choose a different regional English model.
    static func providerCandidates(for code: String) -> [String] {
        guard let canonical = canonicalCode(for: code) else { return [normalized(code)] }
        switch canonical {
        case "en": return ["en", "en-us"]
        case "zh-cn": return ["zh-cn", "zh-hans", "zh-hans-cn"]
        case "zh-tw": return ["zh-tw", "zh-hant", "zh-hant-tw"]
        case "yue": return ["yue", "yue-cn"]
        case "ja": return ["ja", "ja-jp"]
        case "ko": return ["ko", "ko-kr"]
        case "es": return ["es", "es-es"]
        case "fr": return ["fr", "fr-fr"]
        case "de": return ["de", "de-de"]
        case "it": return ["it", "it-it"]
        case "pt": return ["pt", "pt-br"]
        case "ru": return ["ru", "ru-ru"]
        case "ar": return ["ar", "ar-sa"]
        default: return [canonical]
        }
    }
    static func providerCode(for language: String, catalog: ProviderLanguageCatalog) -> String? {
        for candidate in providerCandidates(for: language) {
            if let match = catalog.languages.first(where: { normalized($0.code) == candidate }) { return match.code }
        }
        return nil
    }
}
