import AppCore
import Foundation
import Testing

private func model(
    _ id: String, kind: ModelKind = .asr, languages: Set<LanguageCode> = ["en"], minTier: HardwareTier = .tier8,
    experimental: Bool = false, nonCommercial: Bool = false, engine: EngineID? = "e", size: Int64 = 100,
    capabilities: ModelCapabilities = .standard
) -> ModelDescriptor {
    ModelDescriptor(
        id: ModelID(id), displayName: id, kind: kind, runtime: .coreML, engine: engine, languages: languages, sizeBytes: size,
        license: LicenseInfo(spdx: "MIT", isNonCommercial: nonCommercial), minTier: minTier, isExperimental: experimental,
        capabilities: capabilities)
}

@Suite("ModelCapabilities and ModelDescriptor decoding")
struct ModelCapabilitiesDecodingTests {
    @Test("finite mapped aliases preserve scripts, cannot chain, and survive persistence")
    func mappedTranslationAliases() throws {
        let capabilities = ModelCapabilities(translation: true, translationPairs: [LanguagePair(source: "en", target: "zh-Hant")], translationLanguageMatching: .mapped,
            translationLanguageAliases: ["eng": "en", "en-Latn": "en", "zh-Hans": "zh", "bad": "unknown", "chain": "eng"])
        let original = model("mapped", kind: .translation, languages: ["en", "zh", "zh-Hant"], capabilities: capabilities)
        let restored = try JSONDecoder().decode(ModelDescriptor.self, from: JSONEncoder().encode(original))
        #expect(restored == original)
        #expect(restored.supportsTranslation(LanguagePair(source: "eng", target: "zh-TW")))
        #expect(restored.supportsTranslation(LanguagePair(source: "en-US", target: "zh-Hant")))
        #expect(!restored.supportsTranslation(LanguagePair(source: "zh-TW", target: "en")))
        #expect(!restored.supportsTranslation(LanguagePair(source: "en-Cyrl", target: "zh-TW")))
        #expect(!restored.supportsTranslation(LanguagePair(source: "en-Latn", target: "en")))
        #expect(restored.canonicalTranslationLanguage("bad") == nil)
        #expect(restored.canonicalTranslationLanguage("chain") == nil)
        let legacy = try JSONDecoder().decode(ModelCapabilities.self, from: Data("{}".utf8))
        #expect(legacy.translationLanguageAliases.isEmpty && legacy.translationLanguageMatching == .primary)
    }

