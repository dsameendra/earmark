import AppCore
import Foundation
import os

@testable import Transcription

/// Decoder that fabricates constant-valued audio of a given length, in `chunkSeconds` blocks, honouring `startingAt`.
struct FakeDecoder: AudioFileDecoder {
    var totalSeconds: TimeInterval
    /// Throws this error after yielding `failAfter` blocks.
    var failure: (after: Int, error: AppError)?

    func decode(file: URL, chunkSeconds: TimeInterval, startingAt: TimeInterval) -> AsyncThrowingStream<AudioChunk, any Error> {
        let total = totalSeconds
        let failure = failure
        return AsyncThrowingStream { continuation in
            let task = Task {
                var time = startingAt
                var emitted = 0
                while time < total - 0.0001 {
                    if Task.isCancelled {
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                    if let failure, emitted == failure.after {
                        continuation.finish(throwing: failure.error)
                        return
                    }
                    let length = min(chunkSeconds, total - time)
                    let samples = [Float](repeating: 0.1, count: Int((length * AudioChunk.sampleRate).rounded()))
                    continuation.yield(AudioChunk(samples: samples, startSeconds: time, source: .file))
                    time += length
                    emitted += 1
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func duration(of file: URL) async throws -> TimeInterval { totalSeconds }
}

/// VAD whose answer is computed from the chunk by a closure.
struct ScriptedVAD: VoiceActivityDetector {
    var script: @Sendable (AudioChunk) -> [TimeRange]
    func speechRanges(in chunk: AudioChunk) async throws -> [TimeRange] { script(chunk) }
}

/// Language identifier answering from a closure; records the candidate sets it was asked with.
final class ScriptedIdentifier: LanguageIdentifier {
    private let script: @Sendable (AudioChunk) -> [LanguageScore]
    private let log = OSAllocatedUnfairLock(initialState: [Set<LanguageCode>]())
    init(_ script: @escaping @Sendable (AudioChunk) -> [LanguageScore]) { self.script = script }
    func identify(chunk: AudioChunk, candidates: Set<LanguageCode>) async throws -> [LanguageScore] {
        log.withLock { $0.append(candidates) }
        return script(chunk)
    }
    var candidateSets: [Set<LanguageCode>] { log.withLock { $0 } }
}

struct EngineCall: Sendable, Equatable {
    var start: TimeInterval
    var duration: TimeInterval
    var mode: LanguageMode
    var model: ModelID?
}

/// Engine that answers each `stream` call with one final segment covering the chunk, and records every call.
final class ChunkEngine: TranscriptionEngine {
    let id: EngineID
    private let callLog = OSAllocatedUnfairLock(initialState: [EngineCall]())
    private let delay: Duration?
    private let failure: (@Sendable (Int) -> (any Error)?)?
    private let languages: Set<LanguageCode>

    init(
        id: EngineID = "chunk.engine", languages: Set<LanguageCode> = ["en", "de", "si"], delay: Duration? = nil,
        failure: (@Sendable (Int) -> (any Error)?)? = nil
    ) {
        self.id = id
        self.languages = languages
        self.delay = delay
        self.failure = failure
    }

    var calls: [EngineCall] { callLog.withLock { $0 } }

    func supportedLanguages(model: ModelID?) async -> Set<LanguageCode> { languages }
    func prepare(model: ModelID) async throws {}
    func unload() async {}
    func transcribe(file: URL, options: TranscriptionOptions) -> AsyncThrowingStream<TranscriptionEvent, any Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func stream(audio: AsyncStream<AudioChunk>, options: TranscriptionOptions) -> AsyncThrowingStream<TranscriptionEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for await chunk in audio {
                        let index = callLog.withLock { log -> Int in
                            log.append(
                                EngineCall(
                                    start: chunk.startSeconds, duration: chunk.duration, mode: options.languageMode, model: options.modelID)
                            )
                            return log.count - 1
                        }
                        if let delay { try await Task.sleep(for: delay) }
                        try Task.checkCancellation()
                        if let error = failure?(index) { throw error }
                        let text: String
                        switch options.languageMode {
                        case .single(let language): text = "\(id.rawValue):\(language.rawValue)@\(Int(chunk.startSeconds))"
                        default: text = "\(id.rawValue)@\(Int(chunk.startSeconds))"
                        }
                        continuation.yield(
                            .final(Segment(start: chunk.startSeconds, end: chunk.startSeconds + chunk.duration, text: text)))
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

struct PlainError: Error, CustomStringConvertible {
    var description: String
}

/// Collects a pipeline's events.
struct Collected {
    var segments: [Segment] = []
    var checkpoints: [JobCheckpoint] = []
    var chunkSegmentCounts: [Int] = []
    var languages: [[LanguageScore]] = []
    var progress: [Double] = []
}

func collect(_ stream: AsyncThrowingStream<FileTranscriptionEvent, any Error>) async throws -> Collected {
    var result = Collected()
    for try await event in stream {
        switch event {
        case .chunkCompleted(let segments, let checkpoint):
            result.segments += segments
            result.checkpoints.append(checkpoint)
            result.chunkSegmentCounts.append(segments.count)
        case .languageDetected(let scores): result.languages.append(scores)
        case .progress(let fraction, _): result.progress.append(fraction)
        }
    }
    return result
}

let testFile = URL(fileURLWithPath: "/tmp/does-not-matter.wav")
