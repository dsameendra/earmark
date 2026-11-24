import AppCore
import AppCoreTesting
import Foundation
import Testing

@testable import LiveCaptions

@Suite("LiveSessionOrchestrator", .timeLimit(.minutes(1)))
struct LiveSessionOrchestratorTests {
    // MARK: partials to finals (LIVE-AC-07, LIVE-AC-19)

    @Test("Volatile line finalizes in place with the same id and post-processed text")
    func partialsBecomeFinals() async throws {
        let rig = makeRig(script: [
            .events([.partial(PartialSegment(text: "hello", start: 0))]),
            .events([.partial(PartialSegment(text: "hello teh wor", start: 0))]),
            .events([.final(segment("hello teh world", 0, 1.4))]),
            .events([.partial(PartialSegment(text: "next", start: 1.5))]),
        ])
        let lines = Recorder(rig.orchestrator.lines())
        let states = Recorder(rig.orchestrator.state())
        try await rig.orchestrator.start(LiveSessionConfig(source: .mic(deviceUID: nil)))
        for t in 0..<4 { rig.source.send(chunk(Double(t))) }

        #expect(await waitUntil { lines.last?.count == 2 && lines.last?.last?.isVolatile == true })
        let all = lines.all
        let firstVolatile = try #require(all.first { $0.first?.isVolatile == true }?.first)
        let finalLine = try #require(lines.last?.first)
        #expect(finalLine.id == firstVolatile.id)
        #expect(finalLine.isVolatile == false)
        #expect(finalLine.text == "hello the world")  // replacement rule applied to finals
        #expect(lines.last?.last?.text == "next")

        // Earlier line never reflows: its position and id are stable in every snapshot after it appeared.
        for snapshot in all where snapshot.count > 1 { #expect(snapshot[0].id == firstVolatile.id) }

        _ = await rig.orchestrator.stop()
        #expect(await waitUntil { states.last == .idle })
        #expect(states.all.contains(.starting) && states.all.contains(.running) && states.all.contains(.stopping))
    }

    @Test("Ignored finals are hidden from captions but persisted flagged, never deleted")
    func ignoredLinesHiddenNotDeleted() async throws {
        let rig = makeRig(script: [
            .events([.partial(PartialSegment(text: "[BLANK_AUDIO]", start: 0))]),
            .events([.final(segment("[BLANK_AUDIO]", 0, 1))]),
            .events([.final(segment("real words", 1, 2))]),
        ])
        let lines = Recorder(rig.orchestrator.lines())
        try await rig.orchestrator.start(LiveSessionConfig(source: .mic(deviceUID: nil), saveAsTranscript: true))
        for t in 0..<3 { rig.source.send(chunk(Double(t))) }
        #expect(await waitUntil { lines.last?.map(\.text) == ["real words"] })

        let id = try #require(await rig.orchestrator.stop())
        let stored = rig.repo.stored(id)
        #expect(stored.count == 2)
        #expect(stored.first?.isIgnored == true)
        #expect(stored.last?.isIgnored == false)
    }

    @Test("Engine, source and persisted source tag follow the config (default English, live use case)")
    func configIsHonoured() async throws {
        let rig = makeRig(script: [.events([.final(segment("hi", 0, 1))])])
        try await rig.orchestrator.start(LiveSessionConfig(source: .mic(deviceUID: nil), saveAsTranscript: true))
        rig.source.send(chunk(0))
        #expect(await waitUntil { rig.engine.receivedCount == 1 })
        let options = try #require(rig.engine.options.withLock { $0 })
        #expect(options.useCase == .live)
        #expect(options.languageMode == .single(.english))
        #expect(options.modelID == ModelID("test/model"))
        let id = try #require(await rig.orchestrator.stop())
        let transcript = try #require(await rig.repo.transcript(id))
        #expect(transcript.source == .liveCaptions)
        #expect(transcript.languages == [.english])
        #expect(rig.repo.stored(id).first?.languageCode == .english)
    }

    @Test("Not saving as transcript persists nothing and returns nil (LIVE-AC-14)")
    func noSaveNoPersistence() async throws {
        let rig = makeRig(script: [.events([.final(segment("hi", 0, 1))])])
        try await rig.orchestrator.start(LiveSessionConfig(source: .mic(deviceUID: nil), saveAsTranscript: false))
        rig.source.send(chunk(0))
        try await Task.sleep(for: .milliseconds(150))
        #expect(await rig.orchestrator.stop() == nil)
        #expect(rig.repo.allTranscripts.isEmpty)
    }

    @Test("Save as transcript returns the TranscriptID with source liveCaptions (LIVE-AC-14)")
    func saveReturnsID() async throws {
        let rig = makeRig(script: [.events([.final(segment("saved text", 0, 1))])])
        try await rig.orchestrator.start(LiveSessionConfig(source: .system, saveAsTranscript: true))
        rig.source.send(chunk(0))
        let id = try #require(await rig.orchestrator.stop())
        #expect(rig.repo.stored(id).map(\.text) == ["saved text"])
        #expect(try await rig.repo.transcript(id)?.source == .liveCaptions)
    }

    @Test("Router warnings (Whisper fallback) are surfaced as engine notices once the session runs")
    func engineWarningsBecomeNotices() async throws {
        let notice = "Apple Speech is unavailable. Using Whisper instead."
        let rig = makeRig(script: [], warnings: [notice])
        let events = Recorder(rig.orchestrator.events())
        try await rig.orchestrator.start(LiveSessionConfig(source: .mic(deviceUID: nil)))
        #expect(await waitUntil { events.all == [.engineNotice(notice)] })
        _ = await rig.orchestrator.stop()
    }

    // MARK: pause / resume

    @Test("Paused audio is discarded; resume continues transcription")
    func pauseResume() async throws {
        let rig = makeRig(script: [])
        let events = Recorder(rig.orchestrator.events())
        try await rig.orchestrator.start(LiveSessionConfig(source: .mic(deviceUID: nil)))
        rig.source.send(chunk(0))
        rig.source.send(chunk(0.1))
        #expect(await waitUntil { rig.engine.receivedCount == 2 })

        await rig.orchestrator.pause()
        #expect(rig.orchestrator.isPaused)
        rig.source.send(chunk(0.2))
        rig.source.send(chunk(0.3))
        try await Task.sleep(for: .milliseconds(150))
        #expect(rig.engine.receivedCount == 2)

        await rig.orchestrator.resume()
        #expect(rig.orchestrator.isPaused == false)
        rig.source.send(chunk(0.4))
        #expect(await waitUntil { rig.engine.receivedCount == 3 })
        #expect(await waitUntil { events.all == [.paused, .resumed] })
        _ = await rig.orchestrator.stop()
    }

    // MARK: cancellation

    @Test("stop() drains, promotes the on-screen volatile text to a final, stops capture and returns to idle")
    func stopPromotesVolatile() async throws {
        let rig = makeRig(script: [.events([.partial(PartialSegment(text: "unfinished thought", start: 2))])])
        let lines = Recorder(rig.orchestrator.lines())
        try await rig.orchestrator.start(LiveSessionConfig(source: .mic(deviceUID: nil), saveAsTranscript: true))
        rig.source.send(chunk(2))
        #expect(await waitUntil { lines.last?.first?.isVolatile == true })
        let id = try #require(await rig.orchestrator.stop())
        #expect(rig.source.stopCount >= 1)
        #expect(rig.repo.stored(id).map(\.text) == ["unfinished thought"])
        #expect(lines.last?.first?.isVolatile == false)
        // A new session can start afterwards.
        try await rig.orchestrator.start(LiveSessionConfig(source: .mic(deviceUID: nil)))
        _ = await rig.orchestrator.stop()
    }

    @Test("stop() while still starting cancels the start without a failed state")
    func cancelDuringStart() async throws {
        let source = ManualAudioSource()
        let orchestrator = LiveSessionOrchestrator(
            audio: StubAudio(lanes: [LiveAudioLane(source: source)], delay: .milliseconds(300)),
            engines: StubEngines([ScriptedEngine([])]), transcripts: InMemoryTranscriptRepository(),
            postProcessor: StubPostProcessor(), options: testOptions())
        let states = Recorder(orchestrator.state())
        let starting = Task { try await orchestrator.start(LiveSessionConfig(source: .mic(deviceUID: nil))) }
        #expect(await waitUntil { states.all.contains(.starting) })
        #expect(await orchestrator.stop() == nil)
        await #expect(throws: AppError.cancelled) { try await starting.value }
        #expect(await waitUntil { states.last == .idle })
        #expect(source.startCount == 0)
        #expect(states.all.contains { if case .failed = $0 { true } else { false } } == false)
    }

    @Test("Starting twice is rejected")
    func startTwiceRejected() async throws {
        let rig = makeRig(script: [])
        try await rig.orchestrator.start(LiveSessionConfig(source: .mic(deviceUID: nil)))
        await #expect(throws: AppError.self) { try await rig.orchestrator.start(LiveSessionConfig(source: .system)) }
        _ = await rig.orchestrator.stop()
    }

    @Test("Source that ends on its own completes the session and stop() returns the saved id")
    func naturalCompletionWithMocks() async throws {
        let engine = MockTranscriptionEngine(events: [
            .partial(PartialSegment(text: "hel", start: 0)), .final(segment("hello", 0, 1)),
        ])
        let source = MockAudioSource(chunks: [chunk(0)])
        let repo = InMemoryTranscriptRepository()
        let orchestrator = LiveSessionOrchestrator(
            audio: StubAudio(lanes: [LiveAudioLane(source: source)]),
            engines: MockEngines(engine: engine), transcripts: repo, postProcessor: StubPostProcessor(), options: testOptions())
        let states = Recorder(orchestrator.state())
        try await orchestrator.start(LiveSessionConfig(source: .mic(deviceUID: nil), saveAsTranscript: true))
        #expect(await waitUntil { states.all.contains(.stopping) && states.last == .idle })
        let id = try #require(await orchestrator.stop())
        #expect(repo.stored(id).map(\.text) == ["hello"])
        #expect(await orchestrator.stop() == nil)  // id is handed out once
    }

    // MARK: crash safety

    @Test("Finals are checkpointed to the repository while the session runs, before stop()")
    func incrementalCheckpoint() async throws {
        let rig = makeRig(script: [
            .events([.final(segment("first", 0, 1))]),
            .events([.final(segment("second", 1, 2))]),
        ])
        try await rig.orchestrator.start(LiveSessionConfig(source: .mic(deviceUID: nil), saveAsTranscript: true))
        // The header exists immediately so a crash leaves a recoverable transcript.
        #expect(rig.repo.allTranscripts.count == 1)
        let id = try #require(rig.repo.allTranscripts.first?.id)
        rig.source.send(chunk(0))
        #expect(await waitUntil { rig.repo.stored(id).map(\.text) == ["first"] })
        rig.source.send(chunk(1))
        #expect(await waitUntil { rig.repo.stored(id).map(\.text) == ["first", "second"] })
        #expect(await waitUntil { (try? await rig.repo.transcript(id))?.duration ?? 0 >= 1.1 })
        // Simulated crash: the session is abandoned without stop(); the data is already durable.
        #expect(try await rig.repo.transcript(id)?.source == .liveCaptions)
        _ = await rig.orchestrator.stop()
    }

    @Test("A failing checkpoint reports an event but never ends the session; data flushes once the repo recovers")
    func checkpointFailureIsNonFatal() async throws {
        let rig = makeRig(script: [.events([.final(segment("kept", 0, 1))])])
        let events = Recorder(rig.orchestrator.events())
        let states = Recorder(rig.orchestrator.state())
        rig.repo.failUpserts = true
        try await rig.orchestrator.start(LiveSessionConfig(source: .mic(deviceUID: nil), saveAsTranscript: true))
        rig.source.send(chunk(0))
        #expect(await waitUntil { events.all.contains { if case .checkpointFailed = $0 { true } else { false } } })
        #expect(states.last == .running)
        rig.repo.failUpserts = false
        let id = try #require(await rig.orchestrator.stop())
        #expect(rig.repo.stored(id).map(\.text) == ["kept"])
    }

    // MARK: failure (LIVE-AC-16)

    @Test("Engine failure ends in .failed(reason) with the partial transcript saved, and Retry works")
    func engineFailureAndRetry() async throws {
        let failing = ScriptedEngine([
            .events([.final(segment("before crash", 0, 1))]),
            .fail(.engineFailure("scripted", reason: "model exploded")),
        ])
        let working = ScriptedEngine([.events([.final(segment("after retry", 0, 1))])])
        let repo = InMemoryTranscriptRepository()
        let source = ManualAudioSource()
        let orchestrator = LiveSessionOrchestrator(
            audio: StubAudio(lanes: [LiveAudioLane(source: source)]), engines: StubEngines([failing, working]),
            transcripts: repo, postProcessor: StubPostProcessor(), options: testOptions())
        let states = Recorder(orchestrator.state())
        try await orchestrator.start(LiveSessionConfig(source: .mic(deviceUID: nil), saveAsTranscript: true))
        source.send(chunk(0))
        source.send(chunk(1))
        #expect(await waitUntil { states.last == .failed("scripted: model exploded") })
        #expect(source.stopCount >= 1)
        let id = try #require(await orchestrator.stop())
        #expect(repo.stored(id).map(\.text) == ["before crash"])

        // Retry: start again on a fresh source lane.
        let retrySource = ManualAudioSource()
        let retry = LiveSessionOrchestrator(
            audio: StubAudio(lanes: [LiveAudioLane(source: retrySource)]), engines: StubEngines([working]),
            transcripts: repo, postProcessor: StubPostProcessor(), options: testOptions())
        try await retry.start(LiveSessionConfig(source: .mic(deviceUID: nil)))
        retrySource.send(chunk(0))
        _ = await retry.stop()
    }

    @Test("The same orchestrator can start again after a failure")
    func retrySameInstance() async throws {
        let failing = ScriptedEngine([.fail(.engineFailure("scripted", reason: "boom"))])
        let working = ScriptedEngine([.events([.final(segment("ok", 0, 1))])])
        let source = ManualAudioSource()
        let orchestrator = LiveSessionOrchestrator(
            audio: StubAudio(lanes: [LiveAudioLane(source: source)]), engines: StubEngines([failing, working]),
            transcripts: InMemoryTranscriptRepository(), postProcessor: StubPostProcessor(), options: testOptions())
        let states = Recorder(orchestrator.state())
        try await orchestrator.start(LiveSessionConfig(source: .mic(deviceUID: nil)))
        source.send(chunk(0))
        #expect(await waitUntil { if case .failed = states.last { true } else { false } })
        try await orchestrator.start(LiveSessionConfig(source: .mic(deviceUID: nil)))
        #expect(await waitUntil { states.last == .running })
        _ = await orchestrator.stop()
    }

    @Test("A source that cannot start fails the session with a readable reason")
    func startFailure() async throws {
        let orchestrator = LiveSessionOrchestrator(
            audio: StubAudio(lanes: [], failure: .permissionDenied(.microphone)), engines: StubEngines([ScriptedEngine([])]),
            transcripts: InMemoryTranscriptRepository(), postProcessor: StubPostProcessor(), options: testOptions())
        let states = Recorder(orchestrator.state())
        await #expect(throws: AppError.permissionDenied(.microphone)) {
            try await orchestrator.start(LiveSessionConfig(source: .mic(deviceUID: nil)))
        }
        #expect(await waitUntil { states.last == .failed("Permission denied: microphone") })
    }