    @Test("a descriptor persisted before SCR-011 decodes with standard capabilities and no include list")
    func legacyDescriptorDecodes() throws {
        // Encode today's descriptor, then strip the SCR-011 keys to get exactly what an old state.json holds.
        let current = model("custom/abc", languages: ["si"], experimental: true)
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        object["capabilities"] = nil
        object["downloadInclude"] = nil
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ModelDescriptor.self, from: legacy)
        #expect(decoded.capabilities == .standard)
        #expect(decoded.downloadInclude.isEmpty)
        #expect(decoded.isRunnable)
        #expect(!decoded.capabilities.live)
    }

    @Test("capabilities round trip and tolerate missing fields")
    func roundTrip() throws {
        let rich = ModelCapabilities(
            live: true, file: true, wordTimestamps: true, autoDetectLanguage: true, speakerLabels: .streaming, translation: true,
            speed: .fast, memory: .moderate, recommendedUse: [RecommendedUse(.live, minTier: .tier16, priority: 2)])
        let back = try JSONDecoder().decode(ModelCapabilities.self, from: JSONEncoder().encode(rich))
        #expect(back == rich)
        let partial = try JSONDecoder().decode(ModelCapabilities.self, from: Data(#"{"live":true}"#.utf8))
        #expect(partial.live && partial.file && !partial.wordTimestamps && partial.speed == nil)
    }

    @Test("a model with neither live nor file capability is not runnable and is hidden from language tables")
    func notRunnableHiddenFromTables() {
        let hidden = model("hidden", languages: ["sk"], capabilities: ModelCapabilities(live: false, file: false))
        let shown = model("shown", languages: ["en"])
        #expect(!hidden.isRunnable)
        let table = LanguageCapabilityTable(models: [hidden, shown])
        #expect(table.languages() == ["en"])
        #expect(table.models(coveringAll: ["sk"]).isEmpty)
        #expect(table.languages(forModel: "hidden").isEmpty)
    }
}

@Suite("ModelCompatibility: one reason per grey-out")
struct ModelCompatibilityTests {
    private func reasons(
        _ m: ModelDescriptor, _ req: ModelRequirement, tier: HardwareTier = .tier16, engines: Set<EngineID>? = nil
    ) -> [ModelIncompatibility] {
        ModelCompatibility.evaluate(m, for: req, tier: tier, availableEngines: engines).reasons
    }

    @Test func compatibleModelIsOK() {
        let ok = model("ok", capabilities: ModelCapabilities(live: true, file: true))
        #expect(ModelCompatibility.evaluate(ok, for: ModelRequirement(useCase: .live, languages: ["en"]), tier: .tier8) == .ok)
    }

    @Test func noLiveStreaming() {
        let r = reasons(model("a"), ModelRequirement(useCase: .live))
        #expect(r == [.noLiveStreaming])
        #expect(r.first?.message == "No live streaming")
        #expect(reasons(model("a"), ModelRequirement(useCase: .dictation)) == [.noLiveStreaming])
    }

    @Test func noFileTranscription() {
        let live = model("live", capabilities: ModelCapabilities(live: true, file: false))
        #expect(reasons(live, ModelRequirement(useCase: .file)) == [.noFileTranscription])
    }

    @Test func languageUnsupportedListsMissingLanguages() {
        let r = reasons(model("a"), ModelRequirement(useCase: .file, languages: ["en", "si", "de"]))
        #expect(r == [.languageUnsupported(missing: ["de", "si"])])
        #expect(r.first?.message == "No de, si support")
    }

    @Test func primarySubtagCovers() {
        #expect(reasons(model("a"), ModelRequirement(useCase: .file, languages: ["en-GB"])).isEmpty)
    }

    @Test func noAutoDetect() {
        let r = reasons(model("a"), ModelRequirement(useCase: .file, needsAutoDetect: true))
        #expect(r == [.noAutoDetect])
        #expect(r.first?.message == "Cannot detect the language automatically")
    }

    @Test func noWordTimestamps() {
        let r = reasons(model("a"), ModelRequirement(useCase: .file, needsWordTimestamps: true))
        #expect(r == [.noWordTimestamps])
        #expect(r.first?.message == "No word timestamps")
    }

    @Test func needsTier() {
        let big = model("big", minTier: .tier16)
        let r = reasons(big, ModelRequirement(useCase: .file), tier: .tier8)
        #expect(r == [.needsTier(.tier16)])
        #expect(r.first?.message == "Needs a 16 GB Mac or more")
        #expect(reasons(big, ModelRequirement(useCase: .file), tier: .tier16).isEmpty)
    }

    @Test func notSpeechRecognition() {
        let diar = model("d", kind: .diarization)
        #expect(reasons(diar, ModelRequirement(useCase: .file)) == [.notSpeechRecognition(.diarization)])
    }

    @Test func notRunnableAndEngineNotRegistered() {
        let dead = model("dead", capabilities: ModelCapabilities(live: false, file: false))
        #expect(reasons(dead, ModelRequirement(useCase: .file)) == [.notRunnableInThisBuild])
        let live = model("e", engine: "ghost")
        #expect(reasons(live, ModelRequirement(useCase: .file), engines: ["other"]) == [.engineNotRegistered("ghost")])
        #expect(reasons(live, ModelRequirement(useCase: .file), engines: ["ghost"]).isEmpty)
        #expect(reasons(live, ModelRequirement(useCase: .file), engines: nil).isEmpty)
    }

    @Test func reasonsAccumulate() {
        let r = reasons(model("a", minTier: .tier32Plus), ModelRequirement(useCase: .live, languages: ["si"], needsAutoDetect: true), tier: .tier8)
        #expect(r.count == 4)
    }
}

@Suite("ModelRecommender: the single tier -> default rule")
struct ModelRecommenderTests {
    private let apple = model(
        "apple", languages: ["en", "de"], capabilities: ModelCapabilities(
            live: true, file: true, recommendedUse: [RecommendedUse(.live), RecommendedUse(.dictation)]))
    private let large = model(
        "large", languages: ["en", "de", "ar"], capabilities: ModelCapabilities(
            file: true, autoDetectLanguage: true, recommendedUse: [RecommendedUse(.file, minTier: .tier16)]))
    private let small = model(
        "small", languages: ["en", "de", "ar"], capabilities: ModelCapabilities(
            live: true, file: true, autoDetectLanguage: true,
            recommendedUse: [RecommendedUse(.file, maxTier: .tier8), RecommendedUse(.live, priority: 1), RecommendedUse(.dictation, priority: 1)]))
    private let sinhala = model(
        "si", languages: ["si"], minTier: .tier16, experimental: true, capabilities: ModelCapabilities(
            live: true, file: true, recommendedUse: [RecommendedUse(.file), RecommendedUse(.live)]))
    private var catalog: [ModelDescriptor] { [apple, large, small, sinhala] }

    private func pick(_ tier: HardwareTier, _ use: UseCase, _ language: LanguageCode?, fallback: Bool = true) -> String? {
        ModelRecommender.recommendedModel(for: tier, useCase: use, language: language, in: catalog, allowFallback: fallback)?.id.rawValue
    }

    @Test func fileByTier() {
        #expect(pick(.tier8, .file, "en") == "small")
        #expect(pick(.tier16, .file, "en") == "large")
        #expect(pick(.tier32Plus, .file, "en") == "large")
        #expect(pick(.tier16, .file, nil) == "large")
        #expect(pick(.tier8, .file, nil) == "small")
    }

    @Test func liveAndDictationPreferAppleWhenItCoversTheLanguage() {
        #expect(pick(.tier16, .live, "en") == "apple")
        #expect(pick(.tier8, .dictation, "de") == "apple")
        #expect(pick(.tier16, .live, "ar") == "small", "Apple does not cover Arabic")
        #expect(pick(.tier16, .live, nil) == "small", "auto-detect needs a model that detects the language")
    }

    @Test func sinhalaGoesToTheDedicatedModelEvenThoughItIsExperimental() {
        #expect(pick(.tier16, .file, "si") == "si")
        #expect(pick(.tier8, .live, "si") == "si")
    }

    @Test func noModelCoversTheLanguage() {
        #expect(pick(.tier16, .file, "xx") == nil)
    }

    @Test func nonCommercialNeverRecommended() {
        let nc = model("nc", nonCommercial: true, capabilities: ModelCapabilities(
            file: true, autoDetectLanguage: true, recommendedUse: [RecommendedUse(.file)]))
        #expect(ModelRecommender.recommendedModel(for: .tier16, useCase: .file, language: "en", in: [nc]) == nil)
    }

    @Test func experimentalLosesToAStableRuleAndNeverWinsByFallback() {
        let exp = model("exp", experimental: true, capabilities: ModelCapabilities(
            file: true, autoDetectLanguage: true, recommendedUse: [RecommendedUse(.file, priority: -5)]))
        #expect(ModelRecommender.recommendedModel(for: .tier16, useCase: .file, language: "en", in: [exp, large])?.id == "large")
    }

    @Test func fallbackOnlyWhenAllowed() {
        let plain = model("plain", size: 50)
        let bigger = model("bigger", size: 500)
        let exp = model("exp", experimental: true, size: 9000)
        #expect(ModelRecommender.recommendedModel(for: .tier16, useCase: .file, language: "en", in: [plain, exp, bigger])?.id == "bigger")
        #expect(
            ModelRecommender.recommendedModel(for: .tier16, useCase: .file, language: "en", in: [plain, bigger], allowFallback: false) == nil)
    }

    @Test func experimentalCoverageAloneNeverBecomesARecommendation() {
        let unreviewed = model("new-tamil", languages: ["ta"], experimental: true)
        let result = ModelRecommender.recommendedModel(for: .tier16, useCase: .file, language: "ta", in: [unreviewed])
        #expect(result == nil)
        let explicit = model("reviewed-tamil", languages: ["ta"], experimental: true,
                             capabilities: ModelCapabilities(file: true, recommendedUse: [RecommendedUse(.file)]))
        let selected = ModelRecommender.recommendedModel(for: .tier16, useCase: .file, language: "ta", in: [explicit])
        #expect(selected?.id == explicit.id)
    }

    @Test func fallbackRespectsTier() {
        let heavy = model("heavy", minTier: .tier16, size: 900)
        let light = model("light", size: 10)
        #expect(ModelRecommender.recommendedModel(for: .tier8, useCase: .file, language: "en", in: [heavy, light])?.id == "light")
    }

    @Test func unrunnableAndWrongEngineAreSkipped() {
        let dead = model("dead", capabilities: ModelCapabilities(live: false, file: false, recommendedUse: [RecommendedUse(.file)]))
        let ghost = model("ghost", engine: "ghost", capabilities: ModelCapabilities(file: true, recommendedUse: [RecommendedUse(.file)]))
        #expect(ModelRecommender.recommendedModel(for: .tier16, useCase: .file, language: "en", in: [dead], availableEngines: nil) == nil)
        #expect(ModelRecommender.recommendedModel(for: .tier16, useCase: .file, language: "en", in: [ghost], availableEngines: ["e"]) == nil)
    }
}

