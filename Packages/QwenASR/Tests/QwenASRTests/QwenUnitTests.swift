import AppCore
import AudioCapture
import Foundation
import Testing

@testable import QwenASR

@Suite("SinhalaOutputGuard")
struct SinhalaOutputGuardTests {
    @Test("token cap follows 64 + 30 per second")
    func cap() {
        #expect(SinhalaOutputGuard.maxTokens(forSeconds: 0) == 64)
        #expect(SinhalaOutputGuard.maxTokens(forSeconds: 4.4) == 64 + 132)
        #expect(SinhalaOutputGuard.maxTokens(forSeconds: 30) == 964)
    }

    @Test("a repeated phrase is cut to one occurrence and the tail is dropped")
    func loop() {
        let phrase = "ඔව් ඔව් කියලා "
        let text = "මම ගෙදර ගියා. " + String(repeating: phrase, count: 8) + "ඊට පස්සේ"
        let cleaned = SinhalaOutputGuard.truncateRepetition(text)
        #expect(cleaned.truncated)
        #expect(cleaned.text.hasPrefix("මම ගෙදර ගියා."))
        #expect(cleaned.text.count < text.count / 2)
    }

    @Test("single-character runs and normal text are handled")
    func runs() {
        #expect(SinhalaOutputGuard.truncateRepetition(String(repeating: "අ", count: 60)).truncated)
        let normal = "මෙන්න අපි වගේ පොඩි ළමයින්ට බලන්න හොඳ නැති එකක් දාලෝ."
        #expect(SinhalaOutputGuard.truncateRepetition(normal) == .init(text: normal, truncated: false))
        #expect(SinhalaOutputGuard.truncateRepetition("short").truncated == false)
    }

    @Test("wrong-script output is detected; Sinhala and Latin are fine")
    func scripts() {
        #expect(SinhalaOutputGuard.isWrongScript("यह एक परीक्षण है"))
        #expect(!SinhalaOutputGuard.isWrongScript("මට notebook එකක් ඕනේ"))
        #expect(!SinhalaOutputGuard.isWrongScript("123 456"))
    }

    @Test("normalisation is NFC and keeps ZWJ")
    func normalise() {
        let text = "  ශ්\u{200D}රී ලංකා \n"
        #expect(SinhalaOutputGuard.normalise(text) == "ශ්\u{200D}රී ලංකා")
    }
}

/// VAD stub: speech wherever the samples are non-zero.
struct AmplitudeVAD: VoiceActivityDetector {
    func speechRanges(in chunk: AudioChunk) async throws -> [TimeRange] {
        var ranges: [TimeRange] = []
        var start: Int?
        let frame = 160
        var index = 0
        while index + frame <= chunk.samples.count {
            let active = chunk.samples[index..<index + frame].contains { abs($0) > 0.01 }
            if active, start == nil { start = index }
            if !active, let s = start {
                ranges.append(TimeRange(start: Double(s) / 16000, end: Double(index) / 16000))
                start = nil
            }
            index += frame
        }
        if let s = start { ranges.append(TimeRange(start: Double(s) / 16000, end: Double(chunk.samples.count) / 16000)) }
        return ranges
    }
}

func tone(_ seconds: Double) -> [Float] { (0..<Int(seconds * 16000)).map { 0.3 * sin(Float($0) * 0.1) } }
func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * 16000)) }

@Suite("UtteranceSegmenter")
struct UtteranceSegmenterTests {
    @Test("releases a finished utterance after the minimum silence and keeps media times")
    func closes() async {
        var seg = UtteranceSegmenter(vad: AmplitudeVAD())
        seg.append(AudioChunk(samples: silence(1) + tone(2) + silence(0.8), startSeconds: 10, source: .file))
        let out = await seg.drain(final: false)
        #expect(out.count == 1)
        #expect(abs((out.first?.start ?? 0) - (11 - 0.15)) < 0.05)
        #expect(abs((out.first?.duration ?? 0) - (2 + 0.3)) < 0.1)
    }

