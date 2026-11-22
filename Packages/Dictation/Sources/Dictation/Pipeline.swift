import AppCore
import Foundation

/// Text ready to insert, with how it got there.
public struct FinalizedDictation: Sendable, Equatable {
    public var text: String
    public var language: LanguageCode?
    /// True when translate-before-insert failed and the original text is used instead (DICT-AC-08).
    public var translationFailed: Bool
}

/// Post-processing chain for dictation (DICT-AC-07, DICT-AC-08): ignore rules, replacement rules (both through the
/// shared `TranscriptPostProcessor`), optional auto-punctuation, then optional translation.
public struct DictationPipeline: Sendable {
    private let postProcessor: any TranscriptPostProcessor
    private let rules: any RuleRepository
    private let translation: (any TranslationRouter)?

    public init(postProcessor: any TranscriptPostProcessor, rules: any RuleRepository, translation: (any TranslationRouter)? = nil) {
        self.postProcessor = postProcessor
        self.rules = rules
        self.translation = translation
    }

    /// Returns `nil` when nothing is left to insert (empty after processing).
    public func finalize(segments: [Segment], settings: DictationSettings) async -> FinalizedDictation? {
        let ignore = ((try? await rules.ignoreRules()) ?? []).filter { $0.isEnabled && $0.deletedAt == nil }
        let replace = ((try? await rules.replacementRules()) ?? []).filter { $0.isEnabled && $0.deletedAt == nil }
        let context = PostProcessingContext(ignoreRules: ignore, replacementRules: replace)
        let processed = await postProcessor.process(segments, context: context).filter { !$0.isIgnored }
        let joined = processed.map(\.text).joined(separator: " ")
        let text = DictationTextFormatter.clean(joined, autoPunctuation: settings.autoPunctuation)
        guard !text.isEmpty else { return nil }

        let language = processed.compactMap(\.languageCode).first ?? Self.fixedLanguage(settings.languageMode)
        guard settings.translateBeforeInsert, let target = settings.translationTarget, let language,
            language.primary != target.primary, let translation
        else { return FinalizedDictation(text: text, language: language, translationFailed: false) }

        do {
            let engine = try await translation.engine(for: LanguagePair(source: language, target: target))
            let items = [TranslationItem(segmentID: processed.first?.id ?? SegmentID(), text: text)]
            var out: [String] = []
            for try await piece in engine.translate(items: items, from: language, to: target) { out.append(piece.text) }
            let translated = out.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !translated.isEmpty else { throw DictationError.translationFailed("empty result") }
            return FinalizedDictation(text: translated, language: target, translationFailed: false)
        } catch {
            return FinalizedDictation(text: text, language: language, translationFailed: true)
        }
    }

    static func fixedLanguage(_ mode: LanguageMode) -> LanguageCode? {
        if case .single(let l) = mode { return l }
        return nil
    }
}

// MARK: - Engine selection (DICT-AC-09)

public struct ResolvedDictationEngine: Sendable {
    public var engine: any TranscriptionEngine
    public var model: ModelID?
    /// True for engines flagged experimental (Sinhala); the HUD shows a badge.
    public var isExperimental: Bool
    public init(engine: any TranscriptionEngine, model: ModelID? = nil, isExperimental: Bool = false) {
        self.engine = engine
        self.model = model
        self.isExperimental = isExperimental
    }
}

/// Chooses and returns the engine for a dictation session.
public typealias DictationEngineProvider = @Sendable (DictationSettings) async throws -> ResolvedDictationEngine

/// Routes through `EngineRouter` with `UseCase.dictation` and looks the chosen engine up in `engines`.
public struct RoutedEngineProvider: Sendable {
    private let router: any EngineRouter
    private let tier: @Sendable () async -> HardwareTier
    private let installedModels: @Sendable () async -> Set<ModelID>
    private let engines: [EngineID: any TranscriptionEngine]

    public init(
        router: any EngineRouter, tier: @escaping @Sendable () async -> HardwareTier,
        installedModels: @escaping @Sendable () async -> Set<ModelID>, engines: [EngineID: any TranscriptionEngine]
    ) {
        self.router = router
        self.tier = tier
        self.installedModels = installedModels
        self.engines = engines
    }

    public func resolve(_ settings: DictationSettings) async throws -> ResolvedDictationEngine {
        let request = RoutingRequest(
            languageMode: settings.languageMode, useCase: .dictation, tier: await tier(),
            installedModels: await installedModels(), explicitModel: settings.modelID)
        let plan = try router.plan(for: request)
        guard let assignment = plan.assignments.first else { throw AppError.other("No engine available for dictation") }
        if assignment.requiresDownload, let model = assignment.model { throw AppError.modelNotInstalled(model) }
        guard let engine = engines[assignment.engine] else {
            throw AppError.engineFailure(assignment.engine, reason: "engine not registered")
        }
        return ResolvedDictationEngine(engine: engine, model: assignment.model, isExperimental: assignment.isExperimental)
    }

    /// Adapter for ``DictationController``.
    public var provider: DictationEngineProvider { { try await self.resolve($0) } }
}
