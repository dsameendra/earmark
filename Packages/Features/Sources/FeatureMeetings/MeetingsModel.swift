import AppCore
import FeatureSupport
import Foundation
import Observation

/// A meeting the detector reported and that has not ended yet.
public struct DetectedMeeting: Equatable, Identifiable, Sendable {
    public var app: MeetingApp
    public var startedAt: Date
    public var decision: MeetingDecision
    /// The user dismissed the banner ("Dismiss" or "Ignore this meeting"); it stays dismissed until the meeting ends.
    public var isDismissed = false
    public var id: MeetingApp { app }
}

/// One row in the meetings list, built from data that exists: the meeting, its transcript header and its recording.
public struct MeetingRowInfo: Identifiable, Equatable, Sendable {
    public var meeting: Meeting
    public var title: String
    public var speakerCount: Int?
    public var id: MeetingID { meeting.id }

    public var duration: TimeInterval? {
        if let recording = meeting.recording, recording.duration > 0 { return recording.duration }
        return meeting.endedAt.map { $0.timeIntervalSince(meeting.startedAt) }
    }

    /// "Mic + system audio, video", "Mic only" or "Transcript only".
    public var capturesDescription: String {
        guard let recording = meeting.recording else { return "Transcript only" }
        let roles = Set(recording.tracks.map(\.role))
        var parts: [String] = []
        if roles.contains(.mic) && roles.contains(.remote) {
            parts.append("Mic + system audio")
        } else if roles.contains(.mic) {
            parts.append("Mic only")
        } else if roles.contains(.remote) {
            parts.append("System audio")
        } else if roles.contains(.mix) {
            parts.append("Mixed audio")
        }
        if roles.contains(.video) { parts.append("video") }
        return parts.isEmpty ? "Recording" : parts.joined(separator: ", ")
    }

    public var isRecorded: Bool { meeting.recording != nil }
}

/// What the current-meeting card shows.
public struct CurrentMeeting: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case detected
        case starting
        case capturing(MeetingCaptureMode, since: Date)
        case stopping
        case failed(String)
    }
    public var app: MeetingApp
    public var phase: Phase
    public var startedAt: Date?
}

/// A Record request waiting for the consent notice to be acknowledged.
public struct PendingRecording: Equatable, Sendable {
    public var app: MeetingApp
    public var mode: MeetingCaptureMode
    public init(app: MeetingApp, mode: MeetingCaptureMode) {
        self.app = app
        self.mode = mode
    }
}

/// Drives the Meetings screen and the app-lifetime meeting automation: detection, prompt policy, notification
/// responses, the consent gate and capture control. `start()` runs the follow loops once at launch, independent of
/// which screen is visible; the view only calls `load()`.
@MainActor @Observable
public final class MeetingsModel {
    public private(set) var rows: [MeetingRowInfo] = []
    public private(set) var isLoading = true
    public private(set) var errorMessage: String?
    /// Active detections by app (one entry per running meeting).
    public private(set) var detections: [MeetingApp: DetectedMeeting] = [:]
    public private(set) var captureState: MeetingCaptureState = .idle
    public private(set) var lines: [CaptionLine] = []
    public private(set) var policies: [MeetingApp: MeetingPolicy] = [:]
    /// Set when Record was chosen before the consent notice was acknowledged.
    public private(set) var pendingRecording: PendingRecording?
    /// Set when an automatic recording started before the notice was acknowledged (shown once, non-blocking).
    public private(set) var consentReminder: MeetingApp?
    public private(set) var finishedTranscriptID: TranscriptID?
    public private(set) var actionError: String?
    public let consent: MeetingConsentModel
    /// Asks the shell to bring the Meetings section forward (set by the shell).
    @ObservationIgnored public var navigate: (@MainActor () -> Void)?

