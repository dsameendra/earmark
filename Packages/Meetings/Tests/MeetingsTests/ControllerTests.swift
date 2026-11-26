import AppCore
import AppCoreTesting
import Foundation
import Testing
import os

@testable import Meetings

private final class FakeDetector: MeetingDetector {
    let broadcaster = Broadcaster<MeetingEvent>()
    func events() -> AsyncStream<MeetingEvent> { broadcaster.stream() }
}

/// Holds a start open so a test can deliver a detector event in the middle of it.
private actor Latch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private final class FakeSources: MeetingAudioSourceProviding {
    let remoteFailure: AppError?
    let log: CallLog
    let hold: Latch?
    init(remoteFailure: AppError? = nil, log: CallLog, hold: Latch? = nil) {
        self.remoteFailure = remoteFailure
        self.log = log
        self.hold = hold
    }
    func micSource(deviceUID: String?) -> any AudioSource { StubSource(tag: .mic(deviceUID: nil), failure: nil, name: "mic", log: log) }
    /// The Meetings override from Settings > Audio.
    func preferredMicDeviceUID() async -> String? { "usb-meetings" }
    func makeMicSource() async -> any AudioSource {
        await log.add("mic.device=\(await preferredMicDeviceUID() ?? "default")")
        await hold?.wait()
        return micSource(deviceUID: await preferredMicDeviceUID())
    }
    func remoteSource(for app: MeetingApp) -> any AudioSource {
        StubSource(tag: .app(bundleID: app.bundleIDs[0]), failure: remoteFailure, name: "remote", log: log)
    }
}

private final class StubSource: AudioSource {
    let tag: AudioSourceTag
    let failure: AppError?
    let name: String
    let log: CallLog
    init(tag: AudioSourceTag, failure: AppError?, name: String, log: CallLog) {
        self.tag = tag
        self.failure = failure
        self.name = name
        self.log = log
    }
    func start() async throws -> AsyncStream<AudioChunk> {
        if let failure { throw failure }
        await log.add("\(name).start")
        return AsyncStream { _ in }
    }
    func stop() async { await log.add("\(name).stop") }
    var levels: AsyncStream<Float> { AsyncStream { $0.finish() } }
    var health: AsyncStream<AudioSourceHealth> { AsyncStream { $0.finish() } }
}

private final class FakeRecorder: BookmarkingRecorder {
    let log: CallLog
    let state = OSAllocatedUnfairLock(initialState: (started: false, bookmarks: [(TimeInterval, String)]()))
    let failStart: Bool
    init(log: CallLog, failStart: Bool = false) {
        self.log = log
        self.failStart = failStart
    }
    func start(config: RecordingConfig, mic: AsyncStream<AudioChunk>, remote: AsyncStream<AudioChunk>) async throws {
        if failStart { throw RecorderError.insufficientDiskSpace(availableBytes: 1, requiredBytes: 2) }
        state.withLock { $0.started = true }
        await log.add("recorder.start:\(config.directory.lastPathComponent):video=\(config.includeVideo)")
    }
    func stop() async throws -> Recording {
        await log.add("recorder.stop")
        return Recording(tracks: [RecordingTrack(role: .mix, relativePath: "mix.m4a")], duration: 42)
    }
    var isRecording: Bool { state.withLock { $0.started } }
    func addBookmark(at time: TimeInterval, note: String) async { state.withLock { $0.bookmarks.append((time, note)) } }
}

private actor FakeJobs: JobQueue {
    var enqueued: [Job] = []
    func enqueue(_ job: Job) async throws -> JobID {
        enqueued.append(job)
        return job.id
    }
    func enqueue(files: [URL], settings: JobSettings, recursive: Bool) async throws -> [JobID] { [] }
    func prioritize(_ id: JobID, to index: Int) async {}
    func pause(_ id: JobID) async {}
    func resume(_ id: JobID) async {}
    func cancel(_ id: JobID) async {}
    func retry(_ id: JobID) async {}
    func setMaxConcurrency(_ n: Int) async {}
    func jobs() async -> [Job] { enqueued }
    nonisolated func events() -> AsyncStream<JobEvent> { AsyncStream { $0.finish() } }
    func resumeInterrupted() async {}
}

private final class FakeLive: LiveSessionControlling {
    let log: CallLog
    let transcriptID = TranscriptID()
    init(log: CallLog) { self.log = log }
    func start(_ config: LiveSessionConfig) async throws {
        await log.add("live.start:diarize=\(config.diarize):save=\(config.saveAsTranscript)")
        if case .micAndSystem(let uid, _) = config.source { await log.add("live.mic=\(uid ?? "default")") }
    }
    func stop() async -> TranscriptID? {
        await log.add("live.stop")
        return transcriptID
    }
    func state() -> AsyncStream<LiveSessionState> { AsyncStream { $0.finish() } }
    func lines() -> AsyncStream<[CaptionLine]> { AsyncStream { $0.finish() } }
}

