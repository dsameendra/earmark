import AppCore
import Foundation
import Testing

@testable import Transcription

private func tone(_ seconds: Double) -> [Float] { (0..<Int(seconds * 16000)).map { 0.3 * sin(Float($0) * 0.1) } }
private func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * 16000)) }

private func liveAudio(_ samples: [Float], gate: AsyncStream<Void>? = nil) -> AsyncStream<AudioChunk> {
    AsyncStream { continuation in
        var index = 0
        var time = 0.0
        while index < samples.count {
            let end = min(samples.count, index + 1600)
            continuation.yield(AudioChunk(samples: Array(samples[index..<end]), startSeconds: time, source: .mixed))
            time += Double(end - index) / 16000
            index = end
        }
        continuation.finish()
    }
}

private func plan() -> (EngineResolver, whisper: ChunkEngine, qwen: ChunkEngine) {
    let whisper = ChunkEngine(id: "whisperkit")
    let qwen = ChunkEngine(id: "qwen3-asr")
    let plan = EnginePlan(
        assignments: [
            EngineAssignment(language: "en", engine: "whisperkit", model: "whisperkit/small"),
            EngineAssignment(language: "de", engine: "whisperkit", model: "whisperkit/small"),
            EngineAssignment(language: "si", engine: "qwen3-asr", model: "mlx/qwen3-asr-0.6b-sinhala-8bit", isExperimental: true),
        ])
    return (EngineBinding.resolver(plan: plan, engines: ["whisperkit": whisper, "qwen3-asr": qwen]), whisper, qwen)
}

@Suite("LanguageDecision (LANG-AC-05/06)")
struct LanguageDecisionTests {
    @Test("a one-language set needs no identification")
    func single() {
        let outcome = LanguageDecision.choose(scores: nil, duration: 0.2, set: ["si"], previous: nil)
        #expect(outcome == .init(language: "si", confidence: 1, isUncertain: false))
    }

    @Test("a confident winner is taken")
    func confident() {
        let outcome = LanguageDecision.choose(
            scores: [.init(language: "si", probability: 0.9), .init(language: "en", probability: 0.1)], duration: 3, set: ["en", "si"], previous: "en")
        #expect(outcome == .init(language: "si", confidence: 0.9, isUncertain: false))
    }

    @Test("below the threshold the previous language is kept and flagged uncertain (LANG-AC-06)")
    func lowConfidence() {
        let outcome = LanguageDecision.choose(
            scores: [.init(language: "si", probability: 0.4), .init(language: "en", probability: 0.35)], duration: 3, set: ["en", "si"], previous: "en")
        #expect(outcome == .init(language: "en", confidence: 0.4, isUncertain: true))
    }

    @Test("the first range takes the winner even when unsure")
    func firstRange() {
        let outcome = LanguageDecision.choose(
            scores: [.init(language: "si", probability: 0.4)], duration: 3, set: ["en", "si"], previous: nil)
        #expect(outcome?.language == "si")
        #expect(outcome?.isUncertain == true)
    }

    @Test("very short ranges and missing scores inherit the previous language")
    func shortOrEmpty() {
        let short = LanguageDecision.choose(
            scores: [.init(language: "si", probability: 0.99)], duration: 0.4, set: ["en", "si"], previous: "en")
        #expect(short == .init(language: "en", confidence: nil, isUncertain: true))
        let empty = LanguageDecision.choose(scores: [], duration: 3, set: ["en", "si"], previous: nil)
        #expect(empty?.language == "en")  // first of the sorted set
    }

    @Test("a previous language outside the (changed) set is ignored")
    func stalePrevious() {
        let outcome = LanguageDecision.choose(scores: [], duration: 3, set: ["de", "si"], previous: "en")
        #expect(outcome?.language == "de")
    }
}

@Suite("MultilingualEngine live routing (LANG-AC-05, LANG-AC-09, LANG-AC-15)")
struct MultilingualEngineTests {
    private let options = TranscriptionOptions(languageMode: .multilingual(["en", "si"]), useCase: .live)

    private func collect(_ stream: AsyncThrowingStream<TranscriptionEvent, any Error>) async throws -> [Segment] {
        var out: [Segment] = []
        for try await event in stream { if case .final(let segment) = event { out.append(segment) } }
        return out
    }

