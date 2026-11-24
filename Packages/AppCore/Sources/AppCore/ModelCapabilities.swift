import Foundation

// SCR-011: structured model capabilities, ONE recommender, ONE compatibility check, and the download preflight types.
// Everything here is pure (no I/O) so it can be unit tested and shared by routing, onboarding, the sidebar and Settings.

// MARK: - Capabilities

public enum ModelTranslationLanguageMatching: String, Codable, Sendable, Hashable { case primary, exact }

/// Whether a model can label speakers, and how.
public enum SpeakerSupport: String, Codable, Sendable, Hashable { case none, offline, streaming }

/// Relative real-time-factor bucket. Unmeasured models carry `nil` rather than an invented value.
public enum SpeedTier: String, Codable, Sendable, Hashable, Comparable {
    case fast, balanced, slow
    private var rank: Int {
        switch self {
        case .fast: 0
        case .balanced: 1
        case .slow: 2
        }
    }
    public static func < (l: Self, r: Self) -> Bool { l.rank < r.rank }
}

/// Approximate working-set bucket. Unmeasured models carry `nil`.
public enum MemoryTier: String, Codable, Sendable, Hashable, Comparable {
    case light, moderate, heavy
    private var rank: Int {
        switch self {
        case .light: 0
        case .moderate: 1
        case .heavy: 2
        }
    }
    public static func < (l: Self, r: Self) -> Bool { l.rank < r.rank }
}

/// "This model is the recommended default for `useCase` on Macs from `minTier` up to `maxTier`."
public struct RecommendedUse: Codable, Hashable, Sendable {
    public var useCase: UseCase
    public var minTier: HardwareTier
    public var maxTier: HardwareTier
    /// Lower wins when several recommended models cover the request (e.g. Apple Speech before Whisper small for live).
    public var priority: Int
    public init(_ useCase: UseCase, minTier: HardwareTier = .tier8, maxTier: HardwareTier = .tier32Plus, priority: Int = 0) {
        self.useCase = useCase
        self.minTier = minTier
        self.maxTier = maxTier
        self.priority = priority
    }
    public func applies(to useCase: UseCase, tier: HardwareTier) -> Bool {
        self.useCase == useCase && tier >= minTier && tier <= maxTier
    }
}

/// What a model can do. Languages stay on ``ModelDescriptor/languages``. Decoding is tolerant: every field falls back to the
/// conservative ``standard`` value so descriptors persisted before SCR-011 still load.
public struct ModelCapabilities: Codable, Hashable, Sendable {
    /// Usable for streaming captions and dictation.
    public var live: Bool
    /// Usable for whole-file transcription (or, for non-ASR kinds, usable at all). `false` + `live == false` means the model is
    /// listed but cannot run in this build (see ``ModelDescriptor/isRunnable``).
    public var file: Bool
    public var wordTimestamps: Bool
    /// Can identify the spoken language itself (otherwise a language must be chosen).
    public var autoDetectLanguage: Bool
    public var speakerLabels: SpeakerSupport
    /// Translation-kind models: can translate between their languages.
    public var translation: Bool
    public var speed: SpeedTier?
    public var memory: MemoryTier?
    /// Where this model is the recommended default (see ``ModelRecommender``).
    public var recommendedUse: [RecommendedUse]
    public var translationPairs: Set<LanguagePair>?
    public var speechTranslationPairs: Set<LanguagePair>
    public var streaming: ModelStreamingImplementation?
    public var overlapRecognitionSpeakers: Int?
    public var translationLanguageMatching: ModelTranslationLanguageMatching

    public init(
        live: Bool = false, file: Bool = true, wordTimestamps: Bool = false, autoDetectLanguage: Bool = false,
        speakerLabels: SpeakerSupport = .none, translation: Bool = false, speed: SpeedTier? = nil, memory: MemoryTier? = nil,
        recommendedUse: [RecommendedUse] = [], translationPairs: Set<LanguagePair>? = nil,
        speechTranslationPairs: Set<LanguagePair> = [], streaming: ModelStreamingImplementation? = nil,
        overlapRecognitionSpeakers: Int? = nil, translationLanguageMatching: ModelTranslationLanguageMatching = .primary
    ) {
        self.live = live
        self.file = file
        self.wordTimestamps = wordTimestamps
        self.autoDetectLanguage = autoDetectLanguage
        self.speakerLabels = speakerLabels
        self.translation = translation
        self.speed = speed
        self.memory = memory
        self.recommendedUse = recommendedUse
        self.translationPairs = translationPairs
        self.speechTranslationPairs = speechTranslationPairs
        self.streaming = streaming
        self.overlapRecognitionSpeakers = overlapRecognitionSpeakers
        self.translationLanguageMatching = translationLanguageMatching
    }