private struct Rig {
    let detector = FakeDetector()
    let settings = InMemorySettings()
    let meetings = InMemoryMeetings()
    let jobs = FakeJobs()
    let clock = ManualClock()
    let live: FakeLive
    let recorder: FakeRecorder
    let transcripts = InMemoryTranscripts()
    let controller: MeetingSessionController
    let sessionEvents: Collector<MeetingSessionEvent>

    let latch = Latch()

    init(remoteFailure: AppError? = nil, recorderFails: Bool = false, holdStart: Bool = false) {
        let log = CallLog()
        self.live = FakeLive(log: log)
        let recorder = FakeRecorder(log: log, failStart: recorderFails)
        self.recorder = recorder
        let policies = MeetingPolicyStore(store: settings)
        controller = MeetingSessionController(
            detector: detector, policies: policies, consent: MeetingConsentStore(store: settings),
            sources: FakeSources(remoteFailure: remoteFailure, log: log, hold: holdStart ? latch : nil), makeRecorder: { _ in recorder },
            recordingsRoot: { URL(fileURLWithPath: "/tmp/earmark-test-root") }, meetings: meetings, jobs: jobs, live: live,
            transcripts: transcripts, clock: clock)
        sessionEvents = Collector(controller.events())
        self.logRef = log
    }
    let logRef: CallLog

    func setBehavior(_ b: MeetingBehavior, quiet: ClosedRange<Int>? = nil, video: Bool = false) async {
        await MeetingPolicyStore(store: settings).save(MeetingPolicy(app: .zoom, behavior: b, recordVideo: video))
    }
    func zoomStarted() async { await controller.handle(.started(.zoom, at: clock.now())) }
}

@Suite("Meeting session controller", .timeLimit(.minutes(1)))
struct ControllerTests {
    // MTG-AC-03 / -04
    @Test("default policy prompts instead of starting")
    func askFirstPrompts() async {
        let rig = Rig()
        await rig.zoomStarted()
        let events = await rig.sessionEvents.settled()
        #expect(events == [.promptUser(.zoom, startedAt: rig.clock.now(), reason: .configured)])
        #expect(await rig.controller.currentSession == nil)
        #expect(await rig.logRef.entries.isEmpty)
    }

    @Test("doNothing ignores the meeting")
    func ignore() async {
        let rig = Rig()
        await rig.setBehavior(.doNothing)
        await rig.zoomStarted()
        #expect(await rig.sessionEvents.settled().isEmpty)
    }

    // MTG-AC-05
    @Test("autoTranscribe starts live transcription only")
    func autoTranscribe() async {
        let rig = Rig()
        await rig.setBehavior(.autoTranscribe)
        await rig.zoomStarted()
        #expect(await rig.logRef.entries == ["live.start:diarize=true:save=true", "live.mic=usb-meetings"])
        let session = await rig.controller.currentSession
        #expect(session?.transcribing == true)
        #expect(session?.recording == false)
    }

    @Test("a transcribe-only meeting is saved as a meeting transcript named after the service")
    func transcribeOnlyIsNamed() async throws {
        let rig = Rig()
        await rig.setBehavior(.autoTranscribe)
        await rig.zoomStarted()
        try await rig.transcripts.save(Transcript(id: rig.live.transcriptID, title: "Live captions", source: .liveCaptions))
        _ = await rig.controller.stopSession()
        let saved = try #require(await rig.transcripts.transcript(rig.live.transcriptID))
        #expect(saved.source == .meeting)
        #expect(saved.title.hasPrefix("Zoom meeting, "))
        #expect(saved.meetingID != nil)
    }

    @Test("autoTranscribeAndRecord records both tracks, shows the indicator and the one-time consent reminder")
    func autoRecord() async {
        let rig = Rig()
        await rig.setBehavior(.autoTranscribeAndRecord, video: true)
        await rig.zoomStarted()
        let events = await rig.sessionEvents.settled()
        #expect(events.contains(.consentNoticeRequired))
        #expect(events.contains(.recordingIndicator(true)))
        let log = await rig.logRef.entries
        #expect(log.contains("mic.start") && log.contains("remote.start"))
        #expect(log.contains("mic.device=usb-meetings"), "the recording uses the Meetings microphone choice")
        #expect(log.contains("live.mic=usb-meetings"), "live transcription of the meeting uses it too")
        #expect(log.contains { $0.hasPrefix("recorder.start:") && $0.hasSuffix("video=true") })
        #expect(await rig.controller.currentSession?.recordsVideo == true)

        // Once the user acknowledged the notice it is not requested again.
        await MeetingConsentStore(store: rig.settings).recordAcknowledged()
        _ = await rig.controller.stopSession()
        await rig.zoomStarted()
        let second = await rig.sessionEvents.settled().filter { $0 == .consentNoticeRequired }
        #expect(second.count == 1)
    }