    // MARK: speakers (LIVE-AC-12)

    @Test("At most four live speakers are labelled; extras become 'More speakers'")
    func speakerLimit() async throws {
        let slots = [10, 11, 12, 13, 14]
        let turns = slots.enumerated().map { i, slot in
            LiveDiarizationEvent.turn(SpeakerTurn(range: TimeRange(start: Double(i) * 2, end: Double(i) * 2 + 1.5), slot: slot))
        }
        let script = slots.indices.map { i in
            Step.events([.final(segment("line \(i)", Double(i) * 2, Double(i) * 2 + 1.5))])
        }
        let rig = makeRig(script: script, diarizer: ScriptedDiarizer(turns + [.speakerLimitReached]))
        let lines = Recorder(rig.orchestrator.lines())
        let events = Recorder(rig.orchestrator.events())
        try await rig.orchestrator.start(LiveSessionConfig(source: .system, diarize: true, saveAsTranscript: true))
        for i in slots.indices { rig.source.send(chunk(Double(i) * 2)) }

        let expected = ["Speaker 1", "Speaker 2", "Speaker 3", "Speaker 4", "More speakers"]
        #expect(await waitUntil { lines.last?.map { $0.speakerLabel ?? "" } == expected })
        #expect(lines.last?.compactMap(\.speakerSlot) == [0, 1, 2, 3])
        #expect(await waitUntil { events.all.contains(.speakerLimitReached) })

        let id = try #require(await rig.orchestrator.stop())
        let transcript = try #require(await rig.repo.transcript(id))
        #expect(transcript.speakers.count == maxLiveSpeakers)
        let stored = rig.repo.stored(id)
        #expect(stored.prefix(4).allSatisfy { $0.speakerID != nil })
        #expect(stored.last?.speakerID == nil)
        #expect(await rig.orchestrator.liveSpeakerTurns().count == 5)
    }

