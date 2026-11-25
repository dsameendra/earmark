import AppCore
import Foundation
import Testing

@testable import ModelStore

private func treeJSON(_ files: [(path: String, size: Int64)]) -> Data {
    let entries = files.map { ["type": "file", "path": $0.path, "size": $0.size] as [String: Any] }
    return (try? JSONSerialization.data(withJSONObject: entries)) ?? Data()
}

/// Which recorded listing backs which catalog entry.
private let listings: [ModelID: CatalogFixtures.Listing] = [
    "fluidaudio/diarization-community-1": CatalogFixtures.community1,
    "fluidaudio/ls-eend-ami": CatalogFixtures.lseend,
    "fluidaudio/sortformer-v2": CatalogFixtures.sortformer,
    "fluidaudio/parakeet-tdt-v3": CatalogFixtures.parakeet,
    "native/nemotron-3.5-asr-q4": CatalogFixtures.nemotron,
    "native/canary-1b-v2-q4": CatalogFixtures.canary,
    "fluidaudio/parakeet-eou-120m": CatalogFixtures.parakeetEOU,
    "fluidaudio/cohere-transcribe-2b": CatalogFixtures.cohere,
    "fluidaudio/parakeet-ultra": CatalogFixtures.parakeetUltra,
    "fluidaudio/parakeet-redux": CatalogFixtures.parakeetRedux,
    "mlx/qwen3-asr-0.6b-4bit": CatalogFixtures.qwenGeneral,
    "mlx/qwen3-asr-1.7b-4bit": CatalogFixtures.qwenGeneral17,
    "whisperkit/large-v3-v20240930_626MB": CatalogFixtures.whisperLarge,
    "whisperkit/large-v3-v20240930_turbo_632MB": CatalogFixtures.whisperTurbo,
    "whisperkit/small": CatalogFixtures.whisperSmall,
    "opus/en-de-ct2-int8": CatalogFixtures.opusEnDe,
    "opus/de-en-ct2-int8": CatalogFixtures.opusDeEn,
    "opus/en-fr-ct2-int8": CatalogFixtures.opusEnFr,
    "opus/fr-en-ct2-int8": CatalogFixtures.opusFrEn,
    "opus/en-es-ct2-int8": CatalogFixtures.opusEnEs,
    "opus/es-en-ct2-int8": CatalogFixtures.opusEsEn,
    "nllb/200-distilled-600M": CatalogFixtures.nllb,
    "madlad/400-3b-mt-ct2-int8": CatalogFixtures.madladNative,
    "mlx/qwen3-asr-0.6b-sinhala-8bit": CatalogFixtures.qwen,
]

/// A resolver whose "network" is the recorded repo listing plus representative files that must never be downloaded.
private func resolve(_ id: ModelID, dropping dropped: String? = nil) async throws -> [RemoteFile] {
    let listing = try #require(listings[id])
    let descriptor = try #require(BuiltInCatalog.models.first { $0.id == id })
    var all = listing.files + (CatalogFixtures.repoNoise[listing.repo] ?? [])
    if let dropped { all.removeAll { $0.path.hasPrefix(dropped) } }
    let json = treeJSON(all)
    let resolver = HuggingFaceManifestResolver { url in
        #expect(url.absoluteString.hasPrefix("https://huggingface.co/api/models/\(listing.repo)/tree/\(listing.revision)"))
        return json
    }
    return try await resolver.files(for: descriptor)
}

@Suite("Catalog downloads: subpaths, pinned revisions and real sizes (SCR-011)")
struct CatalogDownloadTests {
    @Test("general Qwen atomically includes its pinned neural detector; the Sinhala specialist stays unchanged")
    func qwenSpeechDetector() async throws {
        for id: ModelID in ["mlx/qwen3-asr-0.6b-4bit", "mlx/qwen3-asr-1.7b-4bit"] {
            let files = try await resolve(id)
            let support = files.filter { $0.relativePath.hasPrefix("EarmarkSupport/") }
            #expect(support.count == 5)
            #expect(support.allSatisfy { $0.sha256?.count == 64 && $0.sizeBytes != nil && $0.hasSafeRelativePath })
            #expect(support.allSatisfy { $0.url.absoluteString.contains("/resolve/b419383c55c110e2c9271fa6ee0ea83d03c70d96/") })
            let descriptor = try #require(BuiltInCatalog.models.first { $0.id == id })
            #expect(files.compactMap(\.sizeBytes).reduce(0, +) == descriptor.sizeBytes)
            if id == "mlx/qwen3-asr-1.7b-4bit" {
                #expect(files.count == 15)
                #expect(files.allSatisfy { $0.sha256?.count == 64 })
                #expect(descriptor.provenance?.validation == .nativeInferenceChecked)
                #expect(descriptor.isExperimental && !descriptor.languages.contains("si"))
            }
        }
        let specialist = try await resolve("mlx/qwen3-asr-0.6b-sinhala-8bit")
        #expect(!specialist.contains { $0.relativePath.hasPrefix("EarmarkSupport/") })
    }

