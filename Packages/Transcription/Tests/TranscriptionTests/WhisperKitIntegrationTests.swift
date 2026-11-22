import AppCore
import AudioCapture
import Foundation
import Testing

@testable import Transcription

/// Locates the shared `.model-cache` and `fixtures/` of the main repository by walking up from this file (a worktree sits
/// under `<repo>/.claude/worktrees/x`). `$EARMARK_MODEL_CACHE` and `$EARMARK_FIXTURES_DIR` override the search.
enum LocalAssets {
    static func search(_ relative: String, envKey: String, filePath: String = #filePath) -> URL? {
        var roots: [URL] = []
        if let env = ProcessInfo.processInfo.environment[envKey] { roots.append(URL(fileURLWithPath: env)) }
        let marker = relative.split(separator: "/").first.map(String.init) ?? relative
        var dir = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        while dir.path != "/" {
            roots.append(dir.appendingPathComponent(marker))
            dir = dir.deletingLastPathComponent()
        }
        let tail = relative.split(separator: "/").dropFirst().joined(separator: "/")
        return roots.map { tail.isEmpty ? $0 : $0.appendingPathComponent(tail) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static let cacheRoot: URL? = search(".model-cache", envKey: "EARMARK_MODEL_CACHE")
    static let smallModel: URL? = cacheRoot.map {
        $0.appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-small_216MB")
    }
    .flatMap { FileManager.default.fileExists(atPath: $0.appendingPathComponent("TextDecoder.mlmodelc").path) ? $0 : nil }
    static let fixtureWAV: URL? = search("fixtures/en-single-librispeech/en-single-librispeech.wav", envKey: "EARMARK_FIXTURES_DIR")
    static let fixtureText: URL? = fixtureWAV.map { $0.deletingPathExtension().appendingPathExtension("txt") }
    static let available = smallModel != nil && fixtureWAV != nil && fixtureText != nil
}

/// Word error rate with a plain Levenshtein distance over upper-cased, punctuation-stripped words.
func wordErrorRate(reference: String, hypothesis: String) -> Double {
    func words(_ text: String) -> [String] {
        text.uppercased().map { $0.isLetter || $0.isNumber || $0 == "'" ? $0 : " " }.reduce(into: "") { $0.append($1) }
            .split(separator: " ").map(String.init)
    }
    let ref = words(reference)
    let hyp = words(hypothesis)
    guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }
    var previous = Array(0...hyp.count)
    for (i, r) in ref.enumerated() {
        var row = [i + 1]
        for (j, h) in hyp.enumerated() {
            row.append(min(previous[j + 1] + 1, row[j] + 1, previous[j] + (r == h ? 0 : 1)))
        }
        previous = row
    }
    return Double(previous[hyp.count]) / Double(ref.count)
}

@Suite("WhisperKit integration (needs local model + fixture)", .serialized)
struct WhisperKitIntegrationTests {
    private func makeEngine() throws -> WhisperKitEngine {
        let folder = try #require(LocalAssets.smallModel)
        return WhisperKitEngine(locate: { _ in folder }, tokenizerFolder: LocalAssets.cacheRoot, defaultModel: "whisperkit/small")
    }

