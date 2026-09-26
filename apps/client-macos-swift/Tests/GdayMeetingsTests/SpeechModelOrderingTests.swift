import Foundation
import Testing

@testable import GdayMeetings

struct SpeechModelOrderingTests {
    @Test func canonicalChoicesResolveToExactAppleLocale() {
        let supported = ["en_AU", "en_US", "zh_CN", "zh_TW", "yue_CN", "it_IT"].map(Locale.init(identifier:))
        #expect(AppleSpeechLanguageMapping.locale(for: "en", supported: supported)?.identifier == "en_US")
        #expect(AppleSpeechLanguageMapping.locale(for: "zh-cn", supported: supported)?.identifier == "zh_CN")
        #expect(AppleSpeechLanguageMapping.locale(for: "zh-tw", supported: supported)?.identifier == "zh_TW")
        #expect(AppleSpeechLanguageMapping.locale(for: "yue", supported: supported)?.identifier == "yue_CN")
        #expect(AppleSpeechLanguageMapping.locale(for: "it", supported: supported)?.identifier == "it_IT")
        #expect(AppleSpeechLanguageMapping.locale(for: "en", supported: [Locale(identifier: "en_AU")]) == nil)
        #expect(AppleSpeechLanguageMapping.locale(for: "zh-tw", supported: [Locale(identifier: "zh_CN")]) == nil)
        #expect(AppleSpeechLanguageMapping.locale(for: "ru", supported: supported) == nil)
        #expect(AppleSpeechLanguageMapping.identifier(for: "unknown") == nil)
        #expect(AppLanguages.all.allSatisfy { AppleSpeechLanguageMapping.identifier(for: $0.code) != nil })
    }

    @Test func installedFirstAndRefreshedSnapshotReorders() {
        let languages = [
            ProviderLanguage(code: "en", name: "English"),
            ProviderLanguage(code: "zh-cn", name: "Chinese (Simplified)"),
            ProviderLanguage(code: "de", name: "German"),
        ]
        func snapshot(_ installed: Set<String>) -> [SpeechModelOption] {
            languages.map {
                .init(
                    language: $0, locale: nil,
                    readiness: installed.contains($0.code) ? .installed : .available)
            }
        }
        let display = Locale(identifier: "en_US")
        #expect(
            SpeechModelOrdering.sorted(snapshot(["en"]), displayLocale: display).map(\.id) == ["en", "zh-cn", "de"])
        #expect(
            SpeechModelOrdering.sorted(snapshot(["en", "de"]), displayLocale: display).map(\.id) == [
                "en", "de", "zh-cn",
            ])
        #expect(SpeechModelOrdering.sorted(snapshot([]), displayLocale: display).map(\.id) == ["zh-cn", "en", "de"])
    }
}
