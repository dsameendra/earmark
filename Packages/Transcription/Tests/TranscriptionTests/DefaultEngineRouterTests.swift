import AppCore
import Foundation
import Models
import Testing

@testable import Transcription

private typealias Target = RoutingTargets

/// One row of the ADR-004 routing table.
private struct Row: CustomTestStringConvertible, Sendable {
    var name: String
    var mode: LanguageMode
    var useCase: UseCase
    var tier: HardwareTier = .tier16
    var installed: Set<ModelID> = []
    /// Expected assignments as (language, engine, model, experimental, requiresDownload).
    var expected: [(LanguageCode?, EngineID, ModelID, Bool, Bool)]
    var warningFragments: [String] = []
    var testDescription: String { name }
}

private let rows: [Row] = [
    // English live / dictation -> Apple (system assets, never "requires download")
    Row(name: "en live t16", mode: .single("en"), useCase: .live, expected: [(nil, Target.appleEngine, Target.appleSpeech, false, false)]),
    Row(
        name: "en dictation t16", mode: .single("en"), useCase: .dictation,
        expected: [(nil, Target.appleEngine, Target.appleSpeech, false, false)]),
    Row(
        name: "en live t8", mode: .single("en"), useCase: .live, tier: .tier8,
        expected: [(nil, Target.appleEngine, Target.appleSpeech, false, false)]
    ),
    Row(
        name: "en live t32", mode: .single("en"), useCase: .live, tier: .tier32Plus,
        expected: [(nil, Target.appleEngine, Target.appleSpeech, false, false)]),
    Row(
        name: "en-US dictation uses primary subtag", mode: .single("en-US"), useCase: .dictation,
        expected: [(nil, Target.appleEngine, Target.appleSpeech, false, false)]),
    Row(name: "de live", mode: .single("de"), useCase: .live, expected: [(nil, Target.appleEngine, Target.appleSpeech, false, false)]),
    Row(
        name: "ta live (Apple covers Tamil)", mode: .single("ta"), useCase: .live,
        expected: [(nil, Target.appleEngine, Target.appleSpeech, false, false)]),
    // File -> WhisperKit
    Row(
        name: "en file t16 not installed", mode: .single("en"), useCase: .file,
        expected: [(nil, Target.whisperKitEngine, Target.whisperLarge, false, true)]),
    Row(
        name: "en file t16 installed", mode: .single("en"), useCase: .file, installed: [Target.whisperLarge],
        expected: [(nil, Target.whisperKitEngine, Target.whisperLarge, false, false)]),
    Row(
        name: "en file t32", mode: .single("en"), useCase: .file, tier: .tier32Plus, installed: [Target.whisperLarge],
        expected: [(nil, Target.whisperKitEngine, Target.whisperLarge, false, false)]),
    Row(
        name: "en file t8 -> small", mode: .single("en"), useCase: .file, tier: .tier8,
        expected: [(nil, Target.whisperKitEngine, Target.whisperSmall, false, true)]),
    Row(
        name: "en file t8 small installed", mode: .single("en"), useCase: .file, tier: .tier8, installed: [Target.whisperSmall],
        expected: [(nil, Target.whisperKitEngine, Target.whisperSmall, false, false)]),
    Row(name: "fr file", mode: .single("fr"), useCase: .file, expected: [(nil, Target.whisperKitEngine, Target.whisperLarge, false, true)]),
    // Whisper-only languages live -> Whisper small fallback
    Row(
        name: "nl live falls back to Whisper small", mode: .single("nl"), useCase: .live,
        expected: [(nil, Target.whisperKitEngine, Target.whisperSmall, false, true)], warningFragments: ["higher latency"]),
    Row(
        name: "tr dictation falls back to Whisper small", mode: .single("tr"), useCase: .dictation,
        expected: [(nil, Target.whisperKitEngine, Target.whisperSmall, false, true)], warningFragments: ["higher latency"]),
    // Sinhala -> Qwen, experimental, any use case, never Whisper
    Row(
        name: "si file t16", mode: .single("si"), useCase: .file, expected: [(nil, Target.qwenEngine, Target.qwenSinhala, true, true)],
        warningFragments: ["experimental"]),
    Row(
        name: "si live t16", mode: .single("si"), useCase: .live, expected: [(nil, Target.qwenEngine, Target.qwenSinhala, true, true)],
        warningFragments: ["experimental"]),
    Row(
        name: "si dictation installed", mode: .single("si"), useCase: .dictation, installed: [Target.qwenSinhala],
        expected: [(nil, Target.qwenEngine, Target.qwenSinhala, true, false)], warningFragments: ["experimental"]),
    Row(
        name: "si file t8 warns about tier", mode: .single("si"), useCase: .file, tier: .tier8,
        expected: [(nil, Target.qwenEngine, Target.qwenSinhala, true, true)], warningFragments: ["experimental", "tier16"]),
    Row(
        name: "si-LK maps to Sinhala", mode: .single("si-LK"), useCase: .file,
        expected: [(nil, Target.qwenEngine, Target.qwenSinhala, true, true)],
        warningFragments: ["experimental"]),
    // Auto-detect
    Row(
        name: "auto file t16", mode: .autoDetect, useCase: .file,
        expected: [(nil, Target.whisperKitEngine, Target.whisperLarge, false, true)],
        warningFragments: ["never selects the Sinhala"]),
    Row(
        name: "auto file t8", mode: .autoDetect, useCase: .file, tier: .tier8,
        expected: [(nil, Target.whisperKitEngine, Target.whisperSmall, false, true)], warningFragments: ["never selects the Sinhala"]),
    Row(
        name: "auto live", mode: .autoDetect, useCase: .live, expected: [(nil, Target.whisperKitEngine, Target.whisperSmall, false, true)],
        warningFragments: ["higher latency", "never selects the Sinhala"]),
    // Multilingual sets
    Row(
        name: "multi {en,de} file -> one Whisper assignment", mode: .multilingual(["en", "de"]), useCase: .file,
        expected: [(nil, Target.whisperKitEngine, Target.whisperLarge, false, true)]),
    Row(
        name: "multi {en,de} live -> one Apple assignment", mode: .multilingual(["en", "de"]), useCase: .live,
        expected: [(nil, Target.appleEngine, Target.appleSpeech, false, false)]),
    Row(
        name: "multi {en,si} file -> Whisper + Qwen", mode: .multilingual(["en", "si"]), useCase: .file,
        expected: [
            ("en", Target.whisperKitEngine, Target.whisperLarge, false, true), ("si", Target.qwenEngine, Target.qwenSinhala, true, true),
        ],
        warningFragments: ["experimental"]),
    Row(
        name: "multi {en,si} live -> Apple + Qwen", mode: .multilingual(["en", "si"]), useCase: .live,
        expected: [
            ("en", Target.appleEngine, Target.appleSpeech, false, false), ("si", Target.qwenEngine, Target.qwenSinhala, true, true),
        ],
        warningFragments: ["experimental"]),
    Row(
        name: "multi {en,si} file t8 warns about serialised loading", mode: .multilingual(["en", "si"]), useCase: .file, tier: .tier8,
        installed: [Target.whisperSmall, Target.qwenSinhala],
        expected: [
            ("en", Target.whisperKitEngine, Target.whisperSmall, false, false), ("si", Target.qwenEngine, Target.qwenSinhala, true, false),
        ],
        warningFragments: ["only one heavy model", "experimental"]),
    Row(
        name: "multi {en,nl} live -> Apple + Whisper small", mode: .multilingual(["en", "nl"]), useCase: .live,
        expected: [
            ("en", Target.appleEngine, Target.appleSpeech, false, false), ("nl", Target.whisperKitEngine, Target.whisperSmall, false, true),
        ],
        warningFragments: ["higher latency"]),
    Row(
        name: "multi single-element set behaves like single", mode: .multilingual(["en"]), useCase: .live,
        expected: [(nil, Target.appleEngine, Target.appleSpeech, false, false)]),
    // Explicit model override
    Row(
        name: "explicit large for en live", mode: .single("en"), useCase: .live, installed: [Target.whisperLarge],
        expected: [(nil, Target.whisperKitEngine, Target.whisperLarge, false, false)]),
    Row(
        name: "explicit large not installed", mode: .single("fr"), useCase: .file,
        expected: [(nil, Target.whisperKitEngine, Target.whisperLarge, false, true)]),
    Row(
        name: "explicit Apple for file", mode: .single("en"), useCase: .file,
        expected: [(nil, Target.appleEngine, Target.appleSpeech, false, false)]),
    Row(
        name: "explicit Qwen for si", mode: .single("si"), useCase: .file, installed: [Target.qwenSinhala],
        expected: [(nil, Target.qwenEngine, Target.qwenSinhala, true, false)], warningFragments: ["experimental"]),
    Row(
        name: "explicit turbo on t8 warns", mode: .single("en"), useCase: .file, tier: .tier8,
        expected: [(nil, Target.whisperKitEngine, "whisperkit/large-v3-v20240930_turbo_632MB", false, true)], warningFragments: ["tier16"]),
    Row(
        name: "explicit Sinhala Whisper fine-tune warns non-commercial", mode: .single("si"), useCase: .file,
        expected: [(nil, Target.whisperKitEngine, "coreml/whisper-small-sinhala", true, true)],
        warningFragments: ["experimental", "non-commercial"]),
    Row(
        name: "explicit Apple with auto-detect warns", mode: .autoDetect, useCase: .live,
        expected: [(nil, Target.appleEngine, Target.appleSpeech, false, false)], warningFragments: ["cannot detect the language"]),
]

