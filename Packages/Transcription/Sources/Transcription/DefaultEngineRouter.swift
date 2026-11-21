import AppCore
import Foundation
import Models

/// Well-known engine and model identifiers used by routing (ADR-004). They match `BuiltInCatalog` in the Models package.
public enum RoutingTargets {
    /// Apple SpeechAnalyzer engine.
    public static let appleEngine: EngineID = "apple.speech"
    /// WhisperKit CoreML engine.
    public static let whisperKitEngine: EngineID = "whisperkit"
    /// Qwen3-ASR (MLX) engine; implemented later (T25), routing already targets it.
    public static let qwenEngine: EngineID = "qwen3-asr"

    /// System-managed Apple speech assets.
    public static let appleSpeech: ModelID = "apple/speech-analyzer"
    /// Default file model (large-v3-v20240930, 626 MB).
    public static let whisperLarge: ModelID = "whisperkit/large-v3-v20240930_626MB"
    /// Light Whisper model for 8 GB Macs and for Whisper-based live fallback.
    public static let whisperSmall: ModelID = "whisperkit/small"
    /// Default Sinhala model (experimental).
    public static let qwenSinhala: ModelID = "mlx/qwen3-asr-0.6b-sinhala-8bit"
}

/// The pure, table-driven engine router of ADR-004.
///
/// The router performs no I/O and holds only an immutable catalog, so every routing-table row can be unit tested. The
/// table (tier16, "Auto"):
///
/// | Languages | Use case | Engine / model |
/// |---|---|---|
/// | Apple-supported (e.g. `en`) | live, dictation | Apple SpeechAnalyzer |
/// | Whisper languages | file | WhisperKit large-v3-v20240930 626 MB |
/// | `si` | any | Qwen3-ASR-0.6B-Sinhala 8-bit (experimental); stock Whisper is never used for Sinhala |
/// | any, tier8 | file / live fallback | WhisperKit small |
/// | explicit model | any | that model if it covers the languages, else ``AppError/unsupportedLanguage(_:)`` |
///
/// Auto-detect (`LanguageMode.autoDetect`) has no language to route on: files use Whisper, live uses Whisper small, and a
/// warning notes that Sinhala is never selected automatically.
public struct DefaultEngineRouter: EngineRouter {
    private let descriptors: [ModelID: ModelDescriptor]

