import AppCore
import Foundation
import os

/// Audio activity of one meeting app at an instant (the injectable detection seam).
public struct AppAudioActivity: Sendable, Equatable {
    /// The app (or one of its helpers) is running.
    public var isAppRunning: Bool
    /// One of the app's own audio processes has an input (microphone) stream running.
    public var micInput: Bool
    /// One of the app's own audio processes has an output stream running.
    public var audioOutput: Bool
    /// `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default input device. Corroborating only.
    public var deviceMicInUse: Bool
    /// A call-only helper process is running (Zoom `CptHost`, spawned only while a meeting is in progress). Corroborating.
    public var helperPresent: Bool

    public init(
        isAppRunning: Bool = false, micInput: Bool = false, audioOutput: Bool = false, deviceMicInUse: Bool = false,
        helperPresent: Bool = false
    ) {
        self.isAppRunning = isAppRunning
        self.micInput = micInput
        self.audioOutput = audioOutput
        self.deviceMicInUse = deviceMicInUse
        self.helperPresent = helperPresent
    }

    public static let inactive = AppAudioActivity()
}

/// Supplies audio activity per app and signals when anything may have changed (event driven, no polling).
public protocol MeetingProbe: Sendable {
    func activity(for app: MeetingApp) async -> AppAudioActivity
    /// Emits (coalesced) whenever app launch/quit or audio process state may have changed.
    func changes() -> AsyncStream<Void>
    /// Audio processes that currently have input or output running, for the diagnostics list. Defaults to none.
    func activeAudioProcesses() async -> [AudioProcessActivity]
    func browserReadings() async -> [BrowserReading]
    var canReadTitles: Bool { get }
}

extension MeetingProbe {
    public func activeAudioProcesses() async -> [AudioProcessActivity] { [] }
    /// Browser state for Meet and browser calls. Defaults to none (tests that only model native apps).
    public func browserReadings() async -> [BrowserReading] { [] }
    /// Whether window titles can be read (Accessibility granted). Defaults to false.
    public var canReadTitles: Bool { false }
}

/// One Core Audio process with a running stream (bundle ID and flags only; never audio content).
public struct AudioProcessActivity: Sendable, Equatable, Identifiable {
    public var bundleID: String
    public var input: Bool
    public var output: Bool
    public var id: String { bundleID }
    public init(bundleID: String, input: Bool, output: Bool) {
        self.bundleID = bundleID
        self.input = input
        self.output = output
    }
}

/// What the detector currently believes about one app (Settings > Meetings > Detection diagnostics).
public struct AppDetectionDiagnostics: Sendable, Equatable, Identifiable {
    public var app: MeetingApp
    public var activity: AppAudioActivity
    /// `idle`, `candidate`, `active` or `ending`.
    public var phase: String
    public var lastSignalAt: Date?
    public var lastStartedAt: Date?
    public var id: MeetingApp { app }
}

public struct MeetingDetectorConfig: Sendable {
    /// Fast path: input and output both active this long before `.started` (research §4: 3 s).
    public var startDebounce: TimeInterval
    /// Default time without audio activity before `.ended`, used when `endGrace` yields nothing.
    public var defaultEndGrace: TimeInterval
    /// Per-app grace period (typically `MeetingPolicy.autoStopGraceSeconds`).
    public var endGrace: @Sendable (MeetingApp) async -> TimeInterval
    /// When the app's own process reports output but no input (muted, Zoom released the mic), still require the
    /// default input device to be running somewhere before counting it as a meeting start. Default off: the
    /// per-process flags are the primary signal and the device flag only corroborates.
    public var requireDeviceCorroboration: Bool
    /// Muted or listen-only joins: output running plus another corroborating signal (mic, device mic, call helper).
    public var corroboratedDebounce: TimeInterval
    /// Output running with nothing else (listen-only webinar): start only after this long.
    public var outputOnlyDebounce: TimeInterval
    /// A pending start survives signal gaps shorter than this (one weak sample must not reset it).
    public var candidateGrace: TimeInterval
    /// Apps that never start on playback alone. A Discord voice channel is long-lived and bots play music into it, so only a
    /// microphone stream (or a corroborated one) opens a Discord call; the user can still pick it from Detect meetings.
    public var outputOnlyDisabled: Set<MeetingApp>