    @ObservationIgnored private let repository: any MeetingRepository
    @ObservationIgnored private let transcripts: any TranscriptRepository
    @ObservationIgnored private let detector: any MeetingDetector
    @ObservationIgnored private let capture: (any MeetingCapturing)?
    @ObservationIgnored private let prompter: (any MeetingPromptPresenting)?
    @ObservationIgnored private let live: any LiveSessionControlling
    @ObservationIgnored private let settings: any SettingsStore
    /// Microphone and System Audio Recording, the two permissions a meeting capture needs (Screen Recording only adds video).
    @ObservationIgnored public let permissionGate: PermissionGateModel
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private var liveState: LiveSessionState = .idle
    @ObservationIgnored private var usesLiveFallback = false
    @ObservationIgnored private var runTask: Task<Void, Never>?
    /// Apps whose current detection the user dismissed or ignored, and until when a re-detection of the same app stays
    /// quiet after that meeting "ended". Output-only (listen-only) calls can fall silent past the end grace and be
    /// detected again a moment later; without this the user would be asked again about the call they just ignored.
    @ObservationIgnored private var dismissedByUser: Set<MeetingApp> = []
    @ObservationIgnored private var quietUntil: [MeetingApp: Date] = [:]
    static let reDetectionQuietPeriod: TimeInterval = 5 * 60

    public init(services: AppServices, clock: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .current) {
        repository = services.meetings
        transcripts = services.transcripts
        detector = services.meetingDetector
        capture = services.meetingCapture
        prompter = services.meetingPrompts
        live = services.live
        settings = services.settings
        consent = MeetingConsentModel(store: services.settings)
        permissionGate = PermissionGateModel(kinds: [.microphone, .systemAudioRecording], service: services.permissions)
        self.clock = clock
        self.calendar = calendar
    }

    // MARK: Derived state

    /// Banners to show: prompt-decision detections the user has not dismissed, while nothing is being captured.
    public var bannerDetections: [DetectedMeeting] {
        guard !captureState.isActive else { return [] }
        return detections.values.filter { $0.decision == .prompt && !$0.isDismissed }.sorted { $0.startedAt < $1.startedAt }
    }

    public var currentMeeting: CurrentMeeting? {
        switch captureState {
        case .capturing(let app, let mode, let since): return CurrentMeeting(app: app, phase: .capturing(mode, since: since), startedAt: since)
        case .starting:
            let app = detections.values.min { $0.startedAt < $1.startedAt }?.app ?? pendingApp
            return app.map { CurrentMeeting(app: $0, phase: .starting, startedAt: detections[$0]?.startedAt) }
        case .stopping:
            let app = detections.values.min { $0.startedAt < $1.startedAt }?.app ?? pendingApp
            return app.map { CurrentMeeting(app: $0, phase: .stopping, startedAt: detections[$0]?.startedAt) }
        case .failed(let message):
            let app = detections.values.min { $0.startedAt < $1.startedAt }?.app ?? pendingApp
            return app.map { CurrentMeeting(app: $0, phase: .failed(message), startedAt: detections[$0]?.startedAt) }
        case .idle:
            guard let detected = detections.values.filter({ !$0.isDismissed }).min(by: { $0.startedAt < $1.startedAt }) else { return nil }
            return CurrentMeeting(app: detected.app, phase: .detected, startedAt: detected.startedAt)
        }
    }

    @ObservationIgnored private var lastApp: MeetingApp?
    private var pendingApp: MeetingApp? { lastApp }

    public var isRecording: Bool {
        if case .capturing(_, let mode, _) = captureState { return mode.recordsAudio }
        return false
    }

    /// Whether this build can capture at all: the meeting runtime, or live captions for transcribe-only.
    public var canRecord: Bool { capture != nil }

    public func policy(for app: MeetingApp) -> MeetingPolicy { policies[app] ?? MeetingPolicy(app: app) }

    // MARK: Lifecycle

    /// Starts the follow loops (detector, notification responses, capture state and lines). Idempotent.
    public func start() {
        guard runTask == nil else { return }
        runTask = Task { [weak self] in await self?.run() }
    }

    public func stopFollowing() {
        runTask?.cancel()
        runTask = nil
    }