    /// Conservative default for models with no recorded capabilities (custom imports, legacy state): file transcription only.
    public static let standard = ModelCapabilities()

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = ModelCapabilities.standard
        self.init(
            live: try c.decodeIfPresent(Bool.self, forKey: .live) ?? base.live,
            file: try c.decodeIfPresent(Bool.self, forKey: .file) ?? base.file,
            wordTimestamps: try c.decodeIfPresent(Bool.self, forKey: .wordTimestamps) ?? base.wordTimestamps,
            autoDetectLanguage: try c.decodeIfPresent(Bool.self, forKey: .autoDetectLanguage) ?? base.autoDetectLanguage,
            speakerLabels: try c.decodeIfPresent(SpeakerSupport.self, forKey: .speakerLabels) ?? base.speakerLabels,
            translation: try c.decodeIfPresent(Bool.self, forKey: .translation) ?? base.translation,
            speed: try c.decodeIfPresent(SpeedTier.self, forKey: .speed), memory: try c.decodeIfPresent(MemoryTier.self, forKey: .memory),
            recommendedUse: try c.decodeIfPresent([RecommendedUse].self, forKey: .recommendedUse) ?? [],
            translationPairs: try c.decodeIfPresent(Set<LanguagePair>.self, forKey: .translationPairs),
            speechTranslationPairs: try c.decodeIfPresent(Set<LanguagePair>.self, forKey: .speechTranslationPairs) ?? [],
            streaming: try c.decodeIfPresent(ModelStreamingImplementation.self, forKey: .streaming),
            overlapRecognitionSpeakers: try c.decodeIfPresent(Int.self, forKey: .overlapRecognitionSpeakers),
            translationLanguageMatching: try c.decodeIfPresent(ModelTranslationLanguageMatching.self, forKey: .translationLanguageMatching) ?? .primary)
    }
}

extension ModelDescriptor {
    /// `true` when this build can actually run the model. A listed model with neither `live` nor `file` capability is
    /// hidden from language pickers and never recommended (e.g. Parakeet, which has no registered engine yet).
    public var isRunnable: Bool { capabilities.live || capabilities.file }

    public func supportsTranslation(_ pair: LanguagePair) -> Bool {
        guard kind == .translation, isRunnable, capabilities.translation, pair.source != pair.target else { return false }
        if capabilities.translationLanguageMatching == .exact {
            guard languages.contains(pair.source), languages.contains(pair.target) else { return false }
            return capabilities.translationPairs?.contains(pair) ?? true
        }
        if let pairs = capabilities.translationPairs {
            return pairs.contains(pair) || pairs.contains(LanguagePair(source: pair.source.primary, target: pair.target.primary))
        }
        return pair.source.primary != pair.target.primary && covers(pair.source) && covers(pair.target)
    }

    /// `true` when the model covers `language` exactly or by its primary subtag.
    public func covers(_ language: LanguageCode) -> Bool { languages.contains(language) || languages.contains(language.primary) }
}

// MARK: - Compatibility

/// What a screen needs from an ASR model.
public struct ModelRequirement: Sendable, Hashable {
    public var useCase: UseCase
    /// Languages that must all be covered. Empty means "no specific language".
    public var languages: Set<LanguageCode>
    /// The user chose Auto-detect, so the model must identify the language itself.
    public var needsAutoDetect: Bool
    public var needsWordTimestamps: Bool
    public init(useCase: UseCase, languages: Set<LanguageCode> = [], needsAutoDetect: Bool = false, needsWordTimestamps: Bool = false) {
        self.useCase = useCase
        self.languages = languages
        self.needsAutoDetect = needsAutoDetect
        self.needsWordTimestamps = needsWordTimestamps
    }
}

/// Why a model is greyed out. `message` is a short, user-facing sentence fragment (stable strings; tests match them).
public enum ModelIncompatibility: Hashable, Sendable {
    case notSpeechRecognition(ModelKind)
    case notRunnableInThisBuild
    case engineNotRegistered(EngineID)
    case languageUnsupported(missing: [LanguageCode])
    case noLiveStreaming
    case noFileTranscription
    case noWordTimestamps
    case noAutoDetect
    case needsTier(HardwareTier)