    /// Two utterances: English at ~0 s, Sinhala at ~5 s. The identifier answers by start time.
    @Test("each utterance goes to the engine of its identified language, in order, with tags")
    func routes() async throws {
        let (resolver, whisper, qwen) = plan()
        let identifier = ScriptedIdentifier { chunk in
            chunk.startSeconds < 4
                ? [.init(language: "en", probability: 0.95), .init(language: "si", probability: 0.05)]
                : [.init(language: "si", probability: 0.9), .init(language: "en", probability: 0.1)]
        }
        let engine = MultilingualEngine(languages: ["en", "si"], resolver: resolver, identifier: identifier)
        let audio = liveAudio(silence(0.3) + tone(2) + silence(2.5) + tone(2) + silence(2))
        let segments = try await collect(engine.stream(audio: audio, options: options))
        #expect(segments.count == 2)
        #expect(segments.map(\.languageCode) == ["en", "si"])
        #expect(segments.map { $0.text.split(separator: ":").first.map(String.init) } == ["whisperkit", "qwen3-asr"])
        #expect(segments[0].start < segments[1].start)
        #expect(segments.allSatisfy { ($0.languageConfidence ?? 0) > 0.8 })
        #expect(whisper.calls.first?.model == "whisperkit/small")
        #expect(qwen.calls.first?.model == "mlx/qwen3-asr-0.6b-sinhala-8bit")
        // LID was restricted to the chosen set.
        #expect(identifier.candidateSets.allSatisfy { $0 == ["en", "si"] })
    }

    @Test("Sinhala is never routed to a Whisper engine, even when LID is unsure")
    func sinhalaNeverWhisper() async throws {
        let (resolver, whisper, qwen) = plan()
        let identifier = ScriptedIdentifier { _ in [.init(language: "si", probability: 0.3), .init(language: "en", probability: 0.25)] }
        let engine = MultilingualEngine(languages: ["si"], resolver: resolver, identifier: identifier)
        let segments = try await collect(
            engine.stream(
                audio: liveAudio(tone(2) + silence(2)), options: TranscriptionOptions(languageMode: .multilingual(["si"]), useCase: .live)))
        #expect(segments.count == 1)
        #expect(whisper.calls.isEmpty)
        #expect(qwen.calls.count == 1)
        #expect(identifier.candidateSets.isEmpty)  // single-language set skips LID entirely
    }

    @Test("an unsure utterance keeps the previous language")
    func uncertainFallback() async throws {
        let (resolver, whisper, qwen) = plan()
        let identifier = ScriptedIdentifier { chunk in
            chunk.startSeconds < 4
                ? [.init(language: "en", probability: 0.95)]
                : [.init(language: "si", probability: 0.4), .init(language: "en", probability: 0.35)]
        }
        let engine = MultilingualEngine(languages: ["en", "si"], resolver: resolver, identifier: identifier)
        let audio = liveAudio(silence(0.3) + tone(2) + silence(2.5) + tone(2) + silence(2))
        let segments = try await collect(engine.stream(audio: audio, options: options))
        #expect(segments.map(\.languageCode) == ["en", "en"])
        #expect(whisper.calls.count == 2)
        #expect(qwen.calls.isEmpty)
        #expect((segments[1].languageConfidence ?? 1) < 0.5)
    }

    /// LANG-AC-15: the set changes between utterances without restarting the stream.
    @Test("changing the language set applies to subsequent audio without restarting capture")
    func setChange() async throws {
        let (resolver, whisper, qwen) = plan()
        let engine = MultilingualEngine(languages: ["en", "de"], resolver: resolver, identifier: nil)
        let (audio, feed) = AsyncStream<AudioChunk>.makeStream()
        let stream = engine.stream(audio: audio, options: TranscriptionOptions(languageMode: .autoDetect, useCase: .live))
        let reader = Task { try await collect(stream) }
        func send(_ samples: [Float], from start: Double) {
            var index = 0
            var time = start
            while index < samples.count {
                let end = min(samples.count, index + 1600)
                feed.yield(AudioChunk(samples: Array(samples[index..<end]), startSeconds: time, source: .mixed))
                time += Double(end - index) / 16000
                index = end
            }
        }
        send(tone(2) + silence(2), from: 0)
        try await Task.sleep(for: .milliseconds(500))
        await engine.setLanguages(["si"])
        send(tone(2) + silence(2), from: 4)
        feed.finish()
        let segments = try await reader.value
        #expect(segments.count == 2)
        #expect(segments.map(\.languageCode) == ["de", "si"])  // identifier-less set {en, de} falls back to its first sorted language
        #expect(whisper.calls.count == 1)
        #expect(qwen.calls.count == 1)
    }