    /// Creates a router.
    /// - Parameter catalog: Model descriptors used to look up engines, languages and tiers. Defaults to the built-in
    ///   catalog; pass an extended list to include custom imported models.
    public init(catalog: [ModelDescriptor] = BuiltInCatalog.models) {
        descriptors = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Produces the engine plan for a request. Deterministic and side-effect free.
    ///
    /// - Throws: ``AppError/unsupportedLanguage(_:)`` when no model covers a requested language (or the explicit model does
    ///   not), ``AppError/modelNotInstalled(_:)`` when an explicit model is not in the catalog, and ``AppError/other(_:)``
    ///   for an empty multilingual set.
    public func plan(for request: RoutingRequest) throws -> EnginePlan {
        let languages = try requestedLanguages(request.languageMode)
        if let explicit = request.explicitModel {
            return try explicitPlan(model: explicit, languages: languages, request: request)
        }
        return try autoPlan(languages: languages, request: request)
    }

    // MARK: - Languages

    /// `nil` means "detect" (no language known up front).
    private func requestedLanguages(_ mode: LanguageMode) throws -> [LanguageCode]? {
        switch mode {
        case .single(let language): return [language]
        case .autoDetect: return nil
        case .multilingual(let set):
            guard !set.isEmpty else { throw AppError.other("Multilingual mode needs at least one language.") }
            return set.sorted()
        }
    }

    private func covers(_ descriptor: ModelDescriptor, _ language: LanguageCode) -> Bool {
        descriptor.languages.contains(language) || descriptor.languages.contains(language.primary)
    }

    private func descriptor(_ id: ModelID) throws -> ModelDescriptor {
        guard let descriptor = descriptors[id] else { throw AppError.modelNotInstalled(id) }
        return descriptor
    }

    // MARK: - Explicit model

    private func explicitPlan(model: ModelID, languages: [LanguageCode]?, request: RoutingRequest) throws -> EnginePlan {
        let descriptor = try descriptor(model)
        guard descriptor.kind == .asr else { throw AppError.other("\(model) is not a speech recognition model.") }
        for language in languages ?? [] where !covers(descriptor, language) {
            throw AppError.unsupportedLanguage(language)
        }
        var warnings: [String] = []
        if languages == nil, descriptor.languages.count == 1 || descriptor.runtime == .appleAsset {
            warnings.append(Warnings.noAutoDetect(descriptor.displayName))
        }
        let assignment = try makeAssignment(language: nil, descriptor: descriptor, request: request, warnings: &warnings)
        return EnginePlan(assignments: [assignment], warnings: warnings)
    }

    // MARK: - Auto

    private func autoPlan(languages: [LanguageCode]?, request: RoutingRequest) throws -> EnginePlan {
        var warnings: [String] = []
        guard let languages else {
            let model = request.useCase == .file ? fileWhisper(tier: request.tier) : RoutingTargets.whisperSmall
            if request.useCase != .file { warnings.append(Warnings.whisperLive) }
            warnings.append(Warnings.autoDetectNoSinhala)
            let assignment = try makeAssignment(language: nil, descriptor: descriptor(model), request: request, warnings: &warnings)
            return EnginePlan(assignments: [assignment], warnings: warnings)
        }

        var routed: [(language: LanguageCode, model: ModelID)] = []
        for language in languages {
            routed.append((language, try route(language, request: request, warnings: &warnings)))
        }
        let distinctModels = Set(routed.map(\.model))
        var assignments: [EngineAssignment] = []
        if distinctModels.count == 1, let model = distinctModels.first {
            assignments.append(try makeAssignment(language: nil, descriptor: descriptor(model), request: request, warnings: &warnings))
        } else {
            for (language, model) in routed {
                assignments.append(
                    try makeAssignment(language: language, descriptor: descriptor(model), request: request, warnings: &warnings))
            }
            let heavy = distinctModels.filter { descriptors[$0]?.runtime != .appleAsset }
            if request.tier == .tier8, heavy.count > 1 { warnings.append(Warnings.tier8Serialized) }
        }
        return EnginePlan(assignments: assignments, warnings: warnings)
    }

    private func fileWhisper(tier: HardwareTier) -> ModelID {
        tier == .tier8 ? RoutingTargets.whisperSmall : RoutingTargets.whisperLarge
    }

    private func route(_ language: LanguageCode, request: RoutingRequest, warnings: inout [String]) throws -> ModelID {
        // Stock Whisper is never routed for Sinhala (ADR-004): it goes to the dedicated model for every use case.
        if language.primary == .sinhala { return RoutingTargets.qwenSinhala }
        switch request.useCase {
        case .live, .dictation:
            if let apple = descriptors[RoutingTargets.appleSpeech], covers(apple, language) { return RoutingTargets.appleSpeech }
            let whisper = try descriptor(RoutingTargets.whisperSmall)
            guard covers(whisper, language) else { throw AppError.unsupportedLanguage(language) }
            if !warnings.contains(Warnings.whisperLive) { warnings.append(Warnings.whisperLive) }
            return RoutingTargets.whisperSmall
        case .file:
            let model = fileWhisper(tier: request.tier)
            guard covers(try descriptor(model), language) else { throw AppError.unsupportedLanguage(language) }
            return model
        }
    }

    // MARK: - Assignment

    private func makeAssignment(
        language: LanguageCode?, descriptor: ModelDescriptor, request: RoutingRequest, warnings: inout [String]
    ) throws -> EngineAssignment {
        guard let engine = descriptor.engine else { throw AppError.other("\(descriptor.id) has no engine.") }
        if descriptor.minTier > request.tier { warnings.append(Warnings.tier(descriptor.displayName, needs: descriptor.minTier)) }
        if descriptor.isExperimental { warnings.append(Warnings.experimental(descriptor.displayName)) }
        if descriptor.license.isNonCommercial { warnings.append(Warnings.nonCommercial(descriptor.displayName)) }
        // Apple assets are system-managed: the engine checks `AssetInventory` itself (LANG-AC-13).
        let requiresDownload = descriptor.runtime != .appleAsset && !request.installedModels.contains(descriptor.id)
        return EngineAssignment(
            language: language, engine: engine, model: descriptor.id, isExperimental: descriptor.isExperimental,
            requiresDownload: requiresDownload)
    }

    /// Warning texts (stable strings so UI and tests can match them).
    enum Warnings {
        static let autoDetectNoSinhala =
            "Auto-detect never selects the Sinhala model; choose Sinhala explicitly (stock Whisper does not support it)."
        static let whisperLive = "Live transcription with Whisper has higher latency than Apple Speech."
        static let tier8Serialized = "On 8 GB Macs only one heavy model stays loaded; language switches reload models."
        static func noAutoDetect(_ name: String) -> String { "\(name) cannot detect the language; pick a language explicitly." }
        static func tier(_ name: String, needs tier: HardwareTier) -> String {
            "\(name) is recommended for \(tier.rawValue) or higher hardware and may be slow or memory-hungry here."
        }
        static func experimental(_ name: String) -> String { "\(name) is experimental." }
        static func nonCommercial(_ name: String) -> String { "\(name) is licensed for non-commercial use only." }
    }
}
