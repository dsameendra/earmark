import AppCore
import AudioCapture
import Foundation
import Testing

@testable import QwenASR

/// Locates local assets of the main checkout (a worktree sits under `<repo>/.claude/worktrees/x`).
enum LocalSinhalaAssets {
    static func search(_ relative: String, filePath: String = #filePath) -> URL? {
        var dir = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// The pinned Qwen3-ASR Sinhala snapshot in the HF cache (revision 047217cb).
    static func environmentURL(_ key: String) -> URL? {
        guard let path = ProcessInfo.processInfo.environment[key], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
    static let modelFolder: URL? = environmentURL("EARMARK_QWEN_SINHALA_MODEL") ?? search(
        ".model-cache/hf/hub/models--Nerdstorm--Qwen3-ASR-0.6B-Sinhala-8bit/snapshots/047217cb611ad5f51cb2284e4a3617a5eaa9b688")
    static let slr30: URL? = environmentURL("EARMARK_QWEN_SINHALA_MANIFEST") ?? search(".model-cache/sinhala-eval/slr30_wav/manifest.jsonl")
    /// Unlicensed SPEAK-ASR YouTube clips: internal evaluation only; only aggregate numbers may leave this test.
    static let speak: URL? = search(".model-cache/sinhala-eval/speak/manifest.jsonl")
    static let available = modelFolder != nil && slr30 != nil
}

struct EvalRow: Decodable {
    var id: String
    var path: String
    var text: String
    var dur: Double
    var mixed: Bool
}

/// Real-model checks (MLX needs Metal: run with `xcodebuild test -scheme QwenASR -destination platform=macOS`).
@Suite("Qwen3-ASR Sinhala real model (needs local snapshot)", .serialized)
struct QwenRealModelTests {
    private func rows(_ manifest: URL) throws -> [EvalRow] {
        try String(contentsOf: manifest, encoding: .utf8).split(separator: "\n").map {
            try JSONDecoder().decode(EvalRow.self, from: Data($0.utf8))
        }
    }

    private func engine() throws -> QwenSinhalaEngine {
        let folder = try #require(LocalSinhalaAssets.modelFolder)
        return QwenSinhalaEngine(locate: { _ in folder })
    }

    /// Transcribes every clip through the engine's `transcribe(file:)` path and returns hypotheses plus timing.
    private func evaluate(_ rows: [EvalRow], engine: QwenSinhalaEngine) async throws -> (cer: Double, wer: Double, rtf: Double, hyps: [String: String]) {
        let options = TranscriptionOptions(languageMode: .single("si"), useCase: .file)
        var charErrors = 0, charTotal = 0, wordErrors = 0, wordTotal = 0
        var audioSeconds = 0.0
        let clock = ContinuousClock()
        var elapsed: Duration = .zero
        var hyps: [String: String] = [:]
        for row in rows {
            let start = clock.now
            var parts: [String] = []
            for try await event in engine.transcribe(file: URL(fileURLWithPath: row.path), options: options) {
                if case .final(let segment) = event { parts.append(segment.text) }
            }
            elapsed += clock.now - start
            audioSeconds += row.dur
            let hyp = parts.joined(separator: " ")
            hyps[row.id] = hyp
            let c = SinhalaMetrics.characterCounts(reference: row.text, hypothesis: hyp)
            let w = SinhalaMetrics.wordCounts(reference: row.text, hypothesis: hyp)
            charErrors += c.errors; charTotal += c.total; wordErrors += w.errors; wordTotal += w.total
        }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return (100 * Double(charErrors) / Double(max(1, charTotal)), 100 * Double(wordErrors) / Double(max(1, wordTotal)), seconds / max(0.001, audioSeconds), hyps)
    }

    @Test("clean read Sinhala (SLR30, 40 clips): CER close to the Python reference of 6.2%", .enabled(if: LocalSinhalaAssets.available), .timeLimit(.minutes(10)))
    func readSpeech() async throws {
        let rows = try rows(#require(LocalSinhalaAssets.slr30))
        let engine = try engine()
        let result = try await evaluate(rows, engine: engine)
        print(String(format: "QWEN-SI SLR30 n=%d CER=%.2f%% WER=%.2f%% RTF=%.3f", rows.count, result.cer, result.wer, result.rtf))
        if let out = ProcessInfo.processInfo.environment["EARMARK_EVAL_OUT"] {
            let lines = result.hyps.sorted { $0.key < $1.key }.map { "\($0.key)\t\($0.value)" }.joined(separator: "\n")
            try? lines.write(toFile: out + "/qwen_swift_slr30.tsv", atomically: true, encoding: .utf8)
        }
        #expect(result.cer < 12, "Swift CER should be near the Python 6.2%; large gaps point at feature extraction")
        await engine.unload()
    }

    @Test("conversation and code-mixed Sinhala (internal SPEAK set, 60 clips; aggregates only)", .enabled(if: LocalSinhalaAssets.available && LocalSinhalaAssets.speak != nil), .timeLimit(.minutes(15)))
    func conversation() async throws {
        let rows = try rows(#require(LocalSinhalaAssets.speak))
        let engine = try engine()
        let all = try await evaluate(rows, engine: engine)
        let mixed = try await evaluate(rows.filter(\.mixed), engine: engine)
        let plain = try await evaluate(rows.filter { !$0.mixed }, engine: engine)
        print(String(format: "QWEN-SI SPEAK n=%d CER=%.2f%% (sinhala-only %.2f%%, code-mixed %.2f%%) WER=%.2f%% RTF=%.3f", rows.count, all.cer, plain.cer, mixed.cer, all.wer, all.rtf))
        #expect(all.cer < 40)
        await engine.unload()
    }

    @Test("stream path on real audio produces Sinhala finals within bounded lag", .enabled(if: LocalSinhalaAssets.available), .timeLimit(.minutes(5)))
    func live() async throws {
        let rows = try rows(#require(LocalSinhalaAssets.slr30)).prefix(4)
        var samples: [Float] = []
        for row in rows {
            for try await chunk in AVFileDecoder().decode(file: URL(fileURLWithPath: row.path), chunkSeconds: 60, startingAt: 0) {
                samples += chunk.samples + silence(1.0)
            }
        }
        let engine = try engine()
        try await engine.prepare(model: QwenSinhalaTargets.model)
        let stream = AsyncStream<AudioChunk> { continuation in
            var index = 0
            var t = 0.0
            while index < samples.count {
                let end = min(samples.count, index + 1600)
                continuation.yield(AudioChunk(samples: Array(samples[index..<end]), startSeconds: t, source: .mic(deviceUID: nil)))
                t += Double(end - index) / 16000
                index = end
            }
            continuation.finish()
        }
        var finals: [Segment] = []
        var partials = 0
        for try await event in engine.stream(audio: stream, options: TranscriptionOptions(languageMode: .single("si"), useCase: .live)) {
            switch event {
            case .final(let segment): finals.append(segment)
            case .partial: partials += 1
            default: break
            }
        }
        print("QWEN-SI live: \(finals.count) finals, \(partials) partials; first: \(finals.first?.text ?? "-")")
        #expect(finals.count >= 3)
        #expect(finals.allSatisfy { $0.languageCode == "si" && !$0.text.isEmpty })
        await engine.unload()
    }

    @Test("cancelling a real transcription stops within 1 s", .enabled(if: LocalSinhalaAssets.available), .timeLimit(.minutes(5)))
    func cancel() async throws {
        let rows = try rows(#require(LocalSinhalaAssets.slr30))
        let engine = try engine()
        try await engine.prepare(model: QwenSinhalaTargets.model)
        let path = URL(fileURLWithPath: rows[0].path)
        let task = Task {
            for _ in 0..<20 {
                for try await _ in engine.transcribe(file: path, options: TranscriptionOptions(languageMode: .single("si"), useCase: .file)) {}
            }
        }
        try await Task.sleep(for: .milliseconds(400))
        task.cancel()
        let clock = ContinuousClock()
        let start = clock.now
        _ = try? await task.value
        #expect(clock.now - start < .seconds(1))
        await engine.unload()
    }
}
