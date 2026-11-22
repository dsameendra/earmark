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

    public init(isAppRunning: Bool = false, micInput: Bool = false, audioOutput: Bool = false, deviceMicInUse: Bool = false) {
        self.isAppRunning = isAppRunning
        self.micInput = micInput
        self.audioOutput = audioOutput
        self.deviceMicInUse = deviceMicInUse
    }

    public static let inactive = AppAudioActivity()
}

/// Supplies audio activity per app and signals when anything may have changed (event driven, no polling).
public protocol MeetingProbe: Sendable {
    func activity(for app: MeetingApp) async -> AppAudioActivity
    /// Emits (coalesced) whenever app launch/quit or audio process state may have changed.
    func changes() -> AsyncStream<Void>
}

public struct MeetingDetectorConfig: Sendable {
    /// Input and output must both stay active this long before `.started` (research §4: 3 s).
    public var startDebounce: TimeInterval
    /// Default time without audio activity before `.ended`, used when `endGrace` yields nothing.
    public var defaultEndGrace: TimeInterval
    /// Per-app grace period (typically `MeetingPolicy.autoStopGraceSeconds`).
    public var endGrace: @Sendable (MeetingApp) async -> TimeInterval
    /// When the app's own process reports output but no input (muted, Zoom released the mic), still require the
    /// default input device to be running somewhere before counting it as a meeting start. Default off: the
    /// per-process flags are the primary signal and the device flag only corroborates.
    public var requireDeviceCorroboration: Bool

    public init(
        startDebounce: TimeInterval = 3, defaultEndGrace: TimeInterval = 15,
        requireDeviceCorroboration: Bool = false,
        endGrace: (@Sendable (MeetingApp) async -> TimeInterval)? = nil
    ) {
        self.startDebounce = startDebounce
        self.defaultEndGrace = defaultEndGrace
        self.requireDeviceCorroboration = requireDeviceCorroboration
        self.endGrace = endGrace ?? { _ in defaultEndGrace }
    }
}

/// Detects Zoom and Teams meetings from per-process audio activity (MTG-AC-01, -02, -20).
///
/// Per app: a meeting *starts* once the app's own audio process has input **and** output running for
/// `startDebounce` seconds; it *ends* once neither has been active for the grace period. While active, either signal
/// keeps the meeting alive, so muting (mic released) or a quiet stretch does not end it and never re-emits `.started`.
/// Timers exist only while a start or end is pending; an idle detector holds no timers (MTG-AC-20).
/// Call ``start()`` once and keep a strong reference to the detector: its probe watcher holds it weakly.
public actor ProbeMeetingDetector: MeetingDetector {
    private enum Phase {
        case idle
        case candidate(since: Date, token: Int, task: Task<Void, Never>)
        case active(since: Date)
        case ending(activeSince: Date, inactiveSince: Date, token: Int, task: Task<Void, Never>)
    }

    private let probe: any MeetingProbe
    private let clock: any MeetingClock
    private let config: MeetingDetectorConfig
    private let apps: [MeetingApp]
    private let broadcaster = Broadcaster<MeetingEvent>()
    private var phases: [MeetingApp: Phase] = [:]
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

    // MARK: State machine

    private func evaluateAll() async {
        for app in apps { await evaluate(app) }
    }

    private func isStrong(_ a: AppAudioActivity) -> Bool {
        guard a.isAppRunning, a.micInput, a.audioOutput else { return false }
        return true
    }

    /// Output-only (muted or listen-only) counts as "start" only with device corroboration when that is required.
    private func isAlive(_ a: AppAudioActivity) -> Bool { a.isAppRunning && (a.micInput || a.audioOutput) }

    private func evaluate(_ app: MeetingApp) async {
        let activity = await probe.activity(for: app)
        let now = clock.now()
        let phase = phases[app] ?? .idle
        switch phase {
        case .idle:
            guard isStrong(activity), !config.requireDeviceCorroboration || activity.deviceMicInUse else { return }
            schedule(app, since: now)
        case .candidate(_, _, let task):
            if !isStrong(activity) {
                task.cancel()
                phases[app] = .idle
            }
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
        let clock = clock
        let debounce = config.startDebounce
        let task = Task { [weak self] in
            do { try await clock.sleep(for: debounce) } catch { return }
            await self?.confirmStart(app, token: token)
        }
        phases[app] = .candidate(since: since, token: token, task: task)
    }

    private func confirmStart(_ app: MeetingApp, token: Int) async {
        guard case .candidate(let since, let current, _) = phases[app], current == token else { return }
        let activity = await probe.activity(for: app)
        // Re-check after the (suspending) probe call: a newer evaluation may have replaced this candidate.
        guard case .candidate(_, let again, _) = phases[app], again == token else { return }
        guard isStrong(activity) else {
            phases[app] = .idle
            return
        }
        phases[app] = .active(since: since)
        log.info("meeting started: \(app.rawValue, privacy: .public)")
        broadcaster.send(.started(app, at: since))
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
        case .candidate(_, _, let task), .ending(_, _, _, let task): task.cancel()
        default: break
        }
    }
}