    @Test("Speakers are labelled after the fact when diarization arrives late")
    func lateSpeakerLabel() async throws {
        // Diarizer emits its turn only after the final line is already on screen.
        let late = LateDiarizer(turn: SpeakerTurn(range: TimeRange(start: 0, end: 1), slot: 3), after: .milliseconds(150))
        let rig = makeRig(script: [.events([.final(segment("hello", 0, 1))])], diarizer: late)
        let lines = Recorder(rig.orchestrator.lines())
        try await rig.orchestrator.start(LiveSessionConfig(source: .system, diarize: true))
        rig.source.send(chunk(0))
        #expect(await waitUntil { lines.last?.first?.text == "hello" })
        #expect(lines.last?.first?.speakerLabel == nil)
        #expect(await waitUntil { lines.last?.first?.speakerLabel == "Speaker 1" })
        _ = await rig.orchestrator.stop()
    }

    @Test("Mic and System lanes keep separate volatile lines and carry You / Them labels")
    func labelledLanes() async throws {
        let mic = ManualAudioSource(tag: .mic(deviceUID: nil))
        let system = ManualAudioSource(tag: .system)
        let engines = StubEngines([ScriptedEngine([.events([.final(segment("from me", 0, 1))])]), ScriptedEngine([.events([.final(segment("from them", 0, 1))])])])
        let orchestrator = LiveSessionOrchestrator(
            audio: StubAudio(lanes: [
                LiveAudioLane(label: "You", source: mic, diarize: false), LiveAudioLane(label: "Them", source: system),
            ]), engines: SequentialEngines(first: engines), transcripts: InMemoryTranscriptRepository(),
            postProcessor: StubPostProcessor(), options: testOptions())
        let lines = Recorder(orchestrator.lines())
        try await orchestrator.start(LiveSessionConfig(source: .micAndSystem(deviceUID: nil, lanes: true)))
        mic.send(chunk(0))
        system.send(chunk(0, source: .system))
        #expect(await waitUntil { Set(lines.last?.compactMap(\.speakerLabel) ?? []) == ["You", "Them"] })
        _ = await orchestrator.stop()
    }