    public init(
        startDebounce: TimeInterval = 3, defaultEndGrace: TimeInterval = 15,
        requireDeviceCorroboration: Bool = false,
        corroboratedDebounce: TimeInterval = 5, outputOnlyDebounce: TimeInterval = 15, candidateGrace: TimeInterval = 3,
        outputOnlyDisabled: Set<MeetingApp> = [.discord],
        endGrace: (@Sendable (MeetingApp) async -> TimeInterval)? = nil
    ) {
        self.corroboratedDebounce = corroboratedDebounce
        self.outputOnlyDebounce = outputOnlyDebounce
        self.candidateGrace = candidateGrace
        self.outputOnlyDisabled = outputOnlyDisabled
        self.startDebounce = startDebounce
        self.defaultEndGrace = defaultEndGrace
        self.requireDeviceCorroboration = requireDeviceCorroboration
        self.endGrace = endGrace ?? { _ in defaultEndGrace }
    }
}

/// Detects Zoom and Teams meetings from per-process audio activity (MTG-AC-01, -02, -20).
///
/// Per app: a meeting *starts* when the app's audio shows a call for long enough. Three paths, fastest first:
/// input and output for `startDebounce` (3 s); output plus a corroborating signal (mic, default-device mic, call
/// helper process) for `corroboratedDebounce` (5 s), which covers muted joins where Zoom releases the input stream;
/// output alone for `outputOnlyDebounce` (15 s), which covers listen-only joins. A pending start is not reset by a
/// short gap (`candidateGrace`). It *ends* once neither input nor output has been active for the grace period.
/// Timers exist only while a start or end is pending; an idle detector holds no timers (MTG-AC-20).
/// Call ``start()`` once and keep a strong reference to the detector: its probe watcher holds it weakly.
public actor ProbeMeetingDetector: MeetingDetector {
    private struct Candidate {
        var since: Date
        var token: Int
        var task: Task<Void, Never>
        var missingSince: Date?
    }

    private enum Phase {
        case idle
        case candidate(Candidate)
        case active(since: Date)
        case ending(activeSince: Date, inactiveSince: Date, token: Int, task: Task<Void, Never>)

        var name: String {
            switch self {
            case .idle: "idle"
            case .candidate: "candidate"
            case .active: "active"
            case .ending: "ending"
            }
        }
    }

    private let probe: any MeetingProbe
    private let clock: any MeetingClock
    private let config: MeetingDetectorConfig
    private let apps: [MeetingApp]
    private let broadcaster = Broadcaster<MeetingEvent>()
    private let scanBroadcaster = Broadcaster<MeetingScan>()
    private var lastScan: MeetingScan?
    private var phases: [MeetingApp: Phase] = [:]
    private var lastActivity: [MeetingApp: AppAudioActivity] = [:]
    private var lastSignalAt: [MeetingApp: Date] = [:]
    private var lastStartedAt: [MeetingApp: Date] = [:]
    private var watcher: Task<Void, Never>?
    private var nextToken = 0
    private let log = AppLog.logger("meetings.detector")

    public init(
        probe: any MeetingProbe, clock: any MeetingClock = SystemMeetingClock(),
        config: MeetingDetectorConfig = MeetingDetectorConfig(), apps: [MeetingApp] = MeetingApp.allCases
    ) {
        self.probe = probe
        self.clock = clock
        self.config = config
        self.apps = apps
    }

    public nonisolated func events() -> AsyncStream<MeetingEvent> { broadcaster.stream() }

    /// Begins observing the probe. Idempotent.
    public func start() async {
        guard watcher == nil else { return }
        let changes = probe.changes()
        watcher = Task { [weak self] in
            for await _ in changes {
                guard let self else { return }
                await self.evaluateAll()
            }
        }
        await evaluateAll()
    }

    public func stop() {
        watcher?.cancel()
        watcher = nil
        for app in apps { cancelTimer(for: app) }
        phases = [:]
    }

    /// Apps with a meeting currently considered active.
    public func activeApps() -> Set<MeetingApp> {
        Set(
            phases.compactMap { app, phase -> MeetingApp? in
                switch phase {
                case .active, .ending: app
                default: nil
                }
            })
    }

    /// Fresh per-app readings and detector phase for the diagnostics list. Contains no audio or transcript content.
    public func diagnostics() async -> [AppDetectionDiagnostics] {
        var rows: [AppDetectionDiagnostics] = []
        for app in apps {
            let activity = await probe.activity(for: app)
            lastActivity[app] = activity
            rows.append(
                AppDetectionDiagnostics(
                    app: app, activity: activity, phase: (phases[app] ?? .idle).name, lastSignalAt: lastSignalAt[app],
                    lastStartedAt: lastStartedAt[app]))
        }
        return rows
    }

    public func audioProcesses() async -> [AudioProcessActivity] { await probe.activeAudioProcesses() }

    // MARK: Scan (Detect meetings)

    /// Calls Earmark can see right now, without any debounce: the user asked, so a clear signal is enough. Native apps use the
    /// same rule as automatic detection minus the waiting; browsers use their microphone state plus a Meet title.
    public func scan() async -> MeetingScan {
        var calls: [DetectedCall] = []
        var notes: [String] = []
        for app in apps where app != .meet {
            let activity = await probe.activity(for: app)
            lastActivity[app] = activity
            if qualifies(activity, elapsed: .infinity, app: app) || (app == .discord && activity.isAppRunning && activity.micInput) {
                calls.append(
                    DetectedCall(id: app.rawValue, app: app, label: Self.name(of: app), captureBundleID: nil, detail: "Call audio is running"))
            } else if activity.isAppRunning {
                notes.append("\(Self.name(of: app)): running, no call audio")
            } else {
                notes.append("\(Self.name(of: app)): not running")
            }
        }
        let readings = await probe.browserReadings()
        var needsAccessibility = false
        for reading in readings {
            let name = reading.browser.name
            guard reading.micInput else {
                notes.append("\(name): open, microphone not in use")
                continue
            }
            if reading.meetWindowOpen {
                calls.append(
                    DetectedCall(
                        id: "meet.\(reading.browser.captureBundleID)", app: .meet, label: "Google Meet in \(name)",
                        captureBundleID: reading.browser.captureBundleID, detail: "Microphone in use and a Meet window is open"))
            } else {
                if !probe.canReadTitles { needsAccessibility = true }
                let detail = probe.canReadTitles ? "Microphone in use; no Meet window found" : "Microphone in use"
                calls.append(
                    DetectedCall(
                        id: "browser.\(reading.browser.captureBundleID)", app: .browser, label: "Browser call in \(name)",
                        captureBundleID: reading.browser.captureBundleID, detail: detail))
            }
        }
        if readings.isEmpty { notes.append("No supported browser is open") }
        return MeetingScan(calls: calls, notes: notes, needsAccessibilityForMeet: needsAccessibility)
    }

    /// Emits the scan result whenever it changes, driven by the probe's change signal (no polling). Call ``scan()`` for the
    /// current value; this stream only reports later changes.
    public nonisolated func scans() -> AsyncStream<MeetingScan> { scanBroadcaster.stream() }

    private func publishScan() async {
        let next = await scan()
        guard next != lastScan else { return }
        lastScan = next
        scanBroadcaster.send(next)
    }

    static func name(of app: MeetingApp) -> String {
        switch app {
        case .zoom: "Zoom"
        case .teams: "Microsoft Teams"
        case .meet: "Google Meet"
        case .discord: "Discord"
        case .browser: "Browser call"
        }
    }

    // MARK: Signals

    /// Enough to open a pending start: the app is running and shows output, or a mic stream together with a call helper.
    private func isBeginSignal(_ a: AppAudioActivity) -> Bool {
        a.isAppRunning && (a.audioOutput || (a.micInput && a.helperPresent))
    }

    /// Whether the readings justify `.started` after `elapsed` seconds of continuous signal.
    private func qualifies(_ a: AppAudioActivity, elapsed: TimeInterval, app: MeetingApp) -> Bool {
        guard a.isAppRunning else { return false }
        let slack = 0.001
        if a.micInput && a.audioOutput && elapsed + slack >= config.startDebounce { return true }
        let corroborated = (a.audioOutput && (a.micInput || a.deviceMicInUse)) || (a.helperPresent && (a.audioOutput || a.micInput))
        if corroborated && elapsed + slack >= config.corroboratedDebounce { return true }
        if config.outputOnlyDisabled.contains(app) { return false }
        return a.audioOutput && elapsed + slack >= config.outputOnlyDebounce
    }

    /// Either signal keeps an active meeting alive, so muting or a quiet stretch does not end it.
    private func isAlive(_ a: AppAudioActivity) -> Bool { a.isAppRunning && (a.micInput || a.audioOutput) }

    // MARK: State machine

    private func evaluateAll() async {
        for app in apps { await evaluate(app) }
        await publishScan()
    }

    private func evaluate(_ app: MeetingApp) async {
        let activity = await probe.activity(for: app)
        let now = clock.now()
        if lastActivity[app] != activity {
            log.debug(
                "\(app.rawValue, privacy: .public) running=\(activity.isAppRunning) mic=\(activity.micInput) out=\(activity.audioOutput) deviceMic=\(activity.deviceMicInUse) helper=\(activity.helperPresent)"
            )
        }
        lastActivity[app] = activity
        if isAlive(activity) { lastSignalAt[app] = now }
        let phase = phases[app] ?? .idle
        switch phase {
        case .idle:
            guard isBeginSignal(activity), !config.requireDeviceCorroboration || activity.deviceMicInUse else { return }
            schedule(app, since: now)
        case .candidate(var candidate):
            if isBeginSignal(activity) {
                candidate.missingSince = nil
            } else {
                candidate.missingSince = candidate.missingSince ?? now
                if now.timeIntervalSince(candidate.missingSince ?? now) >= config.candidateGrace {
                    candidate.task.cancel()
                    phases[app] = .idle
                    return
                }
            }
            phases[app] = .candidate(candidate)
        case .active(let since):
            if !isAlive(activity) { scheduleEnd(app, activeSince: since, inactiveSince: now) }
        case .ending(let activeSince, _, _, let task):
            if isAlive(activity) {
                task.cancel()
                phases[app] = .active(since: activeSince)
            }
        }
    }

    private func schedule(_ app: MeetingApp, since: Date) {
        nextToken += 1
        let token = nextToken
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runCandidate(app, token: token)
        }
        phases[app] = .candidate(Candidate(since: since, token: token, task: task, missingSince: nil))
    }

    /// Sleeps to the next checkpoint (3 s, 5 s, 15 s, or the end of a signal gap) and re-reads the probe there.
    private func runCandidate(_ app: MeetingApp, token: Int) async {
        while !Task.isCancelled {
            guard let wait = nextWait(app, token: token) else { return }
            do { try await clock.sleep(for: wait) } catch { return }
            guard await checkpoint(app, token: token) else { return }
        }
    }

    private func nextWait(_ app: MeetingApp, token: Int) -> TimeInterval? {
        guard case .candidate(let candidate) = phases[app], candidate.token == token else { return nil }
        let now = clock.now()
        let elapsed = now.timeIntervalSince(candidate.since)
        let checkpoints = [config.startDebounce, config.corroboratedDebounce, config.outputOnlyDebounce]
        var waits = checkpoints.filter { $0 > elapsed + 0.001 }.map { $0 - elapsed }
        if let missing = candidate.missingSince {
            waits.append(max(0, config.candidateGrace - now.timeIntervalSince(missing)))
        }
        return waits.min()
    }

    /// Returns whether the candidate is still pending.
    private func checkpoint(_ app: MeetingApp, token: Int) async -> Bool {
        guard case .candidate(let before) = phases[app], before.token == token else { return false }
        let activity = await probe.activity(for: app)
        // Re-check after the (suspending) probe call: a newer evaluation may have replaced this candidate.
        guard case .candidate(var candidate) = phases[app], candidate.token == token else { return false }
        let now = clock.now()
        lastActivity[app] = activity
        if isAlive(activity) { lastSignalAt[app] = now }
        if isBeginSignal(activity) {
            candidate.missingSince = nil
        } else {
            candidate.missingSince = candidate.missingSince ?? now
            if now.timeIntervalSince(candidate.missingSince ?? now) >= config.candidateGrace {
                phases[app] = .idle
                return false
            }
            phases[app] = .candidate(candidate)
            return true
        }
        if qualifies(activity, elapsed: now.timeIntervalSince(candidate.since), app: app) {
            phases[app] = .active(since: candidate.since)
            lastStartedAt[app] = candidate.since
            log.info("meeting started: \(app.rawValue, privacy: .public)")
            broadcaster.send(.started(app, at: candidate.since))
            return false
        }
        phases[app] = .candidate(candidate)
        // Past the last checkpoint with a begin signal that never qualified: give up until the next change.
        if now.timeIntervalSince(candidate.since) + 0.001 >= config.outputOnlyDebounce {
            phases[app] = .idle
            return false
        }
        return true
    }

    private func scheduleEnd(_ app: MeetingApp, activeSince: Date, inactiveSince: Date) {
        nextToken += 1
        let token = nextToken
        let clock = clock
        let task = Task { [weak self] in
            guard let self else { return }
            let grace = await self.grace(for: app)
            do { try await clock.sleep(for: grace) } catch { return }
            await self.confirmEnd(app, token: token)
        }
        phases[app] = .ending(activeSince: activeSince, inactiveSince: inactiveSince, token: token, task: task)
    }

    private func grace(for app: MeetingApp) async -> TimeInterval { max(0, await config.endGrace(app)) }

    private func confirmEnd(_ app: MeetingApp, token: Int) async {
        guard case .ending(_, let inactiveSince, let current, _) = phases[app], current == token else { return }
        let activity = await probe.activity(for: app)
        guard case .ending(let activeSince, _, let again, _) = phases[app], again == token else { return }
        if isAlive(activity) {
            phases[app] = .active(since: activeSince)
            return
        }
        phases[app] = .idle
        log.info("meeting ended: \(app.rawValue, privacy: .public)")
        broadcaster.send(.ended(app, at: inactiveSince))
    }

    private func cancelTimer(for app: MeetingApp) {
        switch phases[app] {
        case .candidate(let candidate): candidate.task.cancel()
        case .ending(_, _, _, let task): task.cancel()
        default: break
        }
    }
}
