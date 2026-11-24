import AppCore
import Foundation
import TextModelProfiles

/// Finite, checkpoint-specific generative translation adapters. Only the helper
/// links llama/Metal; the app and router share this vendor-free profile metadata.
public actor GenerativeTranslationEngine: TranslationEngine, PairSupportChecking {
    public nonisolated let profile: GenerativeProfile
    public nonisolated var id: EngineID { Self.engineID(for: profile) }
    public nonisolated var modelID: ModelID { Self.modelID(for: profile) }
    private let models: any ModelManaging
    private let runtime: any NLLBRuntime
    private let gate = TranslationOperationGate()

    public init(profile: GenerativeProfile, models: any ModelManaging, runtime: any NLLBRuntime) {
        self.profile = profile
        self.models = models
        self.runtime = runtime
    }

    public nonisolated static func engineID(for profile: GenerativeProfile) -> EngineID { EngineID(profile.rawValue) }
    public nonisolated static func modelID(for profile: GenerativeProfile) -> ModelID {
        switch profile {
        case .hymt18: "hymt2/1.8b-gguf-q4-k-m"
        case .hymt7: "hymt2/7b-gguf-q4-k-m"
        case .gemma4: "translategemma/4b-it-gguf-q4-k-m"
        case .gemma12: "translategemma/12b-it-gguf-q4-k-m"
        }
    }

    public func supports(_ pair: LanguagePair) async -> Bool {
        !pair.isSameWrittenLanguage && profile.supports(source: pair.source.rawValue, target: pair.target.rawValue)
    }

    public func supportedPairs() async -> Set<LanguagePair> {
        // Canonical base/script identities avoid a quadratic regional-alias list.
        // Exact regional requests are still checked by supports(_:).
        let languages = profile.languages.keys.map { LanguageCode($0) }.filter { $0 == $0.translationIdentity }
        return Set(languages.flatMap { source in
            languages.filter { !LanguagePair(source: source, target: $0).isSameWrittenLanguage }
                .map { LanguagePair(source: source, target: $0) }
        })
    }

    public nonisolated func translate(items: [TranslationItem], from: LanguageCode, to: LanguageCode) -> AsyncThrowingStream<TranslatedSegment, any Error> {
        // Generative helpers translate one segment at a time; never concatenate
        // independent rows into a prompt or invent a result-to-row alignment.
        streamInBatches(items: items, maxItems: 1, maxCharacters: 4_000, engine: id, lowConfidence: false) {
            try await self.run($0, from: from, to: to)
        }
    }

    private func run(_ texts: [String], from: LanguageCode, to: LanguageCode) async throws -> [String] {
        try await gate.withLease { try await self.runLocked(texts, from: from, to: to) }
    }

    private func runLocked(_ texts: [String], from: LanguageCode, to: LanguageCode) async throws -> [String] {
        guard !LanguagePair(source: from, target: to).isSameWrittenLanguage else { throw TranslationFailure.sameLanguage(from) }
        guard profile.languages[from.rawValue] != nil else { throw AppError.unsupportedLanguage(from) }
        guard profile.languages[to.rawValue] != nil else { throw AppError.unsupportedLanguage(to) }
        // Validate the real prompt before loading expensive weights.
        for text in texts { _ = try profile.content(text: text, source: from.rawValue, target: to.rawValue) }
        try Task.checkCancellation()
        guard case .installed = await models.state(of: modelID) else { throw AppError.modelNotInstalled(modelID) }
        let folder = try await models.location(of: modelID)
        do {
            try await runtime.load(modelFolder: folder)
            try Task.checkCancellation()
            return try await runtime.translate(texts, source: from.rawValue, target: to.rawValue)
        } catch is CancellationError { throw AppError.cancelled }
        catch let error as AppError {
            if case .engineFailure(_, let reason) = error { throw AppError.engineFailure(id, reason: reason) }
            throw error
        } catch { throw AppError.engineFailure(id, reason: error.localizedDescription) }
    }

    public func unload() async { await gate.cleanup { await self.unloadLocked() } }
    private func unloadLocked() async { await runtime.unload() }
}