    @Test("every tree-sourced entry has a recorded listing, and its real download size is within 15% of the catalog size")
    func sizesMatchManifests() async throws {
        let treeEntries = BuiltInCatalog.models.filter { $0.sourceURL?.absoluteString.contains("/tree/") == true }
        #expect(Set(treeEntries.map(\.id)) == Set(listings.keys), "every catalog tree source needs a recorded fixture")
        for descriptor in treeEntries {
            let files = try await resolve(descriptor.id)
            let total = files.compactMap(\.sizeBytes).reduce(0, +)
            let drift = abs(Double(total) - Double(descriptor.sizeBytes)) / Double(descriptor.sizeBytes)
            #expect(drift <= 0.15, "\(descriptor.id): catalog \(descriptor.sizeBytes) vs manifest \(total)")
        }
    }

    @Test("the entries that used to download whole repositories now fetch exactly the needed files")
    func exactSizes() async throws {
        let expected: [ModelID: Int64] = [
            "fluidaudio/diarization-community-1": 21_623_423, "fluidaudio/ls-eend-ami": 44_617_906,
            "fluidaudio/sortformer-v2": 486_844_491, "fluidaudio/parakeet-tdt-v3": 483_105_645,
            "mlx/qwen3-asr-0.6b-sinhala-8bit": 1_015_560_793,
        ]
        for (id, size) in expected {
            let files = try await resolve(id)
            #expect(files.compactMap(\.sizeBytes).reduce(0, +) == size, "\(id)")
            #expect(BuiltInCatalog.models.first { $0.id == id }?.sizeBytes == size, "\(id) catalog size")
        }
    }

    @Test("LS-EEND downloads only the AMI 100 ms mlmodelc, laid out so the diarizer's name search still finds it")
    func lseend() async throws {
        let files = try await resolve("fluidaudio/ls-eend-ami")
        #expect(files.allSatisfy { $0.relativePath.hasPrefix("optimized/ami/100ms/ls_eend_ami_100ms.mlmodelc/") })
        #expect(files.contains { $0.relativePath.hasSuffix("weights/weight.bin") })
        #expect(files.allSatisfy { !$0.relativePath.contains("mlpackage") && !$0.relativePath.contains("dihard") })
    }

    @Test("Sortformer never downloads the v2.1 weights, the mlpackage duplicates or other variants")
    func sortformer() async throws {
        let files = try await resolve("fluidaudio/sortformer-v2")
        let roots = Set(files.map { String($0.relativePath.split(separator: "/")[0]) })
        #expect(roots == ["Sortformer_v2.mlmodelc", "SortformerNvidiaLow_v2.mlmodelc"])
        #expect(files.allSatisfy { !$0.relativePath.contains("v2.1") })
    }

