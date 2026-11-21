import AppCore
import Export
import Foundation
import Models
import Persistence
import Testing
import Transcription

@testable import Jobs

@Suite("State machine")
struct StateMachineTests {
    @Test("FILE-AC-06: the transition table allows exactly the documented edges")
    func table() {
        let allowed: [JobState: [JobCommand: JobState]] = [
            .pending: [.start: .running, .pause: .paused, .cancel: .cancelled],
            .running: [.pause: .paused, .cancel: .cancelled, .complete: .completed, .fail: .failed, .interrupt: .pending],
            .paused: [.resume: .pending, .cancel: .cancelled],
            .failed: [.retry: .pending, .cancel: .cancelled],
            .cancelled: [.retry: .pending],
            .completed: [:],
        ]
        for state in [JobState.pending, .running, .paused, .failed, .cancelled, .completed] {
            for command in JobCommand.allCases {
                #expect(JobStateMachine.next(from: state, command: command) == allowed[state]?[command], "\(state) + \(command)")
            }
        }
    }

    @Test("terminal states")
    func terminal() {
        #expect(JobStateMachine.isTerminal(.completed) && JobStateMachine.isTerminal(.failed) && JobStateMachine.isTerminal(.cancelled))
        #expect(!JobStateMachine.isTerminal(.paused) && !JobStateMachine.isTerminal(.pending) && !JobStateMachine.isTerminal(.running))
    }
}

@Suite("Resource policy")
struct ResourcePolicyTests {
    @Test("default concurrency follows the hardware tier")
    func defaults() {
        #expect(JobResourcePolicy.defaultConcurrency(for: .tier8) == 1)
        #expect(JobResourcePolicy.defaultConcurrency(for: .tier16) == 2)
        #expect(JobResourcePolicy.defaultConcurrency(for: .tier32Plus) == 2)
    }

    @Test("FILE-AC-13: battery and thermal lower concurrency and priority")
    func decisions() {
        let plain = JobResourcePolicy.decide(userMax: 4, onBattery: false, lowPriorityOnBattery: true, thermal: .nominal)
        #expect(plain == .init(concurrency: 4, priority: .medium))
        let battery = JobResourcePolicy.decide(userMax: 4, onBattery: true, lowPriorityOnBattery: true, thermal: .nominal)
        #expect(battery == .init(concurrency: 2, priority: .utility))
        let batteryOff = JobResourcePolicy.decide(userMax: 4, onBattery: true, lowPriorityOnBattery: false, thermal: .nominal)
        #expect(batteryOff == plain)
        let serious = JobResourcePolicy.decide(userMax: 4, onBattery: false, lowPriorityOnBattery: true, thermal: .serious)
        #expect(serious == .init(concurrency: 2, priority: .background))
        let critical = JobResourcePolicy.decide(userMax: 4, onBattery: false, lowPriorityOnBattery: true, thermal: .critical)
        #expect(critical == .init(concurrency: 1, priority: .background))
        #expect(JobResourcePolicy.decide(userMax: 1, onBattery: true, lowPriorityOnBattery: true, thermal: .serious).concurrency == 1)
    }
}

@Suite("Media scanning")
struct MediaScannerTests {
    @Test("FILE-AC-02: folders recurse and keep only supported media")
    func folders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID().uuidString)")
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        for name in ["a.mp3", "notes.txt", "sub/b.WAV", "sub/c.mov", "sub/readme.md", ".hidden.m4a"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(name))
        }
        let all = MediaFileScanner.expand([root], recursive: true).map(\.lastPathComponent)
        #expect(all == ["a.mp3", "b.WAV", "c.mov"])
        let top = MediaFileScanner.expand([root], recursive: false).map(\.lastPathComponent)
        #expect(top == ["a.mp3"])
        // An explicitly named file is kept even with an unknown type (it then fails its own job, FILE-AC-03).
        let odd = root.appendingPathComponent("notes.txt")
        #expect(MediaFileScanner.expand([odd], recursive: true) == [odd])
    }
}