/// The explicit-model rows share the table above but need the model id in the request.
private let explicitModels: [String: ModelID] = [
    "explicit large for en live": Target.whisperLarge,
    "explicit large not installed": Target.whisperLarge,
    "explicit Apple for file": Target.appleSpeech,
    "explicit Qwen for si": Target.qwenSinhala,
    "explicit turbo on t8 warns": "whisperkit/large-v3-v20240930_turbo_632MB",
    "explicit Sinhala Whisper fine-tune warns non-commercial": "coreml/whisper-small-sinhala",
    "explicit Apple with auto-detect warns": Target.appleSpeech,
]

@Suite("DefaultEngineRouter")
struct DefaultEngineRouterTests {
    private let router = DefaultEngineRouter()

    /// ENG-AC-01, ENG-AC-02, LANG-AC-09: every row of the routing table, including requiresDownload and warnings.
    @Test("routing table row", arguments: rows)
    private func tableRow(_ row: Row) throws {
        let request = RoutingRequest(
            languageMode: row.mode, useCase: row.useCase, tier: row.tier, installedModels: row.installed,
            explicitModel: explicitModels[row.name])
        let plan = try router.plan(for: request)
        #expect(plan.assignments.count == row.expected.count, "\(row.name): assignment count")
        for (assignment, expected) in zip(plan.assignments, row.expected) {
            #expect(assignment.language == expected.0, "\(row.name): language")
            #expect(assignment.engine == expected.1, "\(row.name): engine")
            #expect(assignment.model == expected.2, "\(row.name): model")
            #expect(assignment.isExperimental == expected.3, "\(row.name): experimental")
            #expect(assignment.requiresDownload == expected.4, "\(row.name): requiresDownload")
        }
        for fragment in row.warningFragments {
            #expect(
                plan.warnings.contains { $0.localizedCaseInsensitiveContains(fragment) },
                "\(row.name): warning '\(fragment)' in \(plan.warnings)")
        }
        if row.warningFragments.isEmpty { #expect(plan.warnings.isEmpty, "\(row.name): unexpected warnings \(plan.warnings)") }
    }