    @Test("Community-1 downloads the required bundles, PLDA parameters and licence files only")
    func community1() async throws {
        let files = try await resolve("fluidaudio/diarization-community-1")
        let roots = Set(files.map { String($0.relativePath.split(separator: "/")[0]) })
        #expect(
            roots == ["Segmentation.mlmodelc", "FBank.mlmodelc", "Embedding.mlmodelc", "PldaRho.mlmodelc", "plda-parameters.json", "LICENSE", "NOTICE.md"])
    }

    @Test("every built-in source is pinned to a 40-character commit, never main")
    func pinnedRevisions() throws {
        let hex = Set("0123456789abcdef")
        for descriptor in BuiltInCatalog.models {
            guard let source = descriptor.sourceURL else { continue }
            #expect(!source.absoluteString.contains("/main"), "\(descriptor.id) must not follow main")
            let location = try #require(HuggingFaceManifestResolver.location(of: source))
            #expect(location.revision.count == 40 && location.revision.allSatisfy(hex.contains), "\(descriptor.id): \(location.revision)")
            if let listing = listings[descriptor.id] { #expect(location.revision == listing.revision, "\(descriptor.id) fixture revision") }
        }
        for repo in ["openai/whisper-large-v3", "openai/whisper-small"] {
            let urls = WhisperTokenizerFiles.remoteFiles(repo: repo).map(\.url.absoluteString)
            #expect(urls.allSatisfy { !$0.contains("/resolve/main/") }, "\(repo) tokenizer must be pinned")
        }
    }

    @Test("MADLAD is a single pinned file with a checksum and its exact size")
    func madlad() async throws {
        let descriptor = try #require(BuiltInCatalog.models.first { $0.id == "madlad/400-3b-mt-q4k" })
        #expect(descriptor.sha256?.count == 64)
        #expect(descriptor.sizeBytes == 1_654_597_280)
        let files = try await HuggingFaceManifestResolver { _ in Data() }.files(for: descriptor)
        #expect(files.count == 1 && files[0].sha256 == descriptor.sha256)
    }

    @Test("a listing missing a required file is an error, not a silently partial model")
    func missingIncludeFails() async throws {
        await #expect(throws: AppError.self) { _ = try await resolve("fluidaudio/ls-eend-ami", dropping: "optimized/ami/100ms/ls_eend_ami_100ms.mlmodelc") }
        await #expect(throws: AppError.self) { _ = try await resolve("fluidaudio/diarization-community-1", dropping: "plda-parameters.json") }
    }

    @Test("paged tree listings are followed to the end")
    func pagination() async throws {
        let first = URL(string: "https://huggingface.co/api/models/o/r/tree/main/m?recursive=true")!
        let second = URL(string: "https://huggingface.co/api/models/o/r/tree/main/m?recursive=true&cursor=2")!
        let resolver = HuggingFaceManifestResolver(pages: { url in
            if url == first { return (treeJSON([("m/a.bin", 1)]), second) }
            #expect(url == second)
            return (treeJSON([("m/b.bin", 2)]), nil)
        })
        var descriptor = BuiltInCatalog.models[3]
        descriptor.sourceURL = URL(string: "https://huggingface.co/o/r/tree/main/m")
        descriptor.downloadInclude = []
        let files = try await resolver.files(for: descriptor)
        #expect(files.map(\.relativePath) == ["a.bin", "b.bin"])
    }

    @Test("Link header parsing finds rel=next")
    func linkHeader() {
        let header = "<https://huggingface.co/api/models/o/r/tree/main?cursor=abc>; rel=\"next\", <https://x/>; rel=\"first\""
        #expect(HuggingFaceManifestResolver.nextPage(inLinkHeader: header)?.absoluteString == "https://huggingface.co/api/models/o/r/tree/main?cursor=abc")
        #expect(HuggingFaceManifestResolver.nextPage(inLinkHeader: nil) == nil)
        #expect(HuggingFaceManifestResolver.nextPage(inLinkHeader: "<https://x/>; rel=\"first\"") == nil)
    }
}

@Suite("Catalog capabilities, Parakeet and the shared recommender")
struct CatalogCapabilityTests {
    private let catalog = BuiltInCatalog.models

    @Test("native MADLAD is distinct from the legacy download and keeps exact language coverage")
    func nativeMADLADRecipe() throws {
        let native = try #require(catalog.first { $0.id == "madlad/400-3b-mt-ct2-int8" })
        let legacy = try #require(catalog.first { $0.id == "madlad/400-3b-mt-q4k" })
        #expect(native.isRunnable && native.engine == "madlad")
        #expect(native.languages.count == 27)
        #expect(native.supportsTranslation(LanguagePair(source: "ta", target: "si")))
        #expect(!native.supportsTranslation(LanguagePair(source: "en-US", target: "si")))
        #expect(!native.supportsTranslation(LanguagePair(source: "en", target: "zh-Hant")))
        #expect(!legacy.isRunnable)
        #expect(!native.license.isNonCommercial)
    }
    private func recommend(_ tier: HardwareTier, _ use: UseCase, _ language: LanguageCode?) -> ModelID? {
        ModelRecommender.recommendedModel(for: tier, useCase: use, language: language, in: catalog)?.id
    }

    @Test("validated Parakeet is available for its languages and accurately describes buffered streaming")
    func parakeetReady() throws {
        let parakeet = try #require(catalog.first { $0.id == "fluidaudio/parakeet-tdt-v3" })
        #expect(parakeet.isRunnable)
        #expect(parakeet.capabilities.streaming == .buffered)
        #expect(!parakeet.capabilities.autoDetectLanguage)
        let table = LanguageCapabilityTable(models: catalog)
        #expect(table.models(coveringAll: ["sk"]).contains { $0.id == parakeet.id })
        #expect(ModelCompatibility.evaluate(parakeet, for: ModelRequirement(useCase: .file, languages: ["de"]), tier: .tier16).isOK)
    }