    @Test("two concurrent starts open exactly one recording")
    func concurrentStartsAreRejected() async {
        let rig = Rig()
        async let first: Void = rig.controller.startSession(app: .zoom, transcribe: true, record: true)
        async let second: Void = rig.controller.startSession(app: .zoom, transcribe: true, record: true)
        _ = await (first, second)
        let log = await rig.logRef.entries
        #expect(log.filter { $0 == "mic.start" }.count == 1)
        #expect(log.filter { $0.hasPrefix("recorder.start:") }.count == 1)
        #expect(await rig.controller.currentSession != nil)
    }

    @Test("a meeting that ends while capture is still starting does not leave a recording running")
    func endedWhileStarting() async throws {
        let rig = Rig(holdStart: true)
        await rig.setBehavior(.autoTranscribeAndRecord)
        let starting = Task { await rig.zoomStarted() }
        while await !rig.logRef.entries.contains(where: { $0.hasPrefix("mic.device=") }) { try await Task.sleep(for: .milliseconds(5)) }
        await rig.controller.handle(.ended(.zoom, at: rig.clock.now()))
        await rig.latch.open()
        await starting.value
        #expect(await rig.controller.currentSession == nil, "the ended meeting must not stay recording")
        let log = await rig.logRef.entries
        #expect(log.contains("recorder.stop") && log.contains("live.stop") && log.contains("mic.stop"))
    }

    // MTG-AC-06
    @Test("quiet hours and exclusions fall back to asking")
    func quietHoursPrompt() async {
        let rig = Rig()
        let hour = Calendar.current.component(.hour, from: rig.clock.now())
        await MeetingPolicyStore(store: rig.settings).save(
            MeetingPolicy(app: .zoom, behavior: .autoTranscribeAndRecord, quietHours: hour...(hour + 1)))
        await rig.zoomStarted()
        let events = await rig.sessionEvents.settled()
        #expect(events.first == .promptUser(.zoom, startedAt: rig.clock.now(), reason: .quietHours))
        #expect(await rig.controller.currentSession == nil)
    }

    // MTG-AC-07
    @Test("meeting end stops capture, links the live transcript and queues finalization")
    func endQueuesFinalization() async throws {
        let rig = Rig()
        await rig.setBehavior(.autoTranscribeAndRecord)
        await rig.zoomStarted()
        rig.clock.advance(by: 600)
        await rig.controller.handle(.ended(.zoom, at: rig.clock.now()))
        let log = await rig.logRef.entries
        #expect(log.firstIndex(of: "recorder.stop")! > log.firstIndex(of: "mic.stop")!)
        #expect(log.contains("live.stop"))
        let queued = try #require(await rig.jobs.enqueued.first)
        #expect(queued.kind == .finalizeMeeting)
        #expect(queued.transcriptID == rig.live.transcriptID)
        #expect(queued.input?.lastPathComponent.contains("Zoom") == true)
        let saved = try #require(await rig.meetings.saved.first)
        #expect(saved.endedAt == rig.clock.now())
        #expect(saved.recording?.duration == 42)
        #expect(saved.transcriptID == rig.live.transcriptID)
        let events = await rig.sessionEvents.settled()
        #expect(events.contains(.recordingIndicator(false)))
        #expect(events.contains(.sessionEnded(meetingID: saved.id, finalizationJob: queued.id)))
        #expect(await rig.controller.currentSession == nil)
    }

    @Test("transcribe-only meetings queue no finalization job")
    func transcribeOnlyNoJob() async {
        let rig = Rig()
        await rig.setBehavior(.autoTranscribe)
        await rig.zoomStarted()
        await rig.controller.handle(.ended(.zoom, at: rig.clock.now()))
        #expect(await rig.jobs.enqueued.isEmpty)
    }

    @Test("ending before the prompt was answered dismisses it")
    func promptDismissed() async {
        let rig = Rig()
        await rig.zoomStarted()
        await rig.controller.handle(.ended(.zoom, at: rig.clock.now()))
        #expect(await rig.sessionEvents.settled().contains(.promptDismissed(.zoom)))
    }

    @Test("answering the prompt starts the chosen actions")
    func promptAnswer() async {
        let rig = Rig()
        await rig.zoomStarted()
        await rig.controller.startSession(app: .zoom, transcribe: true, record: true)
        #expect(await rig.controller.currentSession?.recording == true)
        await rig.controller.handle(.ended(.zoom, at: rig.clock.now()))
        #expect(await rig.sessionEvents.settled().contains(.promptDismissed(.zoom)) == false)
    }