    // MARK: health (LIVE-AC-05, LIVE-AC-15)

    @Test("Silent capture and device fallback are relayed as events; the session continues")
    func healthEvents() async throws {
        let rig = makeRig(script: [])
        let events = Recorder(rig.orchestrator.events())
        let states = Recorder(rig.orchestrator.state())
        try await rig.orchestrator.start(LiveSessionConfig(source: .system))
        rig.source.report(.deviceChanged(to: "BuiltInMic"))
        rig.source.report(.silent)
        #expect(await waitUntil { events.all.count == 2 })
        #expect(events.all[0] == .deviceFallback(to: "BuiltInMic"))
        if case .captureProblem(.captureSilent) = events.all[1] {} else { Issue.record("expected captureSilent") }
        #expect(states.last == .running)
        _ = await rig.orchestrator.stop()
    }

    // MARK: translation (LIVE-AC-13)

    @Test("late language detection translates finals already waiting in the bounded queue")
    func lateLanguageTranslation() async throws {
        let router = FakeTranslationRouter()
        var unknown = segment("bonjour", 0, 1)
        unknown.languageCode = nil
        let rig = makeRig(script: [.events([.final(unknown)]), .events([.languageDetected([LanguageScore(language: "fr", probability: 0.9)])])], translation: router)
        let lines = Recorder(rig.orchestrator.lines())
        let events = Recorder(rig.orchestrator.events())
        try await rig.orchestrator.start(LiveSessionConfig(source: .mic(deviceUID: nil), languageMode: .autoDetect, translateTo: .sinhala, saveAsTranscript: true))
        rig.source.send(chunk(0))
        #expect(await waitUntil { events.all.contains { if case .translationFailed = $0 { true } else { false } } })
        #expect(router.callTimes.isEmpty)
        rig.source.send(chunk(1))
        #expect(await waitUntil { lines.last?.first?.translation == "T(bonjour)" })
        let id = try #require(await rig.orchestrator.stop())
        #expect(rig.repo.stored(id).first?.translations.first?.text == "T(bonjour)")
    }

