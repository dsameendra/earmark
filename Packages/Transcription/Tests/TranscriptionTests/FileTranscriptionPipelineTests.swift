import AppCore
import Foundation
import Testing

@testable import Transcription

@Suite("FileTranscriptionPipeline")
struct FileTranscriptionPipelineTests {
    private func pipeline(
        seconds: TimeInterval, vad: (any VoiceActivityDetector)? = nil, identifier: (any LanguageIdentifier)? = nil,
        failure: (after: Int, error: AppError)? = nil
    ) -> FileTranscriptionPipeline {
        FileTranscriptionPipeline(
            decoder: FakeDecoder(totalSeconds: seconds, failure: failure), vad: vad, identifier: identifier)
    }

    private let options = TranscriptionOptions(languageMode: .single("en"), useCase: .file)

    /// FILE-AC-09: bounded chunks, a checkpoint after each, segments in order, progress reaching 1.
    @Test("chunks the file and checkpoints after every chunk")
    func chunkAndCheckpoint() async throws {
        let engine = ChunkEngine()
        let out = try await collect(pipeline(seconds: 100).run(file: testFile, options: options, engine: engine))
        #expect(out.checkpoints == (0..<4).map { JobCheckpoint(lastCompletedChunk: $0, mediaTime: [30, 60, 90, 100][$0]) })
        #expect(out.segments.map(\.start) == [0, 30, 60, 90])
        #expect(engine.calls.map(\.duration) == [30, 30, 30, 10])
        #expect(out.progress.last == 1)
        #expect(zip(out.progress, out.progress.dropFirst()).allSatisfy { $0 <= $1 })
    }