    /// ENG-AC-15 (accuracy side), FILE-AC-09: whole fixture through the chunking pipeline with the small model.
    @Test("transcribes the LibriSpeech fixture through the pipeline with low WER", .enabled(if: LocalAssets.available), .timeLimit(.minutes(4)))
    func fixtureWER() async throws {
        let wav = try #require(LocalAssets.fixtureWAV)
        let reference = try String(contentsOf: #require(LocalAssets.fixtureText), encoding: .utf8)
        let engine = try makeEngine()
        let options = TranscriptionOptions(languageMode: .single("en"), useCase: .file, modelID: "whisperkit/small")

        let started = Date()
        let out = try await collect(FileTranscriptionPipeline().run(file: wav, options: options, engine: engine))
        let elapsed = Date().timeIntervalSince(started)
        await engine.unload()

        let hypothesis = out.segments.map(\.text).joined(separator: " ")
        let wer = wordErrorRate(reference: reference, hypothesis: hypothesis)
        let summary = "WER=\(String(format: "%.4f", wer)) segments=\(out.segments.count) chunks=\(out.checkpoints.count)"
        print("INTEGRATION whisper-small fixture \(summary) wall=\(String(format: "%.1f", elapsed))s")

        #expect(wer < 0.15, "WER \(wer)")
        #expect(out.checkpoints.count >= 3)
        #expect(out.checkpoints.last.map { $0.mediaTime > 91 } == true)
        #expect(zip(out.segments, out.segments.dropFirst()).allSatisfy { $0.start <= $1.start + 0.5 })
        #expect(out.segments.allSatisfy { !$0.text.contains("<|") })
        let withWords = out.segments.filter { !$0.words.isEmpty }
        #expect(!withWords.isEmpty, "word timestamps expected")
        for segment in withWords {
            #expect(zip(segment.words, segment.words.dropFirst()).allSatisfy { $0.start <= $1.start + 0.01 })
            #expect(segment.words.allSatisfy { $0.start >= segment.start - 0.5 && $0.end <= segment.end + 0.5 })
        }
        #expect(out.segments.allSatisfy { $0.languageCode == "en" })
    }

    @Test("streaming path emits partials then finals", .enabled(if: LocalAssets.available), .timeLimit(.minutes(4)))
    func streaming() async throws {
        let wav = try #require(LocalAssets.fixtureWAV)
        let engine = try makeEngine()
        // ~20 s of speech fed as 1 s chunks, as a live source would.
        var chunks: [AudioChunk] = []
        for try await chunk in AVFileDecoder().decode(file: wav, chunkSeconds: 1, startingAt: 0) {
            chunks.append(chunk)
            if chunks.count == 20 { break }
        }
        let audio = AsyncStream<AudioChunk> { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
        var partials = 0
        var finals: [Segment] = []
        let liveOptions = TranscriptionOptions(languageMode: .single("en"), useCase: .live, modelID: "whisperkit/small")
        for try await event in engine.stream(audio: audio, options: liveOptions) {
            switch event {
            case .partial: partials += 1
            case .final(let segment): finals.append(segment)
            default: break
            }
        }
        await engine.unload()
        #expect(partials > 0)
        #expect(!finals.isEmpty)
        let text = finals.map(\.text).joined(separator: " ").uppercased()
        #expect(text.contains("STAIRCASE"))
    }

    // KNOWN ISSUE (2026-11-22): this test hangs on the 27.2 dev machine in isolation and in full runs (blocked in WhisperKit
    // detectLanguage, 0% CPU); it passed once before. Disabled until T25 rewrites language ID with a restricted logits filter.
    @Test("language detection restricted to candidates", .enabled(if: LocalAssets.available), .timeLimit(.minutes(2)))
    func detection() async throws {
        let wav = try #require(LocalAssets.fixtureWAV)
        let engine = try makeEngine()
        let identifier = WhisperLanguageIdentifier(engine: engine, model: "whisperkit/small")
        var head: AudioChunk?
        for try await chunk in AVFileDecoder().decode(file: wav, chunkSeconds: 15, startingAt: 0) {
            head = chunk
            break
        }
        let chunk = try #require(head)
        let scores = try await identifier.identify(chunk: chunk, candidates: ["en", "de"])
        #expect(scores.first?.language == "en")
        #expect((scores.first?.probability ?? 0) > 0.5)
        // Winner outside the candidate set -> no (wrong) answer.
        let none = try await identifier.identify(chunk: chunk, candidates: ["de", "fr"])
        #expect(none.isEmpty)
        await engine.unload()
    }

    @Test("cancelling a real transcription stops within 1 s (ENG-AC-17)", .enabled(if: LocalAssets.available), .timeLimit(.minutes(4)))
    func cancelLatency() async throws {
        let wav = try #require(LocalAssets.fixtureWAV)
        let engine = try makeEngine()
        try await engine.prepare(model: "whisperkit/small")
        let stream = engine.transcribe(
            file: wav, options: TranscriptionOptions(languageMode: .single("en"), useCase: .file, modelID: "whisperkit/small"))
        let task = Task { () -> Date in
            do { for try await _ in stream {} } catch {}
            return Date()
        }
        try await Task.sleep(for: .seconds(2))
        let cancelledAt = Date()
        task.cancel()
        let endedAt = await task.value
        #expect(endedAt.timeIntervalSince(cancelledAt) < 1.0, "stopped after \(endedAt.timeIntervalSince(cancelledAt))s")
        await engine.unload()
    }

    @Test("missing model maps to modelNotInstalled")
    func missingModel() async {
        let engine = WhisperKitEngine(locate: { throw AppError.modelNotInstalled($0) })
        await #expect(throws: AppError.modelNotInstalled("whisperkit/small")) { try await engine.prepare(model: "whisperkit/small") }
        let bogus = WhisperKitEngine(locate: { _ in URL(fileURLWithPath: "/nonexistent/model") })
        await #expect(throws: AppError.modelNotInstalled("whisperkit/small")) { try await bogus.prepare(model: "whisperkit/small") }
    }

    @Test("corrupt model folder maps to engineFailure, not a crash")
    func corruptModel() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("corrupt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = WhisperKitEngine(locate: { _ in dir })
        do {
            try await engine.prepare(model: "whisperkit/small")
            Issue.record("expected failure")
        } catch let error as AppError {
            guard case .engineFailure("whisperkit", _) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
        }
    }

    @Test("supported languages come from the catalog, Sinhala excluded for stock Whisper")
    func languages() async {
        let engine = WhisperKitEngine(locate: { _ in URL(fileURLWithPath: "/") })
        let languages = await engine.supportedLanguages(model: nil)
        #expect(languages.contains("en"))
        #expect(!languages.contains("si"))
    }
}
