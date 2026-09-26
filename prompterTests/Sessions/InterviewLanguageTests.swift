import Foundation
import Testing
@testable import prompter

/// The interview language is any locale the transcriber supports, and stored values from before that
/// change still decode.
struct InterviewLanguageTests {
    @Test
    func englishAndFrenchKeepTheirStoredValues() {
        #expect(InterviewLanguage(rawValue: "english") == .english)
        #expect(InterviewLanguage(rawValue: "french") == .french)
        #expect(InterviewLanguage.english.rawValue == "english", "saved sessions must keep decoding")
        #expect(InterviewLanguage.french.rawValue == "french")
        #expect(InterviewLanguage.english.bcp47 == "en" && InterviewLanguage.french.bcp47 == "fr")
    }

    @Test
    func otherLocalesRoundTripByIdentifier() throws {
        let german = try #require(InterviewLanguage(rawValue: "de-DE"))
        #expect(german.rawValue == "de-DE" && german.bcp47 == "de-DE")
        #expect(german.transcriberLocale.identifier(.bcp47) == "de-DE")
        #expect(!german.isFrench)
        #expect(try #require(InterviewLanguage(rawValue: "fr-CA")).isFrench, "French variants follow French rules")
        #expect(InterviewLanguage(rawValue: "") == nil)
        #expect(InterviewLanguagePreference(rawValue: "de-DE") == .language(german))
        #expect(InterviewLanguagePreference(rawValue: "system") == .system)
        #expect(InterviewLanguagePreference.from(stored: "french") == .french)
    }

    @Test
    func namesAreNativeWithTheirRegion() {
        #expect(InterviewLanguage(identifier: "de-DE").displayName.hasPrefix("Deutsch"))
        #expect(InterviewLanguage(identifier: "en-GB").displayName.contains("("), "regional variants are told apart")
        #expect(InterviewLanguage(identifier: "de-DE").localizedName(in: Locale(identifier: "en-US")) == "German (Germany)")
    }

    @Test
    func deviceLanguagesMatchTheClosestSupportedVariant() {
        let supported = ["de-AT", "de-DE", "en-GB", "en-US", "es-ES", "es-MX", "fr-FR", "zh-CN", "zh-TW"]
        #expect(SpeechLocales.bestMatch(for: "es-MX", in: supported) == "es-MX", "exact region")
        #expect(SpeechLocales.bestMatch(for: "de", in: supported) == "de-DE", "the language's usual region")
        #expect(SpeechLocales.bestMatch(for: "zh-Hant-TW", in: supported) == "zh-TW")
        #expect(SpeechLocales.bestMatch(for: "ja-JP", in: supported) == nil, "unsupported is nil, never another language")
    }

    @Test
    func anUnsupportedSystemLanguageIsExplainedNotSwapped() {
        let resolution = InterviewLanguagePreference.resolveSystem(preferredLanguages: ["ja-JP"], supported: ["en-US", "de-DE"])
        #expect(resolution.fallbackNote != nil)
        let german = InterviewLanguagePreference.resolveSystem(preferredLanguages: ["de-CH"], supported: ["en-US", "de-DE"])
        #expect(german.language == InterviewLanguage(identifier: "de-DE") && german.fallbackNote == nil)
    }

    @Test
    func theYearlyMonthlyEquivalentComesFromTheStorePrice() {
        let yearly = EntitlementService.PlanOffer(kind: .yearly, productIdentifier: "talk.cointerview.pro.yearly",
                                                  localizedPrice: "$239.88", price: Decimal(string: "239.88")!, currencyCode: "USD")
        #expect(yearly.monthlyEquivalent == EntitlementService.PlanOffer.format(Decimal(string: "19.99")!, currencyCode: "USD"))
        let monthly = EntitlementService.PlanOffer(kind: .monthly, productIdentifier: "talk.cointerview.pro.monthly",
                                                   localizedPrice: "$25.00", price: 25, currencyCode: "USD")
        #expect(monthly.monthlyEquivalent == nil)
    }
}