@Suite("Download preflight types")
struct ModelPreflightTypeTests {
    @Test func issuesClassify() {
        #expect(ModelPreflightIssue.insufficientDisk(needed: 2, available: 1).isBlocking)
        #expect(ModelPreflightIssue.nonCommercialLicense(spdx: "CC-BY-NC-4.0").requiresConsent)
        #expect(ModelPreflightIssue.licenseNotice(spdx: "CC-BY-SA-4.0", attribution: nil).requiresConsent)
        #expect(ModelPreflightIssue.hardwareTier(required: .tier16, available: .tier8).requiresConsent)
        #expect(!ModelPreflightIssue.largeDownload(bytes: 1).requiresConsent)
        #expect(!ModelPreflightIssue.largeDownload(bytes: 1).isBlocking)
    }

    @Test func resultSummaries() {
        let clear = ModelPreflightResult(model: "m", displayName: "M", downloadBytes: 1)
        #expect(clear.isClear && !clear.isBlocking && !clear.requiresConsent)
        let needs = ModelPreflightResult(model: "m", displayName: "M", downloadBytes: 1, issues: [.nonCommercialLicense(spdx: "X")])
        #expect(!needs.isClear && needs.requiresConsent && !needs.isBlocking)
        let blocked = ModelPreflightResult(model: "m", displayName: "M", downloadBytes: 1, issues: [.insufficientDisk(needed: 5, available: 1)])
        #expect(blocked.isBlocking && !blocked.isClear)
        #expect(blocked.issues[0].message.hasPrefix("Not enough free disk space"))
    }

    @Test func licenceAcknowledgement() {
        #expect(LicenseInfo(spdx: "LicenseRef-Gemma").needsAcknowledgement)
        #expect(LicenseInfo(spdx: "LicenseRef-OpenMDW-1.1").needsAcknowledgement)
        #expect(!LicenseInfo(spdx: "LicenseRef-Apple-System").needsAcknowledgement)
        #expect(LicenseInfo(spdx: "CC-BY-SA-4.0").needsAcknowledgement)
        #expect(LicenseInfo(spdx: "NOASSERTION").needsAcknowledgement)
        #expect(!LicenseInfo(spdx: "MIT").needsAcknowledgement)
        #expect(!LicenseInfo(spdx: "CC-BY-4.0").needsAcknowledgement)
    }
}