    /// FILE-AC-08: resuming continues at the checkpoint without re-emitting committed segments.
    @Test("resumes from a checkpoint without duplicating committed chunks")
    func resume() async throws {
        let engine = ChunkEngine()
        let checkpoint = JobCheckpoint(lastCompletedChunk: 1, mediaTime: 60)
        let out = try await collect(
            pipeline(seconds: 100).run(file: testFile, options: options, engine: engine, resumeFrom: checkpoint))
        #expect(
            out.checkpoints == [JobCheckpoint(lastCompletedChunk: 2, mediaTime: 90), JobCheckpoint(lastCompletedChunk: 3, mediaTime: 100)])
        #expect(out.segments.map(\.start) == [60, 90])
        #expect(engine.calls.map(\.start) == [60, 90])
    }

    @Test("interrupted run + resume yields the same segments as an uninterrupted run")
    func interruptedThenResumed() async throws {
        let full = try await collect(pipeline(seconds: 100).run(file: testFile, options: options, engine: ChunkEngine()))

        // First run dies on the third engine call; remember what was committed.
        let flaky = ChunkEngine(failure: { $0 == 2 ? PlainError(description: "boom") : nil })
        var committed: [Segment] = []
        var last: JobCheckpoint?
        do {
            for try await event in pipeline(seconds: 100).run(file: testFile, options: options, engine: flaky) {
                if case .chunkCompleted(let segments, let checkpoint) = event {
                    committed += segments
                    last = checkpoint
                }
            }
            Issue.record("expected failure")
        } catch {}
        #expect(last == JobCheckpoint(lastCompletedChunk: 1, mediaTime: 60))

        let resumed = try await collect(
            pipeline(seconds: 100).run(file: testFile, options: options, engine: ChunkEngine(), resumeFrom: last))
        #expect((committed + resumed.segments).map(\.text) == full.segments.map(\.text))
        #expect((committed + resumed.segments).map(\.start) == full.segments.map(\.start))
    }

    /// ENG-AC-17: cancelling stops further engine work promptly and no later checkpoint is emitted.
    @Test("cancellation stops decoding and engine calls")
    func cancellation() async throws {
        let engine = ChunkEngine(delay: .milliseconds(150))
        let stream = pipeline(seconds: 600).run(file: testFile, options: options, engine: engine)
        let seen = Task { () -> [JobCheckpoint] in
            var checkpoints: [JobCheckpoint] = []
            do {
                for try await event in stream {
                    if case .chunkCompleted(_, let checkpoint) = event {
                        checkpoints.append(checkpoint)
                        if checkpoints.count == 1 { withUnsafeCurrentTask { $0?.cancel() } }
                    }
                }
            } catch {}
            return checkpoints
        }
        let checkpoints = await seen.value
        try await Task.sleep(for: .milliseconds(400))
        #expect(checkpoints.count == 1)
        #expect(engine.calls.count <= 2)
    }

    /// ENG-AC-09: engine errors are mapped to AppError, AppErrors pass through untouched.
    @Test("engine failures map to AppError")
    func failureMapping() async {
        let plain = ChunkEngine(id: "boom.engine", failure: { _ in PlainError(description: "kaput") })
        do {
            _ = try await collect(pipeline(seconds: 40).run(file: testFile, options: options, engine: plain))
            Issue.record("expected throw")
        } catch let error as AppError {
            #expect(error == .engineFailure("boom.engine", reason: "kaput"))
        } catch { Issue.record("not an AppError: \(error)") }

        let oom = ChunkEngine(failure: { _ in AppError.outOfMemory })
        do {
            _ = try await collect(pipeline(seconds: 40).run(file: testFile, options: options, engine: oom))
            Issue.record("expected throw")
        } catch { #expect(error as? AppError == .outOfMemory) }
    }

    @Test("decoder errors pass through as AppError")
    func decoderFailure() async {
        let engine = ChunkEngine()
        do {
            _ = try await collect(
                pipeline(seconds: 100, failure: (after: 2, error: .unsupportedFormat("bad"))).run(
                    file: testFile, options: options, engine: engine))
            Issue.record("expected throw")
        } catch { #expect(error as? AppError == .unsupportedFormat("bad")) }
    }

    @Test("a throwing engine never crashes the pipeline", arguments: [AppError.cancelled, .deviceUnavailable, .other("x")])
    func anyAppError(error: AppError) async {
        let engine = ChunkEngine(failure: { _ in error })
        do {
            _ = try await collect(pipeline(seconds: 10).run(file: testFile, options: options, engine: engine))
            Issue.record("expected throw")
        } catch let thrown { #expect(thrown as? AppError == error) }
    }

    /// FILE-AC-09: cuts at the quietest gap in the second half of the buffer.
    @Test("cuts chunks at VAD silence")
    func vadCut() async throws {
        let vad = ScriptedVAD { chunk in
            [TimeRange(start: 0, end: 20), TimeRange(start: 22, end: chunk.duration)]
        }
        let engine = ChunkEngine()
        let out = try await collect(pipeline(seconds: 70, vad: vad).run(file: testFile, options: options, engine: engine))
        #expect(out.checkpoints.first == JobCheckpoint(lastCompletedChunk: 0, mediaTime: 21))
        #expect(engine.calls.first?.duration == 21)
        // Units are contiguous and cover the whole file.
        let starts = engine.calls.map(\.start)
        let ends = engine.calls.dropLast().map { $0.start + $0.duration }
        #expect(Array(starts.dropFirst()) == ends)
        #expect(out.checkpoints.last?.mediaTime == 70)
    }

    @Test("silent chunks skip the engine but still checkpoint")
    func silentChunksSkipped() async throws {
        let engine = ChunkEngine()
        let out = try await collect(
            pipeline(seconds: 65, vad: ScriptedVAD { _ in [] }).run(file: testFile, options: options, engine: engine))
        #expect(engine.calls.isEmpty)
        #expect(out.segments.isEmpty)
        #expect(out.checkpoints.map(\.mediaTime) == [30, 60, 65])
    }

    /// LANG-AC-04
    @Test("auto-detect identifies once and fixes the language for the whole file")
    func autoDetect() async throws {
        let identifier = ScriptedIdentifier { _ in [LanguageScore(language: "de", probability: 0.9)] }
        let engine = ChunkEngine()
        let out = try await collect(
            pipeline(seconds: 70, identifier: identifier).run(
                file: testFile, options: TranscriptionOptions(languageMode: .autoDetect, useCase: .file), engine: engine))
        #expect(identifier.candidateSets.count == 1)
        #expect(identifier.candidateSets.first == ["en", "de", "si"])
        #expect(out.languages.first?.first?.language == "de")
        #expect(engine.calls.allSatisfy { $0.mode == .single("de") })
    }

    /// LANG-AC-05, LANG-AC-06
    @Test("multilingual mode identifies per speech range and falls back on low confidence")
    func multilingual() async throws {
        let vad = ScriptedVAD { _ in [TimeRange(start: 1, end: 6), TimeRange(start: 10, end: 15), TimeRange(start: 20, end: 25)] }
        let identifier = ScriptedIdentifier { chunk in
            switch Int(chunk.startSeconds.rounded()) {
            case 1: [LanguageScore(language: "en", probability: 0.9)]
            case 10: [LanguageScore(language: "de", probability: 0.3)]  // below threshold -> previous (en)
            default: [LanguageScore(language: "de", probability: 0.8)]
            }
        }
        let engine = ChunkEngine()
        let out = try await collect(
            pipeline(seconds: 30, vad: vad, identifier: identifier).run(
                file: testFile, options: TranscriptionOptions(languageMode: .multilingual(["en", "de"]), useCase: .file), engine: engine))
        #expect(out.segments.map { $0.languageCode?.rawValue } == ["en", "en", "de"])
        #expect(out.segments.map(\.languageConfidence) == [0.9, 0.3, 0.8])
        #expect(identifier.candidateSets.allSatisfy { $0 == ["en", "de"] })
        #expect(engine.calls.map(\.mode) == [.single("en"), .single("en"), .single("de")])
        // Ranges are padded slightly and located on the media timeline.
        #expect(out.segments.allSatisfy { $0.start >= 0.8 && $0.end <= 25.2 })
    }

    @Test("short ranges inherit the previous language without running language ID")
    func shortRangesSkipLID() async throws {
        let vad = ScriptedVAD { _ in [TimeRange(start: 1, end: 6), TimeRange(start: 10, end: 10.4)] }
        let identifier = ScriptedIdentifier { _ in [LanguageScore(language: "de", probability: 0.95)] }
        let out = try await collect(
            pipeline(seconds: 20, vad: vad, identifier: identifier).run(
                file: testFile, options: TranscriptionOptions(languageMode: .multilingual(["en", "de"]), useCase: .file),
                engine: ChunkEngine()))
        #expect(identifier.candidateSets.count == 1)
        #expect(out.segments.map { $0.languageCode?.rawValue } == ["de", "de"])
    }

    /// ADR-004: per-language engine assignment from an EnginePlan.
    @Test("a plan resolver sends each language to its own engine and model")
    func perLanguageEngines() async throws {
        let whisper = ChunkEngine(id: "whisperkit")
        let qwen = ChunkEngine(id: "qwen3-asr")
        let plan = EnginePlan(
            assignments: [
                EngineAssignment(language: "en", engine: "whisperkit", model: "whisperkit/small"),
                EngineAssignment(language: "si", engine: "qwen3-asr", model: "mlx/qwen3-asr-0.6b-sinhala-8bit", isExperimental: true),
            ])
        let resolver = EngineBinding.resolver(plan: plan, engines: ["whisperkit": whisper, "qwen3-asr": qwen])
        let vad = ScriptedVAD { _ in [TimeRange(start: 1, end: 6), TimeRange(start: 10, end: 15)] }
        let identifier = ScriptedIdentifier { chunk in
            [LanguageScore(language: chunk.startSeconds < 5 ? "en" : "si", probability: 0.9)]
        }
        let out = try await collect(
            pipeline(seconds: 20, vad: vad, identifier: identifier).run(
                file: testFile, options: TranscriptionOptions(languageMode: .multilingual(["en", "si"]), useCase: .file),
                engines: resolver))
        #expect(out.segments.map { $0.text.split(separator: "@").first.map(String.init) } == ["whisperkit:en", "qwen3-asr:si"])
        #expect(whisper.calls.first?.model == "whisperkit/small")
        #expect(qwen.calls.first?.model == "mlx/qwen3-asr-0.6b-sinhala-8bit")
    }

    @Test("resolver errors for missing engines map to AppError")
    func missingEngine() async {
        let plan = EnginePlan(assignments: [EngineAssignment(language: nil, engine: "ghost", model: nil)])
        let resolver = EngineBinding.resolver(plan: plan, engines: [:])
        do {
            _ = try await collect(pipeline(seconds: 10).run(file: testFile, options: options, resumeFrom: nil, engines: resolver))
            Issue.record("expected throw")
        } catch { #expect(error as? AppError == .engineFailure("ghost", reason: "Engine is not available in this build.")) }
    }

    @Test("engine file transcription adapter maps pipeline events")
    func adapter() async throws {
        let engine = ChunkEngine()
        var finals = 0
        var lastProgress = 0.0
        for try await event in pipeline(seconds: 65).transcriptionEvents(file: testFile, options: options, engine: engine) {
            switch event {
            case .final: finals += 1
            case .progress(let fraction, _): lastProgress = fraction
            default: break
            }
        }
        #expect(finals == 3)
        #expect(lastProgress == 1)
    }
}

@Suite("Error mapping")
struct ErrorMappingTests {
    @Test("AppError passes through, cancellation maps, others become engineFailure")
    func mapping() {
        #expect(AppError.mapping(AppError.deviceUnavailable, engine: "e") == .deviceUnavailable)
        #expect(AppError.mapping(CancellationError(), engine: "e") == .cancelled)
        #expect(AppError.mapping(PlainError(description: "x"), engine: "e") == .engineFailure("e", reason: "x"))
        #expect(AppError.mapping(PlainError(description: "Out of memory while loading"), engine: "e") == .outOfMemory)
    }
}
