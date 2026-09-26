import Foundation

/// App choices resolve to one explicit Apple locale. Never substitute another
/// region or Chinese script just because the requested locale is unavailable.
enum AppleSpeechLanguageMapping {
    static func identifier(for language: String) -> String? {
        guard let code = AppLanguages.canonicalCode(for: language) else { return nil }
        return [
            "en": "en-US", "zh-cn": "zh-CN", "zh-tw": "zh-TW", "yue": "yue-CN",
            "ja": "ja-JP", "ko": "ko-KR", "es": "es-ES", "fr": "fr-FR",
            "de": "de-DE", "pt": "pt-BR", "ru": "ru-RU", "ar": "ar-SA", "it": "it-IT",
        ][code]
    }

    static func locale(for language: String, supported: [Locale]) -> Locale? {
        guard let identifier = identifier(for: language) else { return nil }
        let expected = identifier.lowercased()
        return supported.first { $0.identifier.replacingOccurrences(of: "_", with: "-").lowercased() == expected }
    }
}
