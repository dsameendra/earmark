import AppCore
import Foundation
import Testing
@testable import ModelStore

@Suite("Complete NLLB catalog inventory")
struct NLLBLanguageProfileTests {
    @Test func inventoryAndAliasPolicyAreSharedWithRuntimeProfiles() throws {
        let descriptor = try #require(BuiltInCatalog.models.first { $0.id == "nllb/200-distilled-600M" })
        #expect(descriptor.languages.count == 202)
        #expect(descriptor.isExperimental && descriptor.license.isNonCommercial)
        #expect(descriptor.capabilities.translationLanguageMatching == .mapped)
        for pair in [LanguagePair(source: "en-US", target: "zh-TW"), LanguagePair(source: "ks-Arab", target: "ks-Deva"), LanguagePair(source: "twi", target: "ak")] {
            #expect(descriptor.supportsTranslation(pair))
        }
        for pair in [LanguagePair(source: "ks", target: "en"), LanguagePair(source: "en-Cyrl", target: "si"), LanguagePair(source: "eng", target: "en-Latn")] {
            #expect(!descriptor.supportsTranslation(pair))
        }
        #expect(descriptor.canonicalTranslationLanguage("ajp") != descriptor.canonicalTranslationLanguage("apc"))
        #expect(descriptor.canonicalTranslationLanguage("tw") == "twi")
    }
}