@Suite("PersistentJobQueue")
struct PersistentJobQueueTests {
    @Test("FILE-AC-01/11: a job transcribes, persists segments and checkpoint, saves the transcript and notifies")
    func happyPath() async throws {
        let h = try Harness()
        let file = try h.makeFile("interview.wav")
        let ids = try await h.queue.enqueue(files: [file], settings: JobSettings(), recursive: false)
        let id = try #require(ids.first)
        #expect(await h.waitFor(id, .completed))

        let job = try #require(await h.job(id))
        #expect(job.progress == 1)
        #expect(job.engine == "whisperkit")
        #expect(job.checkpoint == JobCheckpoint(lastCompletedChunk: 3, mediaTime: 40))
        let segments = try await h.segments(of: job)
        #expect(segments.map(\.text) == ["seg 0", "seg 10", "seg 20", "seg 30"])
        let transcript = try await h.transcript(of: job)
        #expect(transcript.title == "interview")
        #expect(transcript.source == .file)
        #expect(transcript.duration == 40)
        #expect(transcript.languages == ["en"])
        let asset = try await h.asset(of: transcript)
        #expect(asset.kind == .audio)
        #expect(await h.until { !h.notifier.completed.isEmpty })
        #expect(h.notifier.completed.first?.transcriptTitle == "interview")
        #expect(h.notifier.batches.isEmpty)
        // The journal matches memory.
        #expect(try await h.database.jobs.allJobs().first?.state == .completed)
    }

    @Test("FILE-AC-06: illegal transitions are rejected and change nothing")
    func illegalTransitions() async throws {
        let h = try Harness()
        let id = try #require(try await h.queue.enqueue(files: [try h.makeFile()], settings: JobSettings(), recursive: false).first)
        #expect(await h.waitFor(id, .completed))
        await h.queue.resume(id)
        await h.queue.pause(id)
        await h.queue.retry(id)
        await h.queue.cancel(id)
        #expect(await h.job(id)?.state == .completed)

        h.engine.hold(true)
        let pending = try await h.queue.enqueue(Job(kind: .transcribeFile, state: .paused, input: try h.makeFile("p.wav")))
        await h.queue.retry(pending)  // paused -> retry is illegal
        #expect(await h.job(pending)?.state == .paused)
        await h.queue.resume(pending)
        #expect(await h.until { await h.job(pending)?.state == .running })
        await h.queue.resume(pending)  // running -> resume is illegal
        #expect(await h.job(pending)?.state == .running)
        await h.queue.cancel(pending)
        #expect(await h.waitFor(pending, .cancelled))
    }

    @Test("FILE-AC-10: an engine error becomes a retryable failed job with a reason")
    func engineFailureAndRetry() async throws {
        let h = try Harness()
        h.engine.fail(with: .engineFailure("whisperkit", reason: "CoreML exploded"))
        let id = try #require(
            try await h.queue.enqueue(files: [try h.makeFile("bad.wav")], settings: JobSettings(), recursive: false).first)
        #expect(await h.waitFor(id, .failed))
        let failed = try #require(await h.job(id))
        #expect(failed.failureReason?.contains("CoreML exploded") == true)
        #expect(await h.queue.failure(for: id) == .engineFailure("whisperkit", reason: "CoreML exploded"))
        #expect(await h.until { !h.notifier.failed.isEmpty })

