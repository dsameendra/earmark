import AppCore
import Foundation

/// Creates the audio sources a meeting recording uses (backed by `AudioCapture`'s mic and app/system sources).
public protocol MeetingAudioSourceProviding: Sendable {
    func micSource(deviceUID: String?) -> any AudioSource
    /// Remote (everyone else) audio for the app, e.g. an app tap on its bundle ID.
    func remoteSource(for app: MeetingApp) -> any AudioSource
}

public struct MeetingSessionInfo: Sendable, Equatable {
    public var meetingID: MeetingID
    public var app: MeetingApp
    public var startedAt: Date
    public var transcribing: Bool
    public var recording: Bool
    public var recordsVideo: Bool
}

public enum MeetingSessionEvent: Sendable, Equatable {
    /// `askFirst` (or an auto behaviour downgraded by quiet hours / exclusions): show the notification (MTG-AC-04).
    case promptUser(MeetingApp, startedAt: Date, reason: MeetingDecisionReason)
    /// The meeting ended before the user answered the prompt.
    case promptDismissed(MeetingApp)
    case sessionStarted(MeetingSessionInfo)
    /// The one-time consent notice has not been acknowledged yet: show it / the reminder (MTG-AC-05, -11).
    case consentNoticeRequired
    /// Persistent recording indicator on/off (MTG-AC-10).
    case recordingIndicator(Bool)
    /// System/app audio permission denied or capture failed: continuing mic-only with recovery steps (MTG-AC-16).
    case remoteAudioUnavailable(reason: String)
    /// Remote capture delivers only zero buffers (silent permission denial).
    case remoteAudioSilent
    case recordingFailed(reason: String)
    case recorder(RecorderEvent)
    case sessionEnded(meetingID: MeetingID, finalizationJob: JobID?)
    case failed(reason: String)
}