    @Test("every ASR model that is runnable names an engine the app registers")
    func runnableModelsUseRegisteredEngines() {
        let registered: Set<EngineID> = ["whisperkit", "apple.speech", "qwen3-asr", "fluidaudio.parakeet", "fluidaudio.cohere", "native.speech", "fluidaudio.parakeet-eou"]  // App/AppEnvironment.swift
        for model in catalog where model.kind == .asr && model.isRunnable {
            #expect(model.engine.map(registered.contains) == true, "\(model.id) advertises an engine nobody registers")
        }
    }

    @Test("the one recommender reproduces the old tier rules")
    func recommendations() {
        #expect(recommend(.tier8, .file, "en") == "whisperkit/small")
        #expect(recommend(.tier16, .file, "en") == "whisperkit/large-v3-v20240930_626MB")
        #expect(recommend(.tier32Plus, .file, "de") == "whisperkit/large-v3-v20240930_626MB")
        #expect(recommend(.tier16, .file, nil) == "whisperkit/large-v3-v20240930_626MB")
        #expect(recommend(.tier8, .file, nil) == "whisperkit/small")
        #expect(recommend(.tier16, .live, "en") == "apple/speech-analyzer")
        #expect(recommend(.tier8, .dictation, "en") == "apple/speech-analyzer")
        #expect(recommend(.tier16, .live, "ar") == "whisperkit/small")
        #expect(recommend(.tier16, .live, nil) == "whisperkit/small")
        for tier in HardwareTier.allCases {
            #expect(recommend(tier, .file, "si") == "mlx/qwen3-asr-0.6b-sinhala-8bit")
        }
    }

    @Test("never recommends an experimental or non-commercial model other than the dedicated Sinhala one")
    func neverRecommendsRiskyModels() {
        for tier in HardwareTier.allCases {
            for use in UseCase.allCases {
                for language: LanguageCode? in [nil, "en", "de", "si", "ar", "ja"] {
                    guard let id = recommend(tier, use, language), let model = catalog.first(where: { $0.id == id }) else { continue }
                    #expect(!model.license.isNonCommercial)
                    #expect(!model.isExperimental || id == "mlx/qwen3-asr-0.6b-sinhala-8bit", "\(id)")
                }
            }
        }
    }

    @Test("compatibility reasons for real catalog entries")
    func realCompatibility() throws {
        func model(_ id: ModelID) throws -> ModelDescriptor { try #require(catalog.first { $0.id == id }) }
        let large = try model("whisperkit/large-v3-v20240930_626MB")
        #expect(ModelCompatibility.evaluate(large, for: ModelRequirement(useCase: .live), tier: .tier16).reasons == [.noLiveStreaming])
        #expect(
            ModelCompatibility.evaluate(large, for: ModelRequirement(useCase: .file, languages: ["si"]), tier: .tier16).reasons
                == [.languageUnsupported(missing: ["si"])])
        let turbo = try model("whisperkit/large-v3-v20240930_turbo_632MB")
        #expect(ModelCompatibility.evaluate(turbo, for: ModelRequirement(useCase: .file), tier: .tier8).reasons == [.needsTier(.tier16)])
        let qwen = try model("mlx/qwen3-asr-0.6b-sinhala-8bit")
        #expect(
            ModelCompatibility.evaluate(qwen, for: ModelRequirement(useCase: .file, languages: ["si"], needsAutoDetect: true), tier: .tier16)
                .reasons == [.noAutoDetect])
        #expect(ModelCompatibility.evaluate(qwen, for: ModelRequirement(useCase: .file, needsWordTimestamps: true), tier: .tier16).reasons == [.noWordTimestamps])
        let diar = try model("fluidaudio/diarization-community-1")
        #expect(ModelCompatibility.evaluate(diar, for: ModelRequirement(useCase: .file), tier: .tier16).reasons == [.notSpeechRecognition(.diarization)])
    }

    @Test("diarization capabilities are truthful")
    func diarizationCapabilities() throws {
        func caps(_ id: ModelID) throws -> ModelCapabilities { try #require(catalog.first { $0.id == id }).capabilities }
        #expect(try caps("fluidaudio/diarization-community-1").speakerLabels == .offline)
        #expect(try caps("fluidaudio/ls-eend-ami").speakerLabels == .streaming)
        #expect(try caps("fluidaudio/sortformer-v2").speakerLabels == .streaming)
        #expect(try caps("nllb/200-distilled-600M").translation)
    }
}
