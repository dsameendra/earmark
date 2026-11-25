import AppCore
import Foundation
import Translation

public enum AppleLanguageStatus: Sendable, Equatable { case installed, supported, unsupported }

/// Seam over Apple's Translation framework so the engine is testable without language packs.
public protocol AppleTranslationBackend: Sendable {
    func supportedLanguages() async -> Set<LanguageCode>
    func status(from: LanguageCode, to: LanguageCode) async -> AppleLanguageStatus
    /// Translates in order. Only called for installed pairs.
    func translate(_ texts: [String], from: LanguageCode, to: LanguageCode) async throws -> [String]
}

/// Real backend. Uses the programmatic `TranslationSession(installedSource:target:)` (macOS 26.0+, verified in the SDK interface),
/// so no SwiftUI `.translationTask` host view is needed for installed pairs. Language packs that are not installed are reported
/// as `.supported`; the engine maps that to `AppError.modelNotInstalled` and the UI performs the one-time system download.
public struct SystemAppleTranslationBackend: AppleTranslationBackend {
    public init() {}

    private static func language(_ code: LanguageCode) -> Locale.Language { Locale.Language(identifier: Self.appleIdentifier(code)) }
    /// Apple distinguishes script variants; bare codes work for most, but zh needs a script.
    static func appleIdentifier(_ code: LanguageCode) -> String {
        switch code.rawValue {
        case "zh": "zh-Hans"
        case "no": "nb"
        default: code.rawValue
        }
    }

    public func supportedLanguages() async -> Set<LanguageCode> {
        let langs = await LanguageAvailability().supportedLanguages
        return Set(
            langs.compactMap { lang -> LanguageCode? in
                guard lang.languageCode != nil else { return nil }
                return LanguageCode(lang.minimalIdentifier.replacingOccurrences(of: "_", with: "-"))
            })
    }

    public func status(from: LanguageCode, to: LanguageCode) async -> AppleLanguageStatus {
        switch await LanguageAvailability().status(from: Self.language(from), to: Self.language(to)) {
        case .installed: .installed
        case .supported: .supported
        case .unsupported: .unsupported
        @unknown default: .unsupported
        }
    }

    public func translate(_ texts: [String], from: LanguageCode, to: LanguageCode) async throws -> [String] {
        let session = TranslationSession(installedSource: Self.language(from), target: Self.language(to))
        let requests = texts.enumerated().map { TranslationSession.Request(sourceText: $1, clientIdentifier: String($0)) }
        let responses = try await session.translations(from: requests)
        return try Self.orderedResponses(responses.map { ($0.clientIdentifier, $0.targetText) }, count: texts.count)
    }
    /// Apple may return results in a different order. Every identifier must be
    /// unique and in range before any result is attached to a transcript row.
    static func orderedResponses(_ responses: [(String?, String)], count: Int) throws -> [String] {
        var result = [String?](repeating: nil, count: count)
        for (id, text) in responses {
            guard let id, let index = Int(id), result.indices.contains(index), result[index] == nil,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppError.engineFailure(TranslationEngineIDs.apple, reason: "Apple returned an invalid or empty translation response. Original text has been kept.")
            }
            result[index] = text
        }
        guard result.allSatisfy({ $0 != nil }) else {
            throw AppError.engineFailure(TranslationEngineIDs.apple, reason: "Apple returned an incomplete translation batch. Original text has been kept.")
        }
        return result.compactMap { $0 }
    }

}

/// Apple Translation engine (router priority one). Errors: not-installed packs surface as `AppError.modelNotInstalled`.
public struct AppleTranslationEngine: TranslationEngine, PairSupportChecking {
    public var id: EngineID { TranslationEngineIDs.apple }
    private let backend: any AppleTranslationBackend
    private let maxItems: Int
    private let maxCharacters: Int

    public init(backend: any AppleTranslationBackend = SystemAppleTranslationBackend(), maxItems: Int = 24, maxCharacters: Int = 4_000) {
        self.backend = backend
        self.maxItems = maxItems
        self.maxCharacters = maxCharacters
    }

    public func supports(_ pair: LanguagePair) async -> Bool {
        guard pair.source.primary != .sinhala, pair.target.primary != .sinhala, !pair.isSameWrittenLanguage else { return false }
        return await backend.status(from: pair.source.translationIdentity, to: pair.target.translationIdentity) != .unsupported
    }

    /// All ordered pairs Apple can serve (can be slow: one availability query per pair; prefer `supports`).
    public func supportedPairs() async -> Set<LanguagePair> {
        let langs = await backend.supportedLanguages().filter { $0 != .sinhala }.sorted()
        var pairs = Set<LanguagePair>()
        for a in langs {
            for b in langs where a != b {
                if await backend.status(from: a, to: b) != .unsupported { pairs.insert(LanguagePair(source: a, target: b)) }
            }
        }
        return pairs
    }

    public func translate(items: [TranslationItem], from: LanguageCode, to: LanguageCode) -> AsyncThrowingStream<TranslatedSegment, any Error> {
        let backend = backend
        let (source, target) = (from.translationIdentity, to.translationIdentity)
        let engine = id
        return streamInBatches(
            items: items, maxItems: maxItems, maxCharacters: maxCharacters, engine: engine, lowConfidence: false
        ) { texts in
            if source.primary == .sinhala || target.primary == .sinhala { throw AppError.unsupportedLanguage(.sinhala) }
            switch await backend.status(from: source, to: target) {
            case .unsupported: throw AppError.unsupportedLanguage(to)
            case .supported: throw AppError.modelNotInstalled(TranslationEngineIDs.appleModel)
            case .installed: break
            }
            do {
                return try await backend.translate(texts, from: source, to: target)
            } catch is CancellationError {
                throw AppError.cancelled
            } catch let error as AppError {
                throw error
            } catch {
                throw Self.map(error, to: to)
            }
        }
    }

    static func map(_ error: any Error, to: LanguageCode) -> AppError {
        if TranslationError.notInstalled ~= error { return .modelNotInstalled(TranslationEngineIDs.appleModel) }
        if TranslationError.unsupportedLanguagePairing ~= error || TranslationError.unsupportedSourceLanguage ~= error
            || TranslationError.unsupportedTargetLanguage ~= error
        {
            return .unsupportedLanguage(to)
        }
        if TranslationError.alreadyCancelled ~= error { return .cancelled }
        return .engineFailure(TranslationEngineIDs.apple, reason: error.localizedDescription)
    }
}