/// Ties detection, policy, capture, recording and finalization together (MTG-AC-04, -05, -07, -14, -16, -17).
/// One meeting session at a time; the live transcript comes from `LiveSessionControlling`, the recording from the
/// recorder, and the post-meeting pass is queued as a `.finalizeMeeting` job.
public actor MeetingSessionController {
    private struct Active {
        var info: MeetingSessionInfo
        var meeting: Meeting
        var recorder: (any BookmarkingRecorder)?
        var directory: URL?
        var mic: (any AudioSource)?
        var remote: (any AudioSource)?
        var helpers: [Task<Void, Never>]
    }

    public typealias RecorderFactory = @Sendable (RecordingSession) -> any BookmarkingRecorder

    private let detector: any MeetingDetector
    private let policies: MeetingPolicyStore
    private let consent: MeetingConsentStore
    private let sources: any MeetingAudioSourceProviding
    private let makeRecorder: RecorderFactory
    private let recordingsRoot: @Sendable () async -> URL
    private let meetings: any MeetingRepository
    private let jobs: (any JobQueue)?
    private let live: (any LiveSessionControlling)?
    private let clock: any MeetingClock
    private let calendar: Calendar
    private let broadcaster = Broadcaster<MeetingSessionEvent>()
    private var active: Active?
    private var pendingPrompts: [MeetingApp: Date] = [:]
    private var listener: Task<Void, Never>?
    private let log = AppLog.logger("meetings.session")

    public init(
        detector: any MeetingDetector, policies: MeetingPolicyStore, consent: MeetingConsentStore,
        sources: any MeetingAudioSourceProviding, makeRecorder: @escaping RecorderFactory,
        recordingsRoot: @escaping @Sendable () async -> URL,
        meetings: any MeetingRepository, jobs: (any JobQueue)? = nil, live: (any LiveSessionControlling)? = nil,
        clock: any MeetingClock = SystemMeetingClock(), calendar: Calendar = .current
    ) {
        self.detector = detector
        self.policies = policies
        self.consent = consent
        self.sources = sources
        self.makeRecorder = makeRecorder
        self.recordingsRoot = recordingsRoot
        self.meetings = meetings
        self.jobs = jobs
        self.live = live
        self.clock = clock
        self.calendar = calendar
    }

    public nonisolated func events() -> AsyncStream<MeetingSessionEvent> { broadcaster.stream() }
    public var currentSession: MeetingSessionInfo? { active?.info }

    /// Starts reacting to detector events. Idempotent.
    public func start() {
        guard listener == nil else { return }
        let stream = detector.events()
        listener = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    public func shutdown() async {
        listener?.cancel()
        listener = nil
        if active != nil { _ = await stopSession() }
    }

    // MARK: Detector events

    public func handle(_ event: MeetingEvent) async {
        switch event {
        case .started(let app, let at):
            guard active == nil else { return }
            let decision = await policies.decide(for: app, now: clock.now())
            switch decision.action {
            case .ignore: break
            case .promptUser:
                pendingPrompts[app] = at
                broadcaster.send(.promptUser(app, startedAt: at, reason: decision.reason))
            case .transcribe:
                await startSession(app: app, startedAt: at, transcribe: true, record: false, video: false)
            case .transcribeAndRecord:
                await startSession(app: app, startedAt: at, transcribe: true, record: true, video: decision.recordVideo)
            }
        case .ended(let app, _):
            if pendingPrompts.removeValue(forKey: app) != nil { broadcaster.send(.promptDismissed(app)) }
            if active?.info.app == app { _ = await stopSession() }
        }
    }

    /// The user answered the prompt (or chose to start manually from the menu bar).
    public func startSession(app: MeetingApp, startedAt: Date? = nil, transcribe: Bool, record: Bool, video: Bool = false) async {
        guard active == nil, transcribe || record else { return }
        pendingPrompts[app] = nil
        let started = startedAt ?? clock.now()
        var meeting = Meeting(app: app, startedAt: started)
        try? await meetings.save(meeting)
        var info = MeetingSessionInfo(
            meetingID: meeting.id, app: app, startedAt: started, transcribing: transcribe, recording: false, recordsVideo: false)
        var state = Active(info: info, meeting: meeting, helpers: [])

        if record {
            if await consent.needsNotice() { broadcaster.send(.consentNoticeRequired) }
            await beginRecording(&state, video: video)
            info.recording = state.recorder != nil
            info.recordsVideo = state.recorder != nil && video
            state.info = info
        }
        if transcribe, let live {
            do {
                try await live.start(
                    LiveSessionConfig(source: .micAndSystem(deviceUID: nil, lanes: true), diarize: true, saveAsTranscript: true))
            } catch {
                broadcaster.send(.failed(reason: "Live transcription failed to start: \(error)"))
                info.transcribing = false
                state.info = info
            }
        }
        guard info.recording || info.transcribing else {
            meeting.deletedAt = clock.now()
            try? await meetings.save(meeting)
            return
        }
        active = state
        broadcaster.send(.sessionStarted(info))
        if info.recording { broadcaster.send(.recordingIndicator(true)) }
    }

    private func beginRecording(_ state: inout Active, video: Bool) async {
        let app = state.info.app
        let root = await recordingsRoot()
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let folder =
            "\(stamp.string(from: state.info.startedAt)) \(app == .zoom ? "Zoom" : "Teams") \(state.info.meetingID.rawValue.uuidString.prefix(8))"
        let directory = root.appendingPathComponent(folder, isDirectory: true)
        let recorder = makeRecorder(
            RecordingSession(meetingID: state.info.meetingID, app: app, startedAt: state.info.startedAt, relativeDirectory: folder))

        let mic = sources.micSource(deviceUID: nil)
        let remote = sources.remoteSource(for: app)
        let micStream: AsyncStream<AudioChunk>
        do { micStream = try await mic.start() } catch {
            broadcaster.send(.recordingFailed(reason: "Microphone unavailable: \(error)"))
            return
        }
        var remoteStream = AsyncStream<AudioChunk> { $0.finish() }
        do {
            remoteStream = try await remote.start()
            state.remote = remote
            let health = remote.health
            let notify = broadcaster
            state.helpers.append(
                Task {
                    for await h in health where h == .silent { notify.send(.remoteAudioSilent) }
                })
        } catch {
            broadcaster.send(.remoteAudioUnavailable(reason: String(describing: error)))
        }
        do {
            try await recorder.start(
                config: RecordingConfig(directory: directory, separateTracks: true, mixTrack: true, includeVideo: video), mic: micStream,
                remote: remoteStream)
        } catch {
            await mic.stop()
            await state.remote?.stop()
            state.remote = nil
            broadcaster.send(.recordingFailed(reason: String(describing: error)))
            return
        }
        if let rec = recorder as? MeetingRecorder {
            let events = rec.events()
            let notify = broadcaster
            state.helpers.append(Task { for await e in events { notify.send(.recorder(e)) } })
        }
        state.mic = mic
        state.recorder = recorder
        state.directory = directory
    }

    /// Stops capture, finalizes the recording and queues the post-meeting pass. Returns the queued job, if any.
    @discardableResult
    public func stopSession() async -> JobID? {
        guard var state = active else { return nil }
        active = nil
        await state.mic?.stop()
        await state.remote?.stop()
        var recording: Recording?
        if let recorder = state.recorder {
            do { recording = try await recorder.stop() } catch {
                broadcaster.send(.recordingFailed(reason: String(describing: error)))
            }
        }
        let liveID = await live?.stop()
        for helper in state.helpers { helper.cancel() }
        state.meeting.endedAt = clock.now()
        state.meeting.recording = recording
        state.meeting.transcriptID = liveID
        try? await meetings.save(state.meeting)
        if state.info.recording { broadcaster.send(.recordingIndicator(false)) }
        var jobID: JobID?
        if recording != nil, let directory = state.directory, let jobs {
            do {
                jobID = try await jobs.enqueue(MeetingFinalizer.makeJob(directory: directory, liveTranscriptID: liveID))
            } catch {
                broadcaster.send(.failed(reason: "Could not queue meeting finalization: \(error)"))
            }
        }
        broadcaster.send(.sessionEnded(meetingID: state.meeting.id, finalizationJob: jobID))
        return jobID
    }

    /// Bookmark at the current meeting time (MTG-AC-14), persisted in the crash-safe manifest.
    public func addBookmark(note: String = "") async {
        guard let state = active else { return }
        let time = max(0, clock.now().timeIntervalSince(state.info.startedAt))
        await state.recorder?.addBookmark(at: time, note: note)
    }

    /// Menu bar "Toggle auto-record" for the detected app (MTG-AC-17).
    @discardableResult
    public func toggleAutoRecord(for app: MeetingApp) async -> MeetingPolicy { await policies.toggleAutoRecord(for: app) }
}