    /// Follows every source until cancelled.
    public func run() async {
        await consent.load()
        await loadPolicies()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.watchDetector() }
            group.addTask { await self.watchResponses() }
            group.addTask { await self.watchCapture() }
            group.addTask { await self.watchLines() }
            group.addTask { await self.watchLive() }
        }
    }

    public func load() async {
        do {
            let meetings = try await repository.meetings().sorted { $0.startedAt > $1.startedAt }
            var built: [MeetingRowInfo] = []
            for meeting in meetings {
                var transcript: Transcript?
                if let id = meeting.transcriptID { transcript = try? await transcripts.transcript(id) }
                built.append(
                    MeetingRowInfo(
                        meeting: meeting, title: transcript?.title ?? "\(meeting.app.badgeTitle) meeting",
                        speakerCount: transcript.map { $0.speakers.count }))
            }
            rows = built
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
        isLoading = false
        await loadPolicies()
        if !consent.isLoaded { await consent.load() }
    }

    public func loadPolicies() async {
        for app in MeetingApp.allCases {
            policies[app] = await settings.value(for: SettingsKey.meetingPolicy(app.rawValue), as: MeetingPolicy.self) ?? MeetingPolicy(app: app)
        }
    }

    // MARK: Following

    private func watchDetector() async {
        for await event in detector.events() { await handle(event) }
    }

    private func watchResponses() async {
        guard let prompter else { return }
        for await response in prompter.responses() { await handle(response) }
    }

    private func watchCapture() async {
        guard let capture else { return }
        for await next in capture.state() { apply(captureState: next) }
    }

    private func watchLines() async {
        let stream = capture?.lines() ?? live.lines()
        for await next in stream where captureState.isActive || !next.isEmpty { lines = next }
    }

    private func watchLive() async {
        for await state in live.state() {
            liveState = state
            guard usesLiveFallback else { continue }
            switch state {
            case .idle: apply(captureState: .idle)
            case .failed(let message): apply(captureState: .failed(message))
            default: break
            }
        }
    }

    private func apply(captureState next: MeetingCaptureState) {
        captureState = next
        if case .capturing(let app, _, _) = next { lastApp = app }
        if next == .idle {
            lines = []
            usesLiveFallback = false
        }
    }

    // MARK: Detector events and policy

    /// Handles one detector event (MTG-AC-01..06). Repeated `.started` for an active app is ignored; `.ended` clears only
    /// that app's detection, its "ignore this meeting" suppression and its delivered notification.
    public func handle(_ event: MeetingEvent) async {
        switch event {
        case .started(let app, let date):
            guard detections[app] == nil else { return }
            let policy = await loadPolicy(app)
            policies[app] = policy
            let decision = MeetingPromptPolicy.decide(policy: policy, hour: MeetingPromptPolicy.hour(of: date, calendar: calendar))
            var detected = DetectedMeeting(app: app, startedAt: date, decision: decision)
            if decision == .prompt, let until = quietUntil[app], date < until { detected.isDismissed = true }
            detections[app] = detected
            lastApp = app
            if detected.isDismissed { return }
            switch decision {
            case .none: break
            case .prompt: await prompter?.present(MeetingPrompt(app: app, startedAt: date))
            case .auto(let record): await startCapture(app, mode: record ? .transcribeAndRecord : .transcribeOnly, automatic: true)
            }
        case .ended(let app, let date):
            if dismissedByUser.remove(app) != nil { quietUntil[app] = date.addingTimeInterval(Self.reDetectionQuietPeriod) }
            detections[app] = nil
            if pendingRecording?.app == app { pendingRecording = nil }
            await prompter?.withdraw(app: app)
        }
    }

    /// Handles a notification action (MTG-AC-04): Record, Transcribe only, Ignore this meeting, Always, Never.
    public func handle(_ response: MeetingPromptResponse) async {
        let app = response.app
        guard let action = response.action else {
            navigate?()
            return
        }
        if let behavior = MeetingPromptPolicy.behavior(after: action) { await setBehavior(behavior, for: app) }
        switch action {
        case .record: await startCapture(app, mode: .transcribeAndRecord)
        case .transcribeOnly, .alwaysForApp: await startCapture(app, mode: .transcribeOnly)
        case .ignoreThisMeeting, .neverForApp: await dismissDetection(app)
        }
    }

    // MARK: User actions

    /// Starts capture. Recording needs the consent notice first; automatic recording starts anyway and shows a one-time
    /// reminder instead (MTG-AC-05, MTG-AC-11). Transcribe-only never involves consent.
    public func startCapture(_ app: MeetingApp, mode: MeetingCaptureMode, automatic: Bool = false) async {
        guard !captureState.isActive else { return }
        actionError = nil
        if mode.recordsAudio {
            if !consent.isLoaded { await consent.load() }
            if consent.isPending {
                if automatic {
                    consentReminder = app
                    await prompter?.remindConsent(app: app)
                    await consent.acknowledge()
                } else {
                    pendingRecording = PendingRecording(app: app, mode: mode)
                    navigate?()
                    return
                }
            }
        }
        await begin(app, mode: mode)
    }

    public func confirmConsent() async {
        await consent.acknowledge()
        guard let pending = pendingRecording else { return }
        pendingRecording = nil
        await begin(pending.app, mode: pending.mode)
    }

    public func cancelConsent() { pendingRecording = nil }

    public func dismissConsentReminder() { consentReminder = nil }

    public func dismissError() {
        actionError = nil
        if case .failed = captureState { captureState = .idle }
    }

    /// "Dismiss" and "Ignore this meeting": hides the banner and withdraws the notification until the meeting ends.
    public func dismissDetection(_ app: MeetingApp) async {
        detections[app]?.isDismissed = true
        if detections[app] != nil { dismissedByUser.insert(app) }
        await prompter?.withdraw(app: app)
    }

    /// Stops the capture and opens the finalization flow (the runtime enqueues it).
    public func stopCapture() async {
        guard case .capturing = captureState else { return }
        captureState = .stopping
        let id: TranscriptID?
        if let capture {
            id = await capture.stop()
        } else {
            id = await live.stop()
            usesLiveFallback = false
        }
        finishedTranscriptID = id
        apply(captureState: .idle)
        await load()
    }

    public func setBehavior(_ behavior: MeetingBehavior, for app: MeetingApp) async {
        var policy = await loadPolicy(app)
        policy.behavior = behavior
        policies[app] = policy
        await settings.set(policy, for: SettingsKey.meetingPolicy(app.rawValue))
    }

    /// MTG-AC-17: flips between auto-record and ask-first for the app.
    public func toggleAutoRecord(for app: MeetingApp) async {
        await setBehavior(policy(for: app).behavior == .autoTranscribeAndRecord ? .askFirst : .autoTranscribeAndRecord, for: app)
    }

    // MARK: Internals

    private func loadPolicy(_ app: MeetingApp) async -> MeetingPolicy {
        await settings.value(for: SettingsKey.meetingPolicy(app.rawValue), as: MeetingPolicy.self) ?? MeetingPolicy(app: app)
    }

    private func begin(_ app: MeetingApp, mode: MeetingCaptureMode) async {
        detections[app]?.isDismissed = true
        lastApp = app
        await prompter?.withdraw(app: app)
        apply(captureState: .starting)
        if let capture {
            do {
                try await capture.start(app: app, mode: mode)
            } catch {
                actionError = String(describing: error)
                apply(captureState: .failed(actionError ?? "Capture failed"))
            }
            return
        }
        guard !mode.recordsAudio else {
            actionError = "Recording is not available in this build yet. You can still transcribe."
            apply(captureState: .idle)
            return
        }
        guard liveState == .idle else {
            actionError = "Live captions are already running. Stop them first."
            apply(captureState: .idle)
            return
        }
        do {
            usesLiveFallback = true
            try await live.start(LiveSessionConfig(source: .micAndSystem(deviceUID: nil, lanes: true), diarize: true, saveAsTranscript: true))
            apply(captureState: .capturing(app, mode: mode, since: clock()))
        } catch {
            usesLiveFallback = false
            actionError = String(describing: error)
            apply(captureState: .failed(actionError ?? "Capture failed"))
        }
    }
}