    // MTG-AC-16
    @Test("denied system audio continues mic-only with a recovery event")
    func remoteDenied() async {
        let rig = Rig(remoteFailure: .permissionDenied(.systemAudioRecording))
        await rig.setBehavior(.autoTranscribeAndRecord)
        await rig.zoomStarted()
        let events = await rig.sessionEvents.settled()
        #expect(events.contains { if case .remoteAudioUnavailable = $0 { true } else { false } })
        #expect(await rig.controller.currentSession?.recording == true)
        let log = await rig.logRef.entries
        #expect(log.contains("mic.start"))
        #expect(!log.contains("remote.start"))
    }

    @Test("a recorder that cannot start (low disk) leaves transcription running")
    func recorderFails() async {
        let rig = Rig(recorderFails: true)
        await rig.setBehavior(.autoTranscribeAndRecord)
        await rig.zoomStarted()
        let events = await rig.sessionEvents.settled()
        #expect(events.contains { if case .recordingFailed = $0 { true } else { false } })
        let session = await rig.controller.currentSession
        #expect(session?.recording == false)
        #expect(session?.transcribing == true)
        let log = await rig.logRef.entries
        #expect(log.contains("mic.stop"))  // sources released when the recorder fails
    }

    // MTG-AC-17
    @Test("toggle auto-record flips the stored policy")
    func toggle() async {
        let rig = Rig()
        #expect(await rig.controller.toggleAutoRecord(for: .zoom).behavior == .autoTranscribeAndRecord)
        await rig.zoomStarted()
        #expect(await rig.controller.currentSession?.recording == true)
    }

    @Test("a second app's meeting is not started while one is active")
    func oneSessionAtATime() async {
        let rig = Rig()
        await rig.setBehavior(.autoTranscribe)
        await rig.zoomStarted()
        await MeetingPolicyStore(store: rig.settings).save(MeetingPolicy(app: .teams, behavior: .autoTranscribe))
        await rig.controller.handle(.started(.teams, at: rig.clock.now()))
        #expect(await rig.controller.currentSession?.app == .zoom)
        #expect(await rig.logRef.entries.filter { $0.hasPrefix("live.start") }.count == 1)
    }

    // MTG-AC-14
    @Test("bookmarks are timed from when capture began, not from the detector's earlier meeting start")
    func bookmarkTiming() async {
        let rig = Rig()
        await rig.setBehavior(.autoTranscribeAndRecord)
        let detectedAt = rig.clock.now()
        rig.clock.advance(by: 3)  // debounce elapsed before the event is handled
        await rig.controller.handle(.started(.zoom, at: detectedAt))
        rig.clock.advance(by: 90)
        await rig.controller.addBookmark(note: "decision")
        let marks = rig.recorder.state.withLock { $0.bookmarks }
        #expect(marks.count == 1)
        #expect(marks.first?.0 == 90)
        #expect(marks.first?.1 == "decision")
        #expect(await rig.sessionEvents.settled().contains(.bookmarkAdded(time: 90, note: "decision")))
        #expect(await rig.controller.currentSession?.startedAt == detectedAt)
    }

    @Test("bookmarks in a transcribe-only meeting are saved on the live transcript")
    func bookmarkTranscribeOnly() async {
        let rig = Rig()
        await rig.setBehavior(.autoTranscribe)
        await rig.zoomStarted()
        rig.clock.advance(by: 30)
        await rig.controller.addBookmark(note: "action item")
        _ = await rig.controller.stopSession()
        let saved = await rig.transcripts.bookmarkStore
        #expect(saved.map(\.note) == ["action item"])
        #expect(saved.first?.time == 30)
        #expect(saved.first?.transcriptID == rig.live.transcriptID)
    }

    @Test("bookmark without a session is ignored")
    func bookmarkIdle() async {
        let rig = Rig()
        await rig.controller.addBookmark(note: "nothing")
        #expect(await rig.sessionEvents.settled().isEmpty)
    }

    @Test("detector events drive the controller end to end")
    func viaDetector() async {
        let rig = Rig()
        await rig.setBehavior(.autoTranscribe)
        await rig.controller.start()
        rig.detector.broadcaster.send(.started(.zoom, at: rig.clock.now()))
        for _ in 0..<500 where await rig.controller.currentSession == nil { try? await Task.sleep(for: .milliseconds(2)) }
        #expect(await rig.controller.currentSession?.app == .zoom)
        rig.detector.broadcaster.send(.ended(.zoom, at: rig.clock.now()))
        for _ in 0..<500 where await rig.controller.currentSession != nil { try? await Task.sleep(for: .milliseconds(2)) }
        #expect(await rig.controller.currentSession == nil)
        await rig.controller.shutdown()
    }
}