    public var message: String {
        switch self {
        case .notSpeechRecognition: "Not a speech recognition model"
        case .notRunnableInThisBuild: "Not available in this version of Earmark"
        case .engineNotRegistered: "Its engine is not available in this version of Earmark"
        case .languageUnsupported(let missing): "No \(missing.map(\.rawValue).joined(separator: ", ")) support"
        case .noLiveStreaming: "No live streaming"
        case .noFileTranscription: "Cannot transcribe files"
        case .noWordTimestamps: "No word timestamps"
        case .noAutoDetect: "Cannot detect the language automatically"
        case .needsTier(let tier): "Needs \(Self.memoryText(tier)) or more"
        }
    }

    static func memoryText(_ tier: HardwareTier) -> String {
        switch tier {
        case .tier8: "an 8 GB Mac"
        case .tier16: "a 16 GB Mac"
        case .tier32Plus: "a 32 GB Mac"
        }
    }
}

public enum ModelAvailability: Sendable, Hashable {
    case ok
    case disabled([ModelIncompatibility])
    public var isOK: Bool { self == .ok }
    /// Empty when `.ok`.
    public var reasons: [ModelIncompatibility] {
        if case .disabled(let reasons) = self { return reasons }
        return []
    }
}

/// The one compatibility check: every picker greys rows using this and shows ``ModelAvailability/reasons``.
public enum ModelCompatibility {
    /// - Parameters:
    ///   - availableEngines: engines registered in this build; `nil` skips the check.
    public static func evaluate(
        _ model: ModelDescriptor, for requirement: ModelRequirement, tier: HardwareTier, availableEngines: Set<EngineID>? = nil
    ) -> ModelAvailability {
        guard model.kind == .asr else { return .disabled([.notSpeechRecognition(model.kind)]) }
        var reasons: [ModelIncompatibility] = []
        if !model.isRunnable {
            reasons.append(.notRunnableInThisBuild)
        } else {
            switch requirement.useCase {
            case .file: if !model.capabilities.file { reasons.append(.noFileTranscription) }
            case .live, .dictation: if !model.capabilities.live { reasons.append(.noLiveStreaming) }
            }
        }
        if let engine = model.engine, let available = availableEngines, !available.contains(engine), model.isRunnable {
            reasons.append(.engineNotRegistered(engine))
        }
        let missing = requirement.languages.filter { !model.covers($0) }.sorted()
        if !missing.isEmpty { reasons.append(.languageUnsupported(missing: missing)) }
        if requirement.needsAutoDetect && !model.capabilities.autoDetectLanguage { reasons.append(.noAutoDetect) }
        if requirement.needsWordTimestamps && !model.capabilities.wordTimestamps { reasons.append(.noWordTimestamps) }
        if model.minTier > tier { reasons.append(.needsTier(model.minTier)) }
        return reasons.isEmpty ? .ok : .disabled(reasons)
    }
}

// MARK: - Recommendation

/// The one tier -> default-model rule (replaces the copies in the engine router, `PreferredModel` and onboarding).
/// Data-driven: a model is recommended where its ``ModelCapabilities/recommendedUse`` says so.
public enum ModelRecommender {
    /// The recommended ASR model.
    ///
    /// - Parameters:
    ///   - language: `nil` means auto-detect, so only models that identify the language themselves qualify.
    ///   - availableEngines: engines registered in this build; `nil` skips the check.
    ///   - allowFallback: when `false`, only an explicit ``RecommendedUse`` rule can answer (the table-driven router).
    /// - Returns: A model with a matching ``RecommendedUse`` rule (non-commercial models are never chosen; an experimental
    ///   model only when its own rule names this case), else (when `allowFallback`) the best compatible model that fits `tier`,
    ///   else `nil`.
    public static func recommendedModel(
        for tier: HardwareTier, useCase: UseCase, language: LanguageCode? = nil, in catalog: [ModelDescriptor],
        availableEngines: Set<EngineID>? = nil, allowFallback: Bool = true
    ) -> ModelDescriptor? {
        let requirement = ModelRequirement(
            useCase: useCase, languages: language.map { [$0] } ?? [], needsAutoDetect: language == nil)
        let eligible = catalog.enumerated().filter { _, model in
            !model.license.isNonCommercial && model.kind == .asr
                && ModelCompatibility.evaluate(model, for: requirement, tier: .tier32Plus, availableEngines: availableEngines).isOK
        }
        let ruled = eligible.compactMap { offset, model -> (Int, Int, Bool, ModelDescriptor)? in
            guard let rule = model.capabilities.recommendedUse.filter({ $0.applies(to: useCase, tier: tier) }).map(\.priority).min()
            else { return nil }
            return (rule, offset, model.isExperimental, model)
        }
        if let best = ruled.min(by: { ($0.2 ? 1 : 0, $0.0, $0.1) < ($1.2 ? 1 : 0, $1.0, $1.1) }) { return best.3 }
        guard allowFallback else { return nil }
        // No explicit rule: only established models qualify for automatic fallback.
        let fitting = eligible.map(\.element).filter { $0.minTier <= tier && !$0.isExperimental }
        return fitting.min { a, b in
            (a.isExperimental ? 1 : 0, -a.sizeBytes, a.id.rawValue) < (b.isExperimental ? 1 : 0, -b.sizeBytes, b.id.rawValue)
        }
    }
}

