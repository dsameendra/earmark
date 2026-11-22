import AppCore
import CoreML
import Foundation
import WhisperKit

/// Pure scoring of a restricted language distribution (testable without a model).
enum RestrictedLanguageScoring {
    /// Scores `candidates` from the first-decoder-step logits of **all** language tokens.
    ///
    /// - Parameters:
    ///   - logits: Raw decoder logits keyed by Whisper language code (`"en"`, `"si"`, ...), covering every language token.
    ///   - candidates: Allowed languages (primary subtags are compared); empty means "all".
    ///   - minimumMass: Smallest total probability (under the unrestricted softmax over all language tokens) that the
    ///     candidates must hold. Below it the audio is probably in a language outside the set, and the result is empty so the
    ///     caller keeps the previous language instead of mislabelling the segment.
    /// - Returns: Candidates sorted by descending probability, **renormalised over the candidates** (the restricted
    ///   distribution); empty when none of the candidates has a token or the mass floor is not reached.
    static func scores(logits: [String: Float], candidates: Set<LanguageCode>, minimumMass: Double) -> [LanguageScore] {
        guard let maxLogit = logits.values.max() else { return [] }
        let exps = logits.mapValues { Double(exp($0 - maxLogit)) }
        let total = exps.values.reduce(0, +)
        guard total > 0, total.isFinite else { return [] }
        let wanted = Set(candidates.map { $0.primary.rawValue })
        let selected = exps.filter { wanted.isEmpty || wanted.contains($0.key) }
        let mass = selected.values.reduce(0, +)
        guard mass > 0, mass / total >= minimumMass else { return [] }
        return selected.map { LanguageScore(language: LanguageCode($0.key), probability: $0.value / mass) }
            .sorted { $0.probability > $1.probability }
    }
}

/// Outcome of a language-ID run that did not produce scores.
enum LanguageIDError: Error, Equatable {
    /// The Core ML pipeline did not answer in time; the model handle was discarded.
    case timedOut
}

extension WhisperKitEngine {
    /// Upper bound for one language-ID prediction (mel + encoder + one decoder step; about 0.1 to 3 s in practice).
    static let languageIDTimeout: Duration = .seconds(20)

    /// Identifies the language of `samples` (first ~30 s) among `candidates`.
    ///
    /// Replaces WhisperKit's `detectLangauge`, which was observed to wedge (T25). This runs the same three Core ML stages
    /// (log-mel, encoder, **one** decoder step from `<|startoftranscript|>`) through WhisperKit's public components, reads
    /// only the language-token logits, and scores them with ``RestrictedLanguageScoring``: nothing else is sampled, no shared
    /// logits-filter state is touched, and nothing is downloaded.
    ///
    /// ### Hang guard
    /// The prediction runs under ``withDeadline(_:operation:)`` inside the engine gate. On timeout the engine discards its
    /// model handle (the wedged call may still hold it; the next use reloads a fresh `WhisperKit`) and installs a new gate so
    /// queued work is not blocked behind the stuck call, then throws ``LanguageIDError/timedOut``.
    ///
    /// - Returns: restricted, renormalised scores (see ``RestrictedLanguageScoring``).
    /// - Throws: ``LanguageIDError/timedOut``, `AppError` for any engine failure, `AppError.cancelled` on cancellation.
    func detectLanguage(
        samples: [Float], candidates: Set<LanguageCode>, model: ModelID, minimumMass: Double = 0.02,
        timeout: Duration = WhisperKitEngine.languageIDTimeout
    ) async throws -> [LanguageScore] {
        let handle = try await loadedHandle(for: model)
        do {
            let logits = try await gate.run {
                try await withDeadline(timeout) { try await Self.languageLogits(kit: handle.kit, samples: samples) }
            }
            return RestrictedLanguageScoring.scores(logits: logits, candidates: candidates, minimumMass: minimumMass)
        } catch is DeadlineExceeded {
            discard(handle)
            throw LanguageIDError.timedOut
        } catch {
            throw AppError.mapping(error, engine: id)
        }
    }

    /// Drops `stale` (a handle whose Core ML call never returned) and unblocks the gate.
    private func discard(_ stale: WhisperHandle) {
        if handle === stale { handle = nil }
        gate = AsyncGate()
    }

    /// First decoder step: logits of every language token, keyed by language code.
    static func languageLogits(kit: WhisperKit, samples: [Float]) async throws -> [String: Float] {
        guard kit.textDecoder.isModelMultilingual else {
            throw AppError.other("This Whisper model is English-only and cannot identify languages.")
        }
        guard let tokenizer = kit.tokenizer else { throw WhisperError.tokenizerUnavailable() }
        let window = kit.featureExtractor.windowSamples ?? Constants.defaultWindowSamples
        guard let padded = kit.audioProcessor.padOrTrim(fromArray: samples, startAt: 0, toLength: window) else {
            throw WhisperError.transcriptionFailed("Audio samples are nil")
        }
        guard let mel = try await kit.featureExtractor.logMelSpectrogram(fromAudio: padded) else {
            throw WhisperError.transcriptionFailed("Mel output is nil")
        }
        guard let encoded = try await kit.audioEncoder.encodeFeatures(mel) as? MLMultiArray else {
            throw WhisperError.transcriptionFailed("Encoder output is nil")
        }
        let start = tokenizer.specialTokens.startOfTranscriptToken
        guard let inputs = try kit.textDecoder.prepareDecoderInputs(withPrompt: [start]) as? DecodingInputs else {
            throw WhisperError.prepareDecoderInputsFailed("Unexpected decoder input type")
        }
        inputs.inputIds[0] = NSNumber(value: start)
        inputs.cacheLength[0] = NSNumber(value: 0)
        let output =
            try await kit.textDecoder.predictLogits(
                TextDecoderMLMultiArrayInputType(
                    inputIds: inputs.inputIds, cacheLength: inputs.cacheLength, keyCache: inputs.keyCache,
                    valueCache: inputs.valueCache, kvCacheUpdateMask: inputs.kvCacheUpdateMask, encoderOutputEmbeds: encoded,
                    decoderKeyPaddingMask: inputs.decoderKeyPaddingMask)) as? TextDecoderMLMultiArrayOutputType
        guard let logits = output?.logits else { throw WhisperError.decodingLogitsFailed() }
        try Task.checkCancellation()
        var result: [String: Float] = [:]
        for token in tokenizer.allLanguageTokens {
            guard let name = tokenizer.convertIdToToken(token) else { continue }
            let code = name.trimmingCharacters(in: CharacterSet(charactersIn: "<|>"))
            guard !code.isEmpty else { continue }
            result[code] = logits[[0, 0, NSNumber(value: token)]].floatValue
        }
        return result
    }
}