    @Test("revised finals keep their caption identity and discard an older in-flight translation")
    func revisedFinalTranslation() async throws {
        let router = GatedCaptionTranslator()
        let original = segment("original words", 0, 1)
        var revised = original
        revised.text = "corrected words"
        let rig = makeRig(script: [.events([.final(original)]), .events([.final(revised)])], translation: router)
        let lines = Recorder(rig.orchestrator.lines())
        try await rig.orchestrator.start(LiveSessionConfig(source: .mic(deviceUID: nil), translateTo: .sinhala, saveAsTranscript: true))
        rig.source.send(chunk(0))
        #expect(await waitUntil { router.pendingCount == 1 })
        let lineID = try #require(lines.last?.first?.id)
        rig.source.send(chunk(1))
        #expect(await waitUntil { lines.last?.first?.text == "corrected words" })
        router.completeFirst()
        #expect(await waitUntil { router.pendingCount == 1 })
        #expect(!lines.all.flatMap { $0 }.contains { $0.text == "corrected words" && $0.translation?.contains("original words") == true })
        router.completeFirst()
        #expect(await waitUntil { lines.last?.first?.translation?.contains("corrected words") == true })
        #expect(lines.last?.count == 1 && lines.last?.first?.id == lineID)
        let id = try #require(await rig.orchestrator.stop())
        #expect(rig.repo.stored(id).count == 1)
        #expect(rig.repo.stored(id).first?.translations.first?.text == "T(corrected words)")
    }