        h.engine.fail(with: nil)
        await h.queue.retry(id)
        #expect(await h.waitFor(id, .completed))
        let done = try #require(await h.job(id))
        #expect(done.failureReason == nil)
        #expect(try await h.segments(of: done).count == 4)
    }

    @Test("FILE-AC-03: an undecodable file fails only its own job and the batch continues")
    func decodeFailureIsolated() async throws {
        let h = try Harness()
        let bad = try h.makeFile("a-bad.wav")
        let good = try h.makeFile("b-good.wav")
        h.decoder.failDecoding(with: .unsupportedFormat("DRM-protected"), forFileNamed: "a-bad.wav")
        let ids = try await h.queue.enqueue(files: [bad, good], settings: JobSettings(), recursive: false)
        #expect(await h.until { await h.queue.jobs().allSatisfy { JobStateMachine.isTerminal($0.state) } })
        let jobs = await h.queue.jobs()
        #expect(jobs.map(\.id) == ids)
        #expect(jobs.map(\.state) == [.failed, .completed])
        #expect(jobs[0].failureReason?.contains("DRM-protected") == true)
        #expect(jobs[0].failureReason?.contains("a-bad.wav") == true)
        #expect(h.notifier.batches == [JobBatchSummary(jobIDs: ids, completed: 1, failed: 1, cancelled: 0)])
    }

    @Test("FILE-AC-06: cancel stops a running job, keeps the partial transcript out of completion")
    func cancelRunning() async throws {
        let h = try Harness()
        h.engine.hold(true)
        let id = try #require(try await h.queue.enqueue(files: [try h.makeFile()], settings: JobSettings(), recursive: false).first)
        #expect(await h.until { h.engine.active == 1 })
        await h.queue.cancel(id)
        #expect(await h.waitFor(id, .cancelled))
        #expect(await h.until { h.engine.active == 0 })
        #expect(h.notifier.completed.isEmpty)

        // A cancelled job can be retried; it starts over.
        h.engine.hold(false)
        await h.queue.retry(id)
        #expect(await h.waitFor(id, .completed))
    }

    @Test("pause keeps the checkpoint; resume continues from it without duplicating segments")
    func pauseResume() async throws {
        let h = try Harness()
        h.engine.hold(true, afterChunks: 2)
        let id = try #require(try await h.queue.enqueue(files: [try h.makeFile()], settings: JobSettings(), recursive: false).first)
        #expect(await h.until { await h.job(id)?.checkpoint?.mediaTime == 20 })
        await h.queue.pause(id)
        #expect(await h.waitFor(id, .paused))
        let paused = try #require(await h.job(id))
        #expect(paused.checkpoint == JobCheckpoint(lastCompletedChunk: 1, mediaTime: 20))

        h.engine.hold(false)
        await h.queue.resume(id)
        #expect(await h.waitFor(id, .completed))
        #expect(h.decoder.decodeStarts == [0, 20])
        let done = try #require(await h.job(id))
        #expect(try await h.segments(of: done).map(\.start) == [0, 10, 20, 30])
    }

    @Test("FILE-AC-08: resume from the last checkpoint after a simulated crash, without duplicates")
    func crashResume() async throws {
        let db = try AppDatabase.inMemory()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("crash-\(UUID().uuidString).wav")
        try Data("x".utf8).write(to: file)
        // State on disk when the app died: two chunks committed, a third chunk's segment saved but its checkpoint not.
        let transcript = Transcript(title: "crash", source: .file, duration: 40)
        try await db.transcripts.save(transcript)
        let committed = [
            Segment(start: 0, end: 10, text: "seg 0"), Segment(start: 10, end: 20, text: "seg 10"),
            Segment(start: 20, end: 30, text: "orphan from the crashed chunk"),
        ]
        try await db.transcripts.upsertSegments(committed, for: transcript.id)
        let job = Job(
            kind: .transcribeFile, state: .running, input: file, transcriptID: transcript.id, progress: 0.5,
            checkpoint: JobCheckpoint(lastCompletedChunk: 1, mediaTime: 20))
        try await db.jobs.save(job)

        let h = try Harness(database: db)  // a fresh queue = a new process
        await h.queue.resumeInterrupted()
        #expect(await h.waitFor(job.id, .completed))
        #expect(h.decoder.decodeStarts == [20])
        let done = try #require(await h.job(job.id))
        let segments = try await h.segments(of: done)
        #expect(segments.map(\.start) == [0, 10, 20, 30])
        #expect(segments.map(\.text) == ["seg 0", "seg 10", "seg 20", "seg 30"])
        #expect(done.transcriptID == transcript.id)
    }

    @Test("resumeInterrupted leaves paused and failed jobs alone and requeues running ones")
    func resumeInterruptedStates() async throws {
        let db = try AppDatabase.inMemory()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ri-\(UUID().uuidString).wav")
        try Data("x".utf8).write(to: file)
        let paused = Job(kind: .transcribeFile, state: .paused, input: file)
        let failed = Job(kind: .transcribeFile, state: .failed, input: file, failureReason: "boom")
        let interrupted = Job(kind: .transcribeFile, state: .running, input: file)
        for job in [paused, failed, interrupted] { try await db.jobs.save(job) }
        let h = try Harness(database: db)
        await h.queue.resumeInterrupted()
        #expect(await h.waitFor(interrupted.id, .completed))
        #expect(await h.job(paused.id)?.state == .paused)
        #expect(await h.job(failed.id)?.state == .failed)
    }

    @Test("FILE-AC-07: concurrency limit is honoured and lowering it does not stop running jobs")
    func concurrencyLimit() async throws {
        let h = try Harness()
        h.engine.hold(true)
        await h.queue.setMaxConcurrency(2)
        let files = try (0..<4).map { try h.makeFile("f\($0).wav") }
        let ids = try await h.queue.enqueue(files: files, settings: JobSettings(), recursive: false)
        #expect(await h.until { h.engine.active == 2 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.engine.active == 2)
        #expect(await h.queue.jobs().filter { $0.state == .running }.count == 2)

        await h.queue.setMaxConcurrency(1)  // never cancels running jobs
        try await Task.sleep(for: .milliseconds(50))
        #expect(await h.queue.jobs().filter { $0.state == .running }.count == 2)

        h.engine.hold(false)
        for id in ids { #expect(await h.waitFor(id, .completed)) }
        #expect(h.engine.maxActive == 2)
    }

    @Test("FILE-AC-13: on battery with low-priority enabled only half the concurrency is used")
    func batteryLowersConcurrency() async throws {
        let h = try Harness()
        h.hardware.setBattery(true)
        h.engine.hold(true)
        await h.queue.setMaxConcurrency(2)
        let ids = try await h.queue.enqueue(
            files: try (0..<3).map { try h.makeFile("b\($0).wav") }, settings: JobSettings(), recursive: false)
        #expect(await h.until { h.engine.active == 1 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.engine.active == 1)
        // Turning the setting off applies to the next scheduling pass.
        await h.settings.set(false, for: JobsSettingsKey.lowPriorityOnBattery)
        h.engine.hold(false)
        for id in ids { #expect(await h.waitFor(id, .completed)) }
    }

    @Test("FILE-AC-13: serious thermal pressure throttles new starts")
    func thermalThrottle() async throws {
        let h = try Harness()
        h.engine.hold(true)
        await h.queue.setMaxConcurrency(2)
        // Start monitoring, then raise pressure before any job exists.
        await h.queue.resumeInterrupted()
        h.hardware.sendThermal(.serious)
        try await Task.sleep(for: .milliseconds(50))
        let ids = try await h.queue.enqueue(
            files: try (0..<2).map { try h.makeFile("t\($0).wav") }, settings: JobSettings(), recursive: false)
        #expect(await h.until { h.engine.active == 1 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.engine.active == 1)
        h.engine.hold(false)
        for id in ids { #expect(await h.waitFor(id, .completed)) }
    }

    @Test("FILE-AC-15: memory pressure holds new starts for a moment")
    func memoryPressureHold() async throws {
        let h = try Harness(memoryHold: .milliseconds(300))
        await h.queue.resumeInterrupted()
        h.hardware.sendMemoryPressure()
        try await Task.sleep(for: .milliseconds(50))
        let id = try #require(try await h.queue.enqueue(files: [try h.makeFile()], settings: JobSettings(), recursive: false).first)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await h.job(id)?.state == .pending)
        #expect(await h.waitFor(id, .completed))
    }

    @Test("FILE-AC-15: memory pressure unloads the engines once no job is running")
    func memoryPressureUnloads() async throws {
        let h = try Harness(memoryHold: .seconds(5))
        h.engine.hold(true)
        await h.queue.resumeInterrupted()
        let id = try #require(try await h.queue.enqueue(files: [try h.makeFile()], settings: JobSettings(), recursive: false).first)
        #expect(await h.until { h.engine.active == 1 })
        h.hardware.sendMemoryPressure()
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.engine.unloads == 0, "a running job keeps its model")
        h.engine.hold(false)
        #expect(await h.waitFor(id, .completed))
        #expect(await h.until { h.engine.unloads == 1 })
    }

    @Test("the pipeline factory receives the routed plan, so language ID can use the routed model")
    func pipelineFactoryGetsPlan() async throws {
        let h = try Harness()
        let id = try #require(try await h.queue.enqueue(files: [try h.makeFile()], settings: JobSettings(), recursive: false).first)
        #expect(await h.waitFor(id, .completed))
        let plan = try #require(h.plans.plans.first)
        #expect(plan.assignments.first?.engine == "whisperkit")
        #expect(plan.assignments.first?.model == Harness.largeModel)
    }

    @Test("installed models still go through ensureAvailable (tokenizer backfill, ENG-AC-14) but show no download note")
    func installedModelsAreEnsured() async throws {
        let h = try Harness()
        let id = try #require(try await h.queue.enqueue(files: [try h.makeFile()], settings: JobSettings(), recursive: false).first)
        #expect(await h.waitFor(id, .completed))
        #expect(h.models.ensured == [Harness.largeModel])
    }

    @Test("FILE-AC-07: reorder is honoured by the scheduler")
    func ordering() async throws {
        let h = try Harness()
        await h.queue.setMaxConcurrency(1)
        h.engine.hold(true)
        var ids: [JobID] = []
        for name in ["first", "second", "third", "fourth"] {
            ids += try await h.queue.enqueue(files: [try h.makeFile("\(name).wav")], settings: JobSettings(), recursive: false)
        }
        #expect(await h.until { h.engine.active == 1 })
        #expect(await h.queue.jobs().map(\.id) == ids)
        await h.queue.prioritize(ids[3], to: 1)  // behind the running job, ahead of the rest
        #expect(await h.queue.jobs().map(\.id) == [ids[0], ids[3], ids[1], ids[2]])
        // Persisted order matches (the repository sorts by priority).
        #expect(try await h.database.jobs.allJobs().map(\.id) == [ids[0], ids[3], ids[1], ids[2]])

        h.engine.hold(false)
        #expect(await h.until { h.notifier.completed.count == 4 })
        #expect(h.notifier.completed.map(\.job.id) == [ids[0], ids[3], ids[1], ids[2]])
    }

    @Test("a media file that disappears fails the job and maps to the job's media asset id")
    func missingMedia() async throws {
        let h = try Harness()
        let gone = h.folder.appendingPathComponent("moved-away.wav")
        let id = try await h.queue.enqueue(Job(kind: .transcribeFile, input: gone))
        #expect(await h.waitFor(id, .failed))
        let job = try #require(await h.job(id))
        #expect(await h.queue.failure(for: id) == .mediaMissing(MediaAssetID(id.rawValue)))
        #expect(job.failureReason?.contains("moved-away.wav") == true)
        #expect(PersistentJobQueue.mediaAssetID(for: job) == MediaAssetID(id.rawValue))
    }

    @Test("a decoder's placeholder media id is re-mapped to the real asset")
    func decoderPlaceholderRemap() async throws {
        let h = try Harness()
        h.decoder.failDecoding(with: .mediaMissing(MediaAssetID()))  // AVFileDecoder attaches a random id
        let id = try #require(try await h.queue.enqueue(files: [try h.makeFile()], settings: JobSettings(), recursive: false).first)
        #expect(await h.waitFor(id, .failed))
        let job = try #require(await h.job(id))
        let transcript = try await h.transcript(of: job)
        #expect(await h.queue.failure(for: id) == transcript.mediaAssetID.map { AppError.mediaMissing($0) })
        #expect(transcript.mediaAssetID == MediaAssetID(id.rawValue))
    }

    @Test("FILE-AC-05: a missing model downloads via ensureAvailable with progress and a status note, job stays running")
    func downloadProgress() async throws {
        let h = try Harness(installed: [])
        let notes = h.queue.noteChanges()
        let collector = Task { () -> [String] in
            var seen: [String] = []
            for await change in notes {
                if let note = change.note { seen.append(note) }
                if seen.contains(where: { $0.contains("(100%)") }) { break }
            }
            return seen
        }
        let events = h.queue.events()
        let watcher = Task { () -> [(JobState, Double)] in
            var seen: [(JobState, Double)] = []
            for await event in events {
                if case .updated(let job) = event {
                    seen.append((job.state, job.progress))
                    if job.state == .completed { break }
                }
            }
            return seen
        }
        let id = try #require(try await h.queue.enqueue(files: [try h.makeFile()], settings: JobSettings(), recursive: false).first)
        #expect(await h.waitFor(id, .completed))

        let seenNotes = await collector.value
        #expect(seenNotes.contains { $0.hasPrefix("Downloading Whisper large-v3") && $0.contains("(50%)") })
        #expect(seenNotes.contains { $0.contains("(100%)") })
        let seen = await watcher.value
        #expect(seen.contains { $0.0 == .running && $0.1 == 0.5 }, "download progress shows in job progress while running")
        #expect(await h.models.installedModels().contains(Harness.largeModel))
        #expect(await h.queue.statusNote(for: id) == nil)
    }

    @Test("a failed model download fails the job with the reason")
    func downloadFailure() async throws {
        let h = try Harness(installed: [])
        // An explicit model that is not in the catalog cannot be routed.
        let id = try await h.queue.enqueue(
            Job(kind: .transcribeFile, input: try h.makeFile(), settings: JobSettings(modelID: "nope/unknown")))
        #expect(await h.waitFor(id, .failed))
        #expect(await h.job(id)?.failureReason?.contains("nope/unknown") == true)
    }

    @Test("FILE-AC-11: post-processing uses the stored rules")
    func postProcessing() async throws {
        let h = try Harness()
        try await h.database.rules.saveReplacementRule(ReplacementRule(find: "seg", replacement: "SEGMENT"))
        let id = try #require(try await h.queue.enqueue(files: [try h.makeFile()], settings: JobSettings(), recursive: false).first)
        #expect(await h.waitFor(id, .completed))
        let segments = try await h.segments(of: try #require(await h.job(id)))
        #expect(segments.map(\.text) == ["SEGMENT 0", "SEGMENT 10", "SEGMENT 20", "SEGMENT 30"])

        let off = try await h.queue.enqueue(
            Job(kind: .transcribeFile, input: try h.makeFile("off.wav"), settings: JobSettings(applyReplacements: false)))
        #expect(await h.waitFor(off, .completed))
        #expect(try await h.segments(of: try #require(await h.job(off))).first?.text == "seg 0")
    }

    @Test("FILE-AC-11: diarization labels segments and records speakers")
    func diarization() async throws {
        let h = try Harness(diarizer: FakeDiarizer())
        let settings = JobSettings(diarize: true, diarization: ["min": 2, "max": 4])
        let id = try await h.queue.enqueue(Job(kind: .transcribeFile, input: try h.makeFile(), settings: settings))
        #expect(await h.waitFor(id, .completed))
        let job = try #require(await h.job(id))
        let segments = try await h.segments(of: job)
        let transcript = try await h.transcript(of: job)
        #expect(transcript.speakers.count == 2)
        #expect(segments.prefix(2).allSatisfy { $0.speakerID == transcript.speakers[0].id })
        #expect(segments.suffix(2).allSatisfy { $0.speakerID == transcript.speakers[1].id })
        #expect(await h.models.installedModels().contains("fluidaudio/diarization-community-1"))
    }

    @Test("diarization option mapping")
    func diarizationOptions() {
        #expect(PersistentJobQueue.diarizationOptions([:]).speakerCount == .auto)
        #expect(PersistentJobQueue.diarizationOptions(["exact": 3]).speakerCount == .exact(3))
        #expect(PersistentJobQueue.diarizationOptions(["min": 2, "max": 6]).speakerCount == .range(min: 2, max: 6))
        #expect(PersistentJobQueue.diarizationOptions(["min": 5, "max": 2]).speakerCount == .auto)
    }

    @Test("FILE-AC-12: auto-export writes the preset's file into the watch folder")
    func autoExport() async throws {
        let h = try Harness()
        let preset = try #require(ExportPresets.builtIn.first { $0.options.format == .txt })
        let id = try await h.queue.enqueue(
            Job(kind: .transcribeFile, input: try h.makeFile("meeting.wav"), settings: JobSettings(autoExportPresetID: preset.id)))
        #expect(await h.waitFor(id, .completed))
        #expect(await h.until { !h.notifier.completed.isEmpty })
        let exported = try #require(h.notifier.completed.first?.exportedTo)
        #expect(exported.deletingLastPathComponent().path == h.exportFolder.path)
        #expect(try String(contentsOf: exported, encoding: .utf8).contains("seg 10"))
    }

    @Test("a failing auto-export never fails the job")
    func autoExportFailure() async throws {
        let h = try Harness()
        let id = try await h.queue.enqueue(
            Job(kind: .transcribeFile, input: try h.makeFile(), settings: JobSettings(autoExportPresetID: PresetID())))
        #expect(await h.waitFor(id, .completed))
        #expect(await h.until { await h.queue.statusNote(for: id)?.contains("Auto-export failed") == true })
    }

    @Test("FILE-AC-11: a batch reports once through the batch notification")
    func batchNotification() async throws {
        let h = try Harness()
        let files = try ["a.wav", "b.wav", "c.wav"].map { try h.makeFile($0) }
        let ids = try await h.queue.enqueue(files: files, settings: JobSettings(), recursive: false)
        #expect(await h.until { !h.notifier.batches.isEmpty })
        #expect(h.notifier.batches == [JobBatchSummary(jobIDs: ids, completed: 3, failed: 0, cancelled: 0)])
        #expect(h.notifier.completed.isEmpty)
    }

    @Test("FILE-AC-02: enqueueing a folder creates one job per supported file")
    func enqueueFolder() async throws {
        let h = try Harness()
        _ = try h.makeFile("one.mp3")
        _ = try h.makeFile("deep/two.m4a")
        _ = try h.makeFile("deep/readme.txt")
        let ids = try await h.queue.enqueue(files: [h.folder], settings: JobSettings(diarize: false), recursive: true)
        #expect(ids.count == 2)
        let inputs = await h.queue.jobs().compactMap { $0.input?.lastPathComponent }
        #expect(inputs == ["two.m4a", "one.mp3"])  // sorted by path
    }

    @Test("events stream announces updates and removals")
    func events() async throws {
        let h = try Harness()
        let stream = h.queue.events()
        let id = try await h.queue.enqueue(Job(kind: .transcribeFile, state: .paused, input: try h.makeFile()))
        await h.queue.remove(id)
        var sawUpdate = false
        var sawRemoval = false
        for await event in stream {
            switch event {
            case .updated(let job): sawUpdate = sawUpdate || job.id == id
            case .removed(let removed): sawRemoval = removed == id
            }
            if sawRemoval { break }
        }
        #expect(sawUpdate && sawRemoval)
        #expect(await h.queue.jobs().isEmpty)
    }

    @Test("ETA appears while a long job runs")
    func eta() async throws {
        let h = try Harness()
        h.engine.hold(true, afterChunks: 2)
        let id = try #require(try await h.queue.enqueue(files: [try h.makeFile()], settings: JobSettings(), recursive: false).first)
        #expect(await h.until { await h.job(id)?.checkpoint?.mediaTime == 20 })
        // Let measurable time pass so the estimate is finite.
        try await Task.sleep(for: .milliseconds(20))
        let estimator = ETAEstimator(startedAt: Date(timeIntervalSinceNow: -10), startFraction: 0)
        #expect(estimator.eta(fraction: 0.5, now: Date())! > 9)
        #expect(estimator.eta(fraction: 0, now: Date()) == nil)
        #expect(estimator.eta(fraction: 1, now: Date()) == nil)
        h.engine.hold(false)
        #expect(await h.waitFor(id, .completed))
        #expect(await h.job(id)?.etaSeconds == nil)
    }
}