    @Test("cancelling the consumer stops the stream")
    func cancel() async throws {
        let (resolver, _, _) = plan()
        let engine = MultilingualEngine(languages: ["en", "si"], resolver: resolver, identifier: nil)
        let (audio, _) = AsyncStream<AudioChunk>.makeStream()
        let task = Task { try await collect(engine.stream(audio: audio, options: options)) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let clock = ContinuousClock()
        let start = clock.now
        _ = try? await task.value
        #expect(clock.now - start < .seconds(1))
    }
}

@Suite("Auto-detect can pick Sinhala when configured (LANG-AC-04, LANG-AC-09)")
struct AutoDetectSinhalaTests {
    @Test("autoDetectCandidates widens the LID candidate set beyond the first engine's languages")
    func widened() async throws {
        let (resolver, whisper, qwen) = plan()
        var config = FileTranscriptionPipeline.Configuration()
        config.autoDetectCandidates = ["en", "si"]
        let identifier = ScriptedIdentifier { _ in [.init(language: "si", probability: 0.8)] }
        let pipeline = FileTranscriptionPipeline(
            decoder: FakeDecoder(totalSeconds: 20), vad: ScriptedVAD { _ in [TimeRange(start: 1, end: 15)] }, identifier: identifier,
            configuration: config)
        var segments: [Segment] = []
        for try await event in pipeline.run(
            file: URL(fileURLWithPath: "/dev/null"), options: TranscriptionOptions(languageMode: .autoDetect, useCase: .file),
            resumeFrom: nil, engines: resolver)
        {
            if case .chunkCompleted(let produced, _) = event { segments += produced }
        }
        #expect(identifier.candidateSets.first == ["en", "si"])
        #expect(segments.first?.text.hasPrefix("qwen3-asr") == true)
        #expect(whisper.calls.isEmpty)
        #expect(qwen.calls.count >= 1)
    }
}

@Suite("Segment re-transcription (LANG-AC-08, EDIT-AC-09)")
struct SegmentRetranscriptionTests {
    private func retranscriber(_ resolver: @escaping EngineResolver, seconds: TimeInterval = 600) -> SegmentRetranscriber {
        SegmentRetranscriber(
            decoder: FakeDecoder(totalSeconds: seconds), engines: resolver,
            vad: ScriptedVAD { chunk in [TimeRange(start: 0, end: chunk.duration)] })
    }

    @Test("only the segment's range is decoded and the engine of the new language is used")
    func rangeOnly() async throws {
        let (resolver, whisper, qwen) = plan()
        let produced = try await retranscriber(resolver).retranscribe(
            file: URL(fileURLWithPath: "/dev/null"), range: TimeRange(start: 100, end: 108), language: "si",
            options: TranscriptionOptions(useCase: .file))
        #expect(whisper.calls.isEmpty)
        #expect(qwen.calls.count == 1)
        #expect(qwen.calls.first?.mode == .single("si"))
        #expect(qwen.calls.first?.model == "mlx/qwen3-asr-0.6b-sinhala-8bit")
        let call = try #require(qwen.calls.first)
        #expect(abs(call.start - 100) < 0.01 && abs(call.duration - 8) < 0.01)
        #expect(produced.count == 1)
        #expect(produced[0].start >= 100 && produced[0].end <= 108)
        #expect(produced[0].languageCode == "si" && produced[0].languageConfidence == 1)
    }

    @Test("long ranges are split into bounded chunks and never exceed the range")
    func longRange() async throws {
        let (resolver, _, qwen) = plan()
        let produced = try await retranscriber(resolver).retranscribe(
            file: URL(fileURLWithPath: "/dev/null"), range: TimeRange(start: 10, end: 80), language: "si",
            options: TranscriptionOptions(useCase: .file))
        #expect(qwen.calls.count >= 2)
        #expect(qwen.calls.allSatisfy { $0.duration <= 46 })
        #expect(produced.allSatisfy { $0.start >= 10 && $0.end <= 80.001 })
        #expect(produced.map(\.start) == produced.map(\.start).sorted())
    }

    @Test("the editor helper replaces text, words and language but keeps identity, range and speaker")
    func replacement() async throws {
        let (resolver, _, _) = plan()
        let speaker = SpeakerID()
        let original = Segment(
            start: 20, end: 26, text: "old text", speakerID: speaker, languageCode: "en", languageConfidence: 0.4,
            words: [Word(text: "old", start: 20, end: 21)], translations: [SegmentTranslation(language: "de", text: "alt", engine: "x")])
        let updated = try await retranscriber(resolver).retranscribe(
            segment: original, file: URL(fileURLWithPath: "/dev/null"), language: "si")
        #expect(updated.id == original.id && updated.speakerID == speaker)
        #expect(updated.start == 20 && updated.end == 26)
        #expect(updated.text.hasPrefix("qwen3-asr:si"))
        #expect(updated.languageCode == "si" && updated.languageConfidence == 1)
        #expect(updated.translations.isEmpty)
    }

    @Test("an unsupported language or missing engine surfaces as AppError")
    func errors() async {
        let resolver: EngineResolver = { language in throw AppError.unsupportedLanguage(language ?? "??") }
        do {
            _ = try await retranscriber(resolver).retranscribe(
                file: URL(fileURLWithPath: "/dev/null"), range: TimeRange(start: 0, end: 5), language: "xx",
                options: TranscriptionOptions(useCase: .file))
            Issue.record("expected throw")
        } catch { #expect(error as? AppError == .unsupportedLanguage("xx")) }
    }

    @Test("an empty range yields nothing and calls no engine")
    func emptyRange() async throws {
        let (resolver, whisper, qwen) = plan()
        let produced = try await retranscriber(resolver).retranscribe(
            file: URL(fileURLWithPath: "/dev/null"), range: TimeRange(start: 5, end: 5), language: "en",
            options: TranscriptionOptions(useCase: .file))
        #expect(produced.isEmpty && whisper.calls.isEmpty && qwen.calls.isEmpty)
    }
}