// MARK: - Download preflight (licence / hardware / disk)

extension LicenseInfo {
    /// Licences that need an explicit acknowledgement before download: share-alike terms or an unverified licence.
    public var needsAcknowledgement: Bool {
        let identifier = spdx.uppercased()
        return identifier.contains("-SA") || identifier == "NOASSERTION"
            || (identifier.hasPrefix("LICENSEREF-") && identifier != "LICENSEREF-APPLE-SYSTEM")
    }
}

public enum ModelPreflightIssue: Hashable, Sendable {
    case nonCommercialLicense(spdx: String)
    case licenseNotice(spdx: String, attribution: String?)
    case hardwareTier(required: HardwareTier, available: HardwareTier)
    /// Informational: roughly a gigabyte or more.
    case largeDownload(bytes: Int64)
    case insufficientDisk(needed: Int64, available: Int64)

    /// Blocks the download outright.
    public var isBlocking: Bool { if case .insufficientDisk = self { true } else { false } }
    /// Needs the user's confirmation (see ``ModelDownloadConsenting``).
    public var requiresConsent: Bool {
        switch self {
        case .nonCommercialLicense, .licenseNotice, .hardwareTier: true
        case .largeDownload, .insufficientDisk: false
        }
    }

    public var message: String {
        switch self {
        case .nonCommercialLicense(let spdx): "Licensed \(spdx): non-commercial use only."
        case .licenseNotice(let spdx, _): "Licensed \(spdx): review the licence terms before use."
        case .hardwareTier(let required, _): "Recommended for \(ModelIncompatibility.memoryText(required)) or more; this Mac may be slow or run out of memory."
        case .largeDownload(let bytes): "Large download: \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))."
        case .insufficientDisk(let needed, let available):
            "Not enough free disk space: needs \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)), "
                + "\(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) available."
        }
    }
}

/// Result of ``ModelManaging/preflight(_:)``: show `issues`, ask consent when `requiresConsent`, refuse when `isBlocking`.
public struct ModelPreflightResult: Sendable, Hashable {
    public var model: ModelID
    public var displayName: String
    /// Catalog download size (verified against the Hugging Face manifest by the catalog tests).
    public var downloadBytes: Int64
    /// Free bytes on the models volume, when known.
    public var freeDiskBytes: Int64?
    public var issues: [ModelPreflightIssue]
    public init(
        model: ModelID, displayName: String, downloadBytes: Int64, freeDiskBytes: Int64? = nil, issues: [ModelPreflightIssue] = []
    ) {
        self.model = model
        self.displayName = displayName
        self.downloadBytes = downloadBytes
        self.freeDiskBytes = freeDiskBytes
        self.issues = issues
    }
    public var isBlocking: Bool { issues.contains { $0.isBlocking } }
    public var requiresConsent: Bool { issues.contains { $0.requiresConsent } }
    /// `true` when the download can start without asking anything.
    public var isClear: Bool { issues.allSatisfy { !$0.isBlocking && !$0.requiresConsent } }
}

/// Consent hook the app installs on the model manager. Called at most once per model while consent is required and not yet
/// recorded; returning `false` aborts `ensureAvailable` with ``AppError/cancelled``.
public protocol ModelDownloadConsenting: Sendable {
    func confirmDownload(_ preflight: ModelPreflightResult) async -> Bool
}
