import SpeechNative
import Testing

@Suite("Finite native speech profiles")
struct NativeSpeechProfileTests {
    @Test func rejectsTokenizerOnlyLanguagesAndUnsupportedVariants() throws {
        let profile = NativeSpeechProfile.nemotron35
        #expect(profile.languages.count == 32)
        #expect(Set(profile.languages).count == 32)
        #expect(try profile.resolveLanguage("en") == "en-US")
        #expect(try profile.resolveLanguage("en-GB") == "en-GB")
        #expect(try profile.resolveLanguage("ar") == "ar-AR")
        for code in ["el", "el-GR", "lt-LT", "lv-LV", "mt-MT", "sl-SI", "he-IL", "th-TH", "nn-NO",
                     "en-AU", "zh-Hant", "ar-EG", "si", "auto", "EN", ""] {
            #expect(throws: SpeechWireError.self) { try profile.resolveLanguage(code) }
        }
    }

    @Test func modelIdentityCannotCrossProfiles() throws {
        let multi = NativeSpeechProfile.multitalkerV1
        let nemo = NativeSpeechProfile.nemotron35
        #expect(multi.matches(architecture: "parakeet", variant: multi.variant))
        #expect(!multi.matches(architecture: "parakeet", variant: nemo.variant))
        #expect(!nemo.matches(architecture: "whisper", variant: nemo.variant))
        #expect(try multi.resolveLanguage("en") == "en")
        #expect(throws: SpeechWireError.self) { try multi.resolveLanguage("en-US") }
        #expect(NativeSpeechProfile(rawValue: "arbitrary-model") == nil)
    }

    @Test func languageComesOnlyFromUnambiguousSupportedModelTags() {
        let profile = NativeSpeechProfile.nemotron35
        #expect(profile.detectedLanguage(in: "Bonjour. <fr-FR>") == "fr-FR")
        #expect(profile.detectedLanguage(in: "<ja-JP> 日本語 <ja-JP>") == "ja-JP")
        for text in ["English text", "<en>", "<el-GR>", "<en-AU>", "<en-US><fr-FR>", "<el-GR><en-US>"] {
            #expect(profile.detectedLanguage(in: text) == nil)
        }
        #expect(NativeSpeechProfile.multitalkerV1.detectedLanguage(in: "<en-US>") == nil)
    }
}
