import Foundation
import MLX
import MLXAudioSTT

/// A piece of recognizer output.
enum RecognitionPiece: Sendable, Equatable {
    /// Decoded text increment (already parsed of the model's `language ...<asr_text>` prefix).
    case text(String)
    /// The complete transcript, delivered once at the end.
    case final(String)
}

/// What the engine needs from a speech model: one bounded utterance in, a stream of text out. The real implementation is
/// ``MLXQwenRecognizer``; tests use scripted fakes so the engine logic runs without Metal.
protocol SinhalaRecognizing: Sendable {
    /// Recognises `samples` (16 kHz mono) with at most `maxTokens` generated tokens. Cancelling the consumer stops
    /// generation at the next token.
    func recognize(samples: [Float], maxTokens: Int) -> AsyncThrowingStream<RecognitionPiece, any Error>
}

/// Carries the non-`Sendable` MLX model into a detached task; the engine guarantees one recognition at a time.
private struct ModelBox: @unchecked Sendable { let model: Qwen3ASRModel }

/// Owns the non-`Sendable` MLX model. Calls are serialised by the engine (one recognition at a time).
final class MLXQwenRecognizer: SinhalaRecognizing, @unchecked Sendable {
    private let model: Qwen3ASRModel

    private init(model: Qwen3ASRModel) { self.model = model }

    /// Loads weights from an installed model folder (never downloads).
    static func load(folder: URL) async throws -> MLXQwenRecognizer {
        MLXQwenRecognizer(model: try await Qwen3ASRModel.fromModelDirectory(folder))
    }

    func recognize(samples: [Float], maxTokens: Int) -> AsyncThrowingStream<RecognitionPiece, any Error> {
        let box = ModelBox(model: model)
        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                let model = box.model
                do {
                    // Language is left unset: the research measurements (and the model author's) were made that way.
                    let events = model.generateStream(
                        audio: MLXArray(samples), maxTokens: maxTokens, temperature: 0, context: "", language: nil)
                    for try await event in events {
                        try Task.checkCancellation()
                        switch event {
                        case .token(let piece): continuation.yield(.text(piece))
                        case .result(let output): continuation.yield(.final(output.text))
                        case .info: break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