    @Test("stock Whisper is never routed for Sinhala (LANG-AC-09)", arguments: UseCase.allCases, HardwareTier.allCases)
    func sinhalaNeverWhisper(useCase: UseCase, tier: HardwareTier) throws {
        for mode in [LanguageMode.single("si"), .multilingual(["si", "en"]), .multilingual(["si"])] {
            let plan = try router.plan(for: RoutingRequest(languageMode: mode, useCase: useCase, tier: tier, installedModels: []))
            let sinhala = plan.assignments.filter { $0.language == "si" || $0.language == nil }
            #expect(sinhala.contains { $0.model == Target.qwenSinhala })
            #expect(!plan.assignments.contains { $0.language == "si" && $0.engine == Target.whisperKitEngine })
        }
    }

    @Test("unsupported languages throw", arguments: UseCase.allCases)
    func unsupportedLanguage(useCase: UseCase) {
        let request = RoutingRequest(languageMode: .single("xx"), useCase: useCase, tier: .tier16, installedModels: [])
        #expect(throws: AppError.unsupportedLanguage("xx")) { try router.plan(for: request) }
        let multi = RoutingRequest(languageMode: .multilingual(["en", "xx"]), useCase: useCase, tier: .tier16, installedModels: [])
        #expect(throws: AppError.unsupportedLanguage("xx")) { try router.plan(for: multi) }
    }