    @Test("unknown source language never silently routes as English")
    func unknownTranslationSource() async throws {
        let router = FakeTranslationRouter()
        var unknown = segment("bonjour", 0, 1)
        unknown.languageCode = nil
        let rig = makeRig(script: [.events([.final(unknown)])], translation: router)
        let lines = Recorder(rig.orchestrator.lines())
        let events = Recorder(rig.orchestrator.events())
        try await rig.orchestrator.start(LiveSessionConfig(
            source: .mic(deviceUID: nil), languageMode: .autoDetect, translateTo: .sinhala, saveAsTranscript: true))
        rig.source.send(chunk(0))
        #expect(await waitUntil { events.all.contains { if case .translationFailed = $0 { true } else { false } } })
        #expect(router.callTimes.isEmpty)
        #expect(lines.last?.first?.translation == nil)
        let id = try #require(await rig.orchestrator.stop())
        #expect(rig.repo.stored(id).first?.text == "bonjour")
    }

    @Test("slow translation has bounded backlog and keeps every original segment")
    func boundedTranslationBacklog() async throws {
        let router = FakeTranslationRouter()
        let options = LiveSessionOptions(
            checkpointInterval: .seconds(60), drainTimeout: .seconds(1),
            translationMinInterval: .milliseconds(30), maxPendingTranslations: 2)
        let rig = makeRig(
            script: [.events((0..<20).map { .final(segment("sentence \($0)", Double($0), Double($0) + 1)) })],
            translation: router, options: options)
        let lines = Recorder(rig.orchestrator.lines())
        let events = Recorder(rig.orchestrator.events())
        try await rig.orchestrator.start(LiveSessionConfig(
            source: .mic(deviceUID: nil), translateTo: .sinhala, saveAsTranscript: true))
        rig.source.send(chunk(0))
        #expect(await waitUntil { lines.last?.count == 20 })
        let id = try #require(await rig.orchestrator.stop())
        #expect(rig.repo.stored(id).count == 20)
        #expect(router.callTimes.count < 20)
        #expect(events.all.contains { if case .translationFailed(let reason) = $0 { reason.contains("falling behind") } else { false } })
        #expect(rig.repo.stored(id).last?.translations.first?.language == .sinhala)
    }

