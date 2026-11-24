import AppCore
import Foundation

/// Six independently installed Marian checkpoints, each with exactly one direction.
/// This adapter accepts the curated native recipes; it does not imply arbitrary OPUS compatibility.
public actor OPUSTranslationEngine: TranslationEngine, PairSupportChecking {
    public nonisolated let id: EngineID = "opus-mt"
    public static let modelsByPair: [LanguagePair: ModelID] = Dictionary(uniqueKeysWithValues:
        ["de", "fr", "es"].flatMap { language -> [(LanguagePair, ModelID)] in
            let code = LanguageCode(language)
            return [
                (LanguagePair(source: .english, target: code), ModelID("opus/en-\(language)-ct2-int8")),
                (LanguagePair(source: code, target: .english), ModelID("opus/\(language)-en-ct2-int8")),
            ]
        })

    private let locate: @Sendable (ModelID) async throws -> URL
    private let runtime: any NLLBRuntime
    // Hold across load + inference + unload, including actor suspension points.
    // A single Marian worker must never change packs underneath another request.
    private let gate = TranslationOperationGate()

    public init(models: any ModelManaging, runtime: any NLLBRuntime) {
        self.locate = { model in
            guard case .installed = await models.state(of: model) else { throw AppError.modelNotInstalled(model) }
            return try await models.location(of: model)
        }
        self.runtime = runtime
    }

    init(runtime: any NLLBRuntime, locate: @escaping @Sendable (ModelID) async throws -> URL) {
        self.runtime = runtime
        self.locate = locate
    }

    public nonisolated static func model(for pair: LanguagePair) -> ModelID? {
        modelsByPair[LanguagePair(source: pair.source.primary, target: pair.target.primary)]
    }

    public func supportedPairs() async -> Set<LanguagePair> { Set(Self.modelsByPair.keys) }
    public func supports(_ pair: LanguagePair) async -> Bool { Self.model(for: pair) != nil }

    public nonisolated func translate(
        items: [TranslationItem], from: LanguageCode, to: LanguageCode
    ) -> AsyncThrowingStream<TranslatedSegment, any Error> {
        streamInBatches(items: items, maxItems: 8, maxCharacters: 1_200, engine: id, lowConfidence: false) {
            try await self.run($0, from: from, to: to)
        }
    }

    private func run(_ texts: [String], from: LanguageCode, to: LanguageCode) async throws -> [String] {
        try await gate.withLease { try await self.runLocked(texts, from: from, to: to) }
    }

    private func runLocked(_ texts: [String], from: LanguageCode, to: LanguageCode) async throws -> [String] {
        guard let model = Self.model(for: LanguagePair(source: from, target: to)) else {
            throw TranslationFailure.noEngine(LanguagePair(source: from, target: to))
        }
        try Task.checkCancellation()
        let folder = try await locate(model)
        do {
            try await runtime.load(modelFolder: folder)
            try Task.checkCancellation()
            return try await runtime.translate(texts, source: from.primary.rawValue, target: to.primary.rawValue)
        } catch is CancellationError {
            throw AppError.cancelled
        } catch let error as AppError {
            if case .engineFailure(_, let reason) = error { throw AppError.engineFailure(id, reason: reason) }
            throw error
        } catch {
            throw AppError.engineFailure(id, reason: error.localizedDescription)
        }
    }

    public func unload() async {
        await gate.cleanup { await self.unloadLocked() }
    }

    private func unloadLocked() async {
        await runtime.unload()
    }


}