    @Test("an utterance without trailing silence stays open until final")
    func open() async {
        var seg = UtteranceSegmenter(vad: AmplitudeVAD())
        seg.append(AudioChunk(samples: tone(2), startSeconds: 0, source: .file))
        #expect(await seg.drain(final: false).isEmpty)
        #expect(await seg.openUtterance() != nil)
        #expect(await seg.drain(final: true).count == 1)
    }

    @Test("two utterances separated by a pause are split; short gaps merge")
    func splits() async {
        var seg = UtteranceSegmenter(vad: AmplitudeVAD())
        seg.append(AudioChunk(samples: tone(1) + silence(0.2) + tone(1) + silence(1.0) + tone(1) + silence(0.7), startSeconds: 0, source: .file))
        let out = await seg.drain(final: false)
        #expect(out.count == 2)
    }

    @Test("overlong speech is split at the cap and buffer stays bounded")
    func cap() async {
        var seg = UtteranceSegmenter(vad: AmplitudeVAD())
        seg.maxUtterance = 5
        seg.append(AudioChunk(samples: tone(12) + silence(1), startSeconds: 0, source: .file))
        let out = await seg.drain(final: false)
        #expect(out.count == 3)
        #expect(out.allSatisfy { $0.duration <= 5.4 })
        #expect(seg.bufferedSeconds <= 1.1)
    }

    @Test("pure silence is dropped, not accumulated")
    func silent() async {
        var seg = UtteranceSegmenter(vad: AmplitudeVAD())
        for i in 0..<20 {
            seg.append(AudioChunk(samples: silence(1), startSeconds: Double(i), source: .file))
            #expect(await seg.drain(final: false).isEmpty)
        }
        #expect(seg.bufferedSeconds <= 1.1)
    }
}