    @Test("empty multilingual set is rejected")
    func emptyMultilingual() {
        let request = RoutingRequest(languageMode: .multilingual([]), useCase: .file, tier: .tier16, installedModels: [])
        #expect(throws: AppError.self) { try router.plan(for: request) }
    }

    @Test("explicit model must cover the language (ENG table, last row)")
    func explicitModelMismatch() {
        func plan(_ model: ModelID, _ language: LanguageCode) throws -> EnginePlan {
            try router.plan(
                for: RoutingRequest(
                    languageMode: .single(language), useCase: .file, tier: .tier16, installedModels: [], explicitModel: model))
        }
        #expect(throws: AppError.unsupportedLanguage("si")) { try plan(Target.whisperLarge, "si") }
        #expect(throws: AppError.unsupportedLanguage("en")) { try plan(Target.qwenSinhala, "en") }
        #expect(throws: AppError.unsupportedLanguage("si")) { try plan(Target.appleSpeech, "si") }
        #expect(throws: AppError.modelNotInstalled("nope/unknown")) { try plan("nope/unknown", "en") }
        // Non-ASR models cannot be selected for transcription.
        #expect(throws: AppError.self) { try plan("apple/translation", "en") }
    }

    @Test("explicit model overrides the table even when Auto would pick another engine")
    func explicitOverrides() throws {
        let plan = try router.plan(
            for: RoutingRequest(
                languageMode: .single("en"), useCase: .live, tier: .tier16, installedModels: [Target.whisperSmall],
                explicitModel: Target.whisperSmall))
        #expect(plan.assignments == [EngineAssignment(language: nil, engine: Target.whisperKitEngine, model: Target.whisperSmall)])
    }

    @Test("custom catalog entries are routable explicitly")
    func customModel() throws {
        let custom = ModelDescriptor(
            id: "custom/whisper-si", displayName: "My Sinhala", kind: .asr, runtime: .coreML, engine: "whisperkit", languages: ["si"],
            sizeBytes: 1, license: LicenseInfo(spdx: "MIT"), isCustom: true)
        let router = DefaultEngineRouter(catalog: BuiltInCatalog.models + [custom])
        let plan = try router.plan(
            for: RoutingRequest(
                languageMode: .single("si"), useCase: .file, tier: .tier16, installedModels: ["custom/whisper-si"],
                explicitModel: "custom/whisper-si"))
        #expect(plan.assignments == [EngineAssignment(language: nil, engine: "whisperkit", model: "custom/whisper-si")])
    }

    /// ENG-AC-01: pure function; also guards against crashes for every combination of the request space.
    @Test("routing is deterministic and total over the request space")
    func deterministicAndTotal() {
        let modes: [LanguageMode] = [
            .single("en"), .single("si"), .single("xx"), .autoDetect, .multilingual(["en", "si"]), .multilingual(["de", "nl", "si"]),
        ]
        for mode in modes {
            for useCase in UseCase.allCases {
                for tier in HardwareTier.allCases {
                    let request = RoutingRequest(languageMode: mode, useCase: useCase, tier: tier, installedModels: [Target.whisperLarge])
                    let first = Result { try router.plan(for: request) }
                    let second = Result { try router.plan(for: request) }
                    switch (first, second) {
                    case (.success(let a), .success(let b)): #expect(a == b)
                    case (.failure(let a), .failure(let b)): #expect(a as? AppError == b as? AppError)
                    default: Issue.record("non-deterministic routing for \(request)")
                    }
                }
            }
        }
    }

    /// ENG-AC-18 (router side): minTier above the machine tier produces a warning.
    @Test("tier warning for heavier explicit models")
    func tierWarning() throws {
        let plan = try router.plan(
            for: RoutingRequest(
                languageMode: .single("en"), useCase: .file, tier: .tier8, installedModels: [],
                explicitModel: "whisperkit/large-v3-v20240930_turbo_632MB"))
        #expect(plan.warnings.contains { $0.contains("tier16") })
    }
}
