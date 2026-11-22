import Dispatch
import Foundation
import MLX
import MLXAudioSTT

/// What the engine needs from a speech model: one bounded utterance in, its complete transcript out.
///
/// `recognize` returns (or throws) only after the model has fully stopped working on the utterance, so the caller may start the
/// next recognition immediately without two generations ever overlapping on one model (QA B5). The real implementation is
/// ``MLXQwenRecognizer``; tests use scripted fakes so the engine logic runs without Metal.
protocol SinhalaRecognizing: Sendable {
    /// Recognises `samples` (16 kHz mono) with at most `maxTokens` generated tokens and returns the raw transcript (the model's
    /// `language ...<asr_text>` prefix already parsed off).
    func recognize(samples: [Float], maxTokens: Int) async throws -> String
}

/// Owns the non-`Sendable` MLX model. It is an actor on its own serial queue, so the model is only ever touched by one
/// synchronous, run-to-completion `generate` call at a time, off the cooperative pool, without any `@unchecked Sendable`.
///
/// mlx-audio-swift's `generateStream` runs its decode loop in a private detached task that cannot be joined, so the stream API
/// cannot give the "next utterance waits for real completion" guarantee; the synchronous `generate` can. The cost is that a
/// decode is not interrupted mid-utterance; it is bounded by `maxTokens` (`SinhalaOutputGuard.maxTokens(forSeconds:)`).
actor MLXQwenRecognizer: SinhalaRecognizing {
    private static let queue = DispatchSerialQueue(label: "lk.dumindu.earmark.qwen-asr")
    nonisolated var unownedExecutor: UnownedSerialExecutor { Self.queue.asUnownedSerialExecutor() }

    private let model: Qwen3ASRModel

    private init(model: sending Qwen3ASRModel) { self.model = model }

    /// Loads weights from an installed model folder (never downloads).
    static func load(folder: URL) async throws -> MLXQwenRecognizer {
        MLXQwenRecognizer(model: try await Qwen3ASRModel.fromModelDirectory(folder))
    }

    func recognize(samples: [Float], maxTokens: Int) async throws -> String {
        try Task.checkCancellation()
        // Language is left unset: the research measurements (and the model author's) were made that way.
        let output = model.generate(audio: MLXArray(samples), maxTokens: maxTokens, temperature: 0, context: "", language: nil)
        return output.text
    }
}