    @Test("stopping drains queued final translations before saving")
    func stopDrainsTranslationQueue() async throws {
        let router = FakeTranslationRouter()
        let rig = makeRig(
            script: [Step.events((0..<4).map { .final(segment("sentence \($0)", Double($0), Double($0) + 1)) })],
            translation: router, options: testOptions(translation: .milliseconds(80)))
        let lines = Recorder(rig.orchestrator.lines())
        try await rig.orchestrator.start(LiveSessionConfig(source: .mic(deviceUID: nil), translateTo: .sinhala, saveAsTranscript: true))
        rig.source.send(chunk(0))
        #expect(await waitUntil { lines.last?.count == 4 })
        let id = try #require(await rig.orchestrator.stop())
        let saved = rig.repo.stored(id)
        #expect(saved.count == 4)
        #expect(saved.allSatisfy { $0.translations.first?.language == .sinhala })
    }

    @Test("Translation is throttled and English to Sinhala carries the low-confidence marker")
    func translationThrottleAndMarker() async throws {
        let router = FakeTranslationRouter()
        let rig = makeRig(
            script: (0..<3).map { Step.events([.final(segment("sentence \($0)", Double($0), Double($0) + 1))]) },
            translation: router, options: testOptions(translation: .milliseconds(150)))
        let lines = Recorder(rig.orchestrator.lines())
        try await rig.orchestrator.start(LiveSessionConfig(source: .mic(deviceUID: nil), translateTo: .sinhala, saveAsTranscript: true))
        for t in 0..<3 { rig.source.send(chunk(Double(t))) }
        #expect(await waitUntil { lines.last?.allSatisfy { $0.translation != nil } == true && lines.last?.count == 3 })
        let marker = LiveCaptionMarkers.lowConfidenceTranslationPrefix
        #expect(lines.last?.allSatisfy { $0.translation?.hasPrefix(marker) == true } == true)

        let times = router.callTimes
        #expect(times.count == 3)
        for (a, b) in zip(times, times.dropFirst()) { #expect(a.duration(to: b) >= .milliseconds(140)) }

        let id = try #require(await rig.orchestrator.stop())
        #expect(rig.repo.stored(id).allSatisfy { $0.translations.first?.language == .sinhala })
    }
}

// MARK: - Extra stubs for this suite

final class GatedCaptionTranslator: TranslationRouter, TranslationEngine {
    let id: EngineID = "gated.translation"
    private struct Pending: Sendable {
        let items: [TranslationItem]
        let continuation: AsyncThrowingStream<TranslatedSegment, any Error>.Continuation
    }
    private let pending = Mutex<[Pending]>([])
    var pendingCount: Int { pending.withLock { $0.count } }
    func engine(for pair: LanguagePair) async throws -> any TranslationEngine { self }
    func supportedPairs() async -> Set<LanguagePair> { [] }
    func translate(items: [TranslationItem], from: LanguageCode, to: LanguageCode) -> AsyncThrowingStream<TranslatedSegment, any Error> {
        AsyncThrowingStream { continuation in pending.withLock { $0.append(Pending(items: items, continuation: continuation)) } }
    }
    func completeFirst() {
        let job = pending.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        guard let job else { return }
        for item in job.items { job.continuation.yield(TranslatedSegment(segmentID: item.segmentID, text: "T(\(item.text))", engine: id)) }
        job.continuation.finish()
    }
}

struct MockEngines: LiveEngineProviding {
    let engine: MockTranscriptionEngine
    func resolve(languageMode: LanguageMode) async throws -> LiveEngineSelection { LiveEngineSelection(engine: engine) }
}

/// Hands out a different engine per lane: the orchestrator resolves once, so lane engines are wrapped by one that
/// dispatches on audio source tag.
struct SequentialEngines: LiveEngineProviding {
    let first: StubEngines
    func resolve(languageMode: LanguageMode) async throws -> LiveEngineSelection {
        let a = try await first.resolve(languageMode: languageMode)
        let b = try await first.resolve(languageMode: languageMode)
        return LiveEngineSelection(engine: TagDispatchEngine(mic: a.engine, system: b.engine))
    }
}

struct TagDispatchEngine: TranscriptionEngine {
    let mic: any TranscriptionEngine
    let system: any TranscriptionEngine
    var id: EngineID { "dispatch" }
    func supportedLanguages(model: ModelID?) async -> Set<LanguageCode> { [.english] }
    func prepare(model: ModelID) async throws {}
    func unload() async {}
    func transcribe(file: URL, options: TranscriptionOptions) -> AsyncThrowingStream<TranscriptionEvent, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func stream(audio: AsyncStream<AudioChunk>, options: TranscriptionOptions) -> AsyncThrowingStream<TranscriptionEvent, any Error> {
        // Peek at the first chunk's tag to choose the engine, then forward it and the rest.
        let (forwarded, continuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .bufferingNewest(64))
        let mic = mic
        let system = system
        return AsyncThrowingStream { c in
            let task = Task {
                var inner: AsyncThrowingStream<TranscriptionEvent, any Error>?
                for await chunk in audio {
                    if inner == nil {
                        let engine: any TranscriptionEngine = chunk.source == .system ? system : mic
                        inner = engine.stream(audio: forwarded, options: options)
                        let stream = inner!
                        Task {
                            do { for try await e in stream { c.yield(e) }; c.finish() } catch { c.finish(throwing: error) }
                        }
                    }
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
}

final class LateDiarizer: StreamingDiarizer {
    let id: EngineID = "late"
    let turn: SpeakerTurn
    let after: Duration
    init(turn: SpeakerTurn, after: Duration) {
        self.turn = turn
        self.after = after
    }
    func stream(audio: AsyncStream<AudioChunk>, options: DiarizationOptions) -> AsyncThrowingStream<LiveDiarizationEvent, any Error> {
        let turn = turn
        let after = after
        return AsyncThrowingStream { c in
            let task = Task {
                try? await Task.sleep(for: after)
                c.yield(.turn(turn))
                for await _ in audio {}
                c.finish()
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
}

final class FakeTranslationRouter: TranslationRouter {
    private let times = Mutex<[ContinuousClock.Instant]>([])
    var callTimes: [ContinuousClock.Instant] { times.withLock { $0 } }
    func engine(for pair: LanguagePair) async throws -> any TranslationEngine {
        times.withLock { $0.append(ContinuousClock.now) }
        return FakeTranslationEngine()
    }
}

struct FakeTranslationEngine: TranslationEngine {
    var id: EngineID { "fake.translation" }
    func supportedPairs() async -> Set<LanguagePair> { [] }
    func translate(items: [TranslationItem], from: LanguageCode, to: LanguageCode) -> AsyncThrowingStream<TranslatedSegment, any Error> {
        AsyncThrowingStream { c in
            for item in items { c.yield(TranslatedSegment(segmentID: item.segmentID, text: "T(\(item.text))", engine: id)) }
            c.finish()
        }
    }
}

import Synchronization
