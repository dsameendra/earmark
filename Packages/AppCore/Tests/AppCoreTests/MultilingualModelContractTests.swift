import AppCore
import Foundation
import Testing

@Suite("Multilingual model metadata migration")
struct MultilingualModelContractTests {
    @Test("written-language identity preserves scripts while retaining region-only skips")
    func writtenLanguageIdentity() {
        #expect(LanguagePair(source: "en-US", target: "en-GB").isSameWrittenLanguage)
        #expect(!LanguagePair(source: "zh-Hans", target: "zh-Hant").isSameWrittenLanguage)
        #expect(!LanguagePair(source: "zh-CN", target: "zh-TW").isSameWrittenLanguage)
        #expect(LanguagePair(source: "zh-Hant-CN", target: "zh-TW").isSameWrittenLanguage)
        #expect(!LanguagePair(source: "sr-Latn", target: "sr-Cyrl").isSameWrittenLanguage)
        #expect(LanguageCode("zh_HK").translationIdentity == "zh-Hant")
    }
    private func translation(_ capabilities: ModelCapabilities) -> ModelDescriptor {
        ModelDescriptor(
            id: "translation/test", displayName: "Test", kind: .translation, runtime: .other,
            languages: ["en", "de"], sizeBytes: 1, license: LicenseInfo(spdx: "MIT"), capabilities: capabilities)
    }

    @Test("direction packs never acquire a reverse direction from their shared language set")
    func directionalPacks() {
        let forward = LanguagePair(source: "en", target: "de")
        let reverse = LanguagePair(source: "de", target: "en")
        let model = translation(ModelCapabilities(translation: true, translationPairs: [forward]))
        #expect(model.supportsTranslation(forward))
        #expect(!model.supportsTranslation(reverse))
        #expect(!model.supportsTranslation(LanguagePair(source: "fr", target: "de")))
        #expect(!translation(ModelCapabilities(translation: true, translationPairs: [])).supportsTranslation(forward))
        #expect(translation(ModelCapabilities(translation: true)).supportsTranslation(reverse))
    }

    @Test("exact profiles never manufacture support by discarding a language variant")
    func exactLanguageMatching() throws {
        let model = translation(ModelCapabilities(translation: true, translationLanguageMatching: .exact))
        #expect(model.supportsTranslation(LanguagePair(source: "en", target: "de")))
        #expect(!model.supportsTranslation(LanguagePair(source: "en-US", target: "de")))
        #expect(translation(ModelCapabilities(translation: true)).supportsTranslation(LanguagePair(source: "en-US", target: "de")))
        #expect(try JSONDecoder().decode(ModelDescriptor.self, from: JSONEncoder().encode(model)) == model)
    }

    @Test("legacy descriptors preserve behavior without inventing overlap, streaming or provenance")
    func legacyDescriptor() throws {
        let json = #"{"id":{"rawValue":"legacy"},"displayName":"Legacy","kind":"translation","runtime":"other","languages":[{"rawValue":"en"},{"rawValue":"de"}],"sizeBytes":1,"license":{"spdx":"MIT","isNonCommercial":false},"minTier":"tier8","isExperimental":false,"notes":"","isCustom":false,"capabilities":{"file":true,"translation":true}}"#
        let model = try JSONDecoder().decode(ModelDescriptor.self, from: Data(json.utf8))
        #expect(model.provenance == nil)
        #expect(model.capabilities.translationLanguageMatching == .primary)
        #expect(model.capabilities.streaming == nil)
        #expect(model.capabilities.overlapRecognitionSpeakers == nil)
        #expect(model.capabilities.speechTranslationPairs.isEmpty)
        #expect(model.supportsTranslation(LanguagePair(source: "de", target: "en")))
    }

    @Test("native-validation provenance and directions survive restart without implying quality")
    func roundTrip() throws {
        var model = translation(ModelCapabilities(
            translation: true, translationPairs: [LanguagePair(source: "en", target: "de")],
            streaming: .buffered, overlapRecognitionSpeakers: nil))
        model.provenance = ModelProvenance(
            repository: "owner/model", revision: String(repeating: "a", count: 40), profileID: "ct2.marian", profileVersion: 1,
            artifacts: [ModelArtifactDigest(path: "model.bin", bytes: 1, sha256: String(repeating: "b", count: 64))],
            validation: .nativeInferenceChecked)
        #expect(try JSONDecoder().decode(ModelDescriptor.self, from: JSONEncoder().encode(model)) == model)
    }
}