/// Scripted recognizer: returns canned text per call, optionally slowly or forever.
final class ScriptedRecognizer: SinhalaRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String]
    private(set) var calls: [(count: Int, maxTokens: Int)] = []
    let endless: Bool
    /// When set, the text is chosen by utterance length instead of call order (partial decodes also consume calls).
    let byDuration: (@Sendable (Double) -> String)?
    init(_ texts: [String], endless: Bool = false, byDuration: (@Sendable (Double) -> String)? = nil) {
        self.texts = texts
        self.endless = endless
        self.byDuration = byDuration
    }
    func recognize(samples: [Float], maxTokens: Int) -> AsyncThrowingStream<RecognitionPiece, any Error> {
        lock.lock()
        calls.append((samples.count, maxTokens))
        let text = byDuration?(Double(samples.count) / 16000) ?? (texts.isEmpty ? "" : texts.removeFirst())
        lock.unlock()
        let endless = endless
        return AsyncThrowingStream { continuation in
            let task = Task {
                if endless {
                    while !Task.isCancelled {
                        continuation.yield(.text("අ"))
                        try? await Task.sleep(for: .milliseconds(5))
                    }
                    continuation.finish()
                    return
                }
                for piece in text.split(separator: " ", omittingEmptySubsequences: false) {
                    continuation.yield(.text(String(piece) + " "))
                }
                continuation.yield(.final(text))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@Suite("QwenSinhalaEngine (scripted recognizer)")
struct QwenSinhalaEngineTests {
    private func engine(_ recognizer: ScriptedRecognizer, located: Bool = true) -> QwenSinhalaEngine {
        let folder = FileManager.default.temporaryDirectory
        return QwenSinhalaEngine(
            locate: { model in
                if !located { throw AppError.modelNotInstalled(model) }
                return folder
            }, vad: AmplitudeVAD(), loader: { _ in recognizer })
    }

    private func audio(_ samples: [Float]) -> AsyncStream<AudioChunk> {
        AsyncStream { continuation in
            var t = 0.0
            var index = 0
            while index < samples.count {
                let end = min(samples.count, index + 1600)
                continuation.yield(AudioChunk(samples: Array(samples[index..<end]), startSeconds: t, source: .mic(deviceUID: nil)))
                t += Double(end - index) / 16000
                index = end
            }
            continuation.finish()
        }
    }

    @Test("supports only Sinhala (LANG-AC-09)")
    func languages() async {
        let languages = await engine(ScriptedRecognizer([])).supportedLanguages(model: nil)
        #expect(languages == ["si"])
    }

    @Test("stream emits a Sinhala-tagged final per utterance with the token cap for its length")
    func finals() async throws {
        let rec = ScriptedRecognizer([], byDuration: { $0 >= 2.0 ? "පළමු වාක්‍යය" : "දෙවන වාක්‍යය" })
        let samples = silence(0.5) + tone(2) + silence(1) + tone(1.5) + silence(1)
        var finals: [Segment] = []
        for try await event in engine(rec).stream(audio: audio(samples), options: TranscriptionOptions(languageMode: .single("si"), useCase: .live)) {
            if case .final(let segment) = event { finals.append(segment) }
        }
        #expect(finals.map(\.text) == ["පළමු වාක්‍යය", "දෙවන වාක්‍යය"])
        #expect(finals.allSatisfy { $0.languageCode == "si" })
        #expect(finals.count == 2 && finals[0].start < finals[1].start)
        #expect(rec.calls.first.map { $0.maxTokens > 64 } == true)
    }

    @Test("other single languages are rejected, multilingual and autoDetect are accepted")
    func languageModes() async throws {
        let rec = ScriptedRecognizer(["ok"])
        var thrown: AppError?
        do {
            for try await _ in engine(rec).stream(audio: audio(tone(1) + silence(1)), options: TranscriptionOptions(languageMode: .single("en"), useCase: .live)) {}
        } catch { thrown = error as? AppError }
        #expect(thrown == .unsupportedLanguage("en"))
        var count = 0
        for try await event in engine(ScriptedRecognizer(["ok"])).stream(
            audio: audio(tone(1) + silence(1)), options: TranscriptionOptions(languageMode: .multilingual(["en", "si"]), useCase: .live))
        {
            if case .final = event { count += 1 }
        }
        #expect(count == 1)
    }

    @Test("a missing model surfaces modelNotInstalled and never downloads")
    func notInstalled() async {
        var thrown: AppError?
        do {
            for try await _ in engine(ScriptedRecognizer([]), located: false).stream(
                audio: audio(tone(1)), options: TranscriptionOptions(languageMode: .single("si"), useCase: .live)) {}
        } catch { thrown = error as? AppError }
        #expect(thrown == .modelNotInstalled(QwenSinhalaTargets.model))
    }

    @Test("a runaway repetition stream is stopped early and flagged low-confidence")
    func runaway() async throws {
        let rec = ScriptedRecognizer([], endless: true)
        var finals: [Segment] = []
        let clock = ContinuousClock()
        let start = clock.now
        for try await event in engine(rec).stream(audio: audio(tone(1.5) + silence(1)), options: TranscriptionOptions(languageMode: .single("si"), useCase: .live)) {
            if case .final(let segment) = event { finals.append(segment) }
        }
        #expect(clock.now - start < .seconds(10))
        #expect(finals.count == 1)
        #expect((finals.first?.confidence ?? 1) < 0.5)
        #expect((finals.first?.text.count ?? 1000) < 40)
    }

    @Test("wrong-script output is dropped (treated as an engine error for that clip)")
    func wrongScript() async throws {
        let rec = ScriptedRecognizer(["यह एक परीक्षण है"])
        var count = 0
        for try await event in engine(rec).stream(audio: audio(tone(1.5) + silence(1)), options: TranscriptionOptions(languageMode: .single("si"), useCase: .live)) {
            if case .final = event { count += 1 }
        }
        #expect(count == 0)
    }

    @Test("cancelling the consumer stops the engine promptly")
    func cancel() async throws {
        let rec = ScriptedRecognizer([], endless: true)
        let eng = engine(rec)
        let task = Task {
            for try await _ in eng.stream(audio: audio(tone(1.5) + silence(1)), options: TranscriptionOptions(languageMode: .single("si"), useCase: .live)) {}
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let clock = ContinuousClock()
        let start = clock.now
        _ = try? await task.value
        #expect(clock.now - start < .seconds(1))
    }
}
