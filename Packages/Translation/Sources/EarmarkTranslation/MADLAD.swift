import AppCore
import Foundation

/// Explicit base-language mapping for the initial native T5 integration.
/// The upstream model has wider coverage; tokenizer tags alone are not a quality certification.
public enum MADLADLanguages {
    public static let codes: [LanguageCode: String] = Dictionary(uniqueKeysWithValues:
        ["si", "en", "ta", "hi", "bn", "ur", "te", "ml", "kn", "mr", "gu", "pa", "ne",
         "de", "fr", "es", "it", "pt", "nl", "ja", "ko", "zh", "ar", "ru", "id", "th", "vi"]
            .map { (LanguageCode($0), $0) })
    public static let languages = Set(codes.keys)
}

/// Native MADLAD-400 T5 translation. Source language is validated, while the model
/// recognizes it from the text; the runtime supplies the exact <2target> prefix.
public actor MADLADEngine: TranslationEngine, PairSupportChecking {
    public nonisolated let id: EngineID = "madlad"
    public static let modelID: ModelID = "madlad/400-3b-mt-ct2-int8"
    private let models: any ModelManaging
    private let runtime: any NLLBRuntime
    private let gate = TranslationOperationGate()

    public init(models: any ModelManaging, runtime: any NLLBRuntime) {
        self.models = models
        self.runtime = runtime
    }

    public func supportedPairs() async -> Set<LanguagePair> {
        Set(MADLADLanguages.languages.flatMap { source in
            MADLADLanguages.languages.filter { $0 != source }.map { LanguagePair(source: source, target: $0) }
        })
    }

    public func supports(_ pair: LanguagePair) async -> Bool {
        pair.source != pair.target && MADLADLanguages.codes[pair.source] != nil
            && MADLADLanguages.codes[pair.target] != nil
    }

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
        guard from != to else { throw TranslationFailure.sameLanguage(from) }
        guard let source = MADLADLanguages.codes[from] else { throw AppError.unsupportedLanguage(from) }
        guard let target = MADLADLanguages.codes[to] else { throw AppError.unsupportedLanguage(to) }
        try Task.checkCancellation()
        guard case .installed = await models.state(of: Self.modelID) else { throw AppError.modelNotInstalled(Self.modelID) }
        let folder = try await models.location(of: Self.modelID)
        do {
            try await runtime.load(modelFolder: folder)
            try Task.checkCancellation()
            return try await runtime.translate(texts, source: source, target: target)
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
