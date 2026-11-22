import AppCore
import Foundation
import Synchronization

/// Everything the controller talks to. All are AppCore protocols or small Dictation abstractions, so the app wires
/// real services and tests wire fakes.
public struct DictationDependencies: Sendable {
    public var hotkeys: any HotkeyServicing
    /// Builds the audio source for a session; the argument is the per-feature device override (Core Audio UID).
    public var makeAudioSource: @Sendable (String?) -> any AudioSource
    public var engineProvider: DictationEngineProvider
    public var pipeline: DictationPipeline
    public var inserter: any TextInserting
    public var history: DictationHistory
    public var settings: any SettingsStore
    public var permissions: any PermissionsServicing
    public var hud: any DictationHUDPresenting
    public var notifier: any DictationNotifying
    public var onboarding: any DictationOnboardingPresenting

    public init(
        hotkeys: any HotkeyServicing, makeAudioSource: @escaping @Sendable (String?) -> any AudioSource,
        engineProvider: @escaping DictationEngineProvider, pipeline: DictationPipeline, inserter: any TextInserting,
        history: DictationHistory, settings: any SettingsStore, permissions: any PermissionsServicing,
        hud: any DictationHUDPresenting, notifier: any DictationNotifying, onboarding: any DictationOnboardingPresenting
    ) {
        self.hotkeys = hotkeys
        self.makeAudioSource = makeAudioSource
        self.engineProvider = engineProvider
        self.pipeline = pipeline
        self.inserter = inserter
        self.history = history
        self.settings = settings
        self.permissions = permissions
        self.hud = hud
        self.notifier = notifier
        self.onboarding = onboarding
    }
}

/// Fan-out of ``DictationState`` to any number of observers.
final class DictationStateHub: Sendable {
    private struct Box {
        var current = DictationState.idle
        var observers: [UUID: AsyncStream<DictationState>.Continuation] = [:]
    }
    private let box = Mutex(Box())

    var current: DictationState { box.withLock { $0.current } }

    func publish(_ state: DictationState) {
        let conts = box.withLock { b -> [AsyncStream<DictationState>.Continuation] in
            b.current = state
            return Array(b.observers.values)
        }
        for c in conts { c.yield(state) }
    }

    /// Partial text updates only apply while listening, so a late partial never overwrites a terminal state.
    func publishPartial(_ text: String) {
        let conts = box.withLock { b -> [AsyncStream<DictationState>.Continuation] in
            guard case .listening = b.current else { return [] }
            b.current = .listening(partial: text)
            return Array(b.observers.values)
        }
        for c in conts { c.yield(.listening(partial: text)) }
    }

    private func remove(_ id: UUID) { box.withLock { _ = $0.observers.removeValue(forKey: id) } }

    func stream() -> AsyncStream<DictationState> {
        let id = UUID()
        let (stream, cont) = AsyncStream<DictationState>.makeStream(bufferingPolicy: .bufferingNewest(8))
        box.withLock { b in
            b.observers[id] = cont
            cont.yield(b.current)
        }
        cont.onTermination = { [weak self] _ in self?.remove(id) }
        return stream
    }
}

struct CaptureOutcome: Sendable {
    var segments: [Segment]
    var error: AppError?
}

/// The dictation session controller: hotkey → AudioSource → TranscriptionEngine(.dictation) → post-processing →
/// insertion → history. Never blocks the app: missing permissions surface as ``DictationState`` values.
public actor DictationController {
    private enum Phase { case idle, listening, finalizing }
    private struct Session {
        let id: UUID
        let source: any AudioSource
        let task: Task<CaptureOutcome, Never>
    }

    private let deps: DictationDependencies
    private let clock: @Sendable () -> TimeInterval
    private let finalizeTimeout: Duration
    private let hub = DictationStateHub()

    private var settings = DictationSettings()
    private var trigger = DictationTrigger(mode: .pushToTalk)
    private var phase = Phase.idle
    private var session: Session?
    private var registeredCombo: KeyCombo?
    private var hotkeyTask: Task<Void, Never>?
    private var permissionTask: Task<Void, Never>?

    /// - Parameters:
    ///   - clock: monotonic seconds, injected for tests.
    ///   - finalizeTimeout: how long to wait for the engine to finish after release before giving up.
    public init(
        dependencies: DictationDependencies,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        finalizeTimeout: Duration = .seconds(5)
    ) {
        self.deps = dependencies
        self.clock = clock
        self.finalizeTimeout = finalizeTimeout
    }

    /// Current and future states (the current state is delivered first).
    public nonisolated func states() -> AsyncStream<DictationState> { hub.stream() }

    // MARK: Lifecycle

    /// Loads settings, registers the hotkey and starts watching permission changes. Safe to call when permissions
    /// are missing: state becomes ``DictationState/hotkeyUnavailable`` and the app carries on.
    public func start() async {
        settings = await DictationSettings.load(from: deps.settings)
        trigger.setMode(settings.mode)
        observePermissions()
        await registerHotkey()
        warmEngine()
    }

    public func stop() async {
        hotkeyTask?.cancel()
        permissionTask?.cancel()
        hotkeyTask = nil
        permissionTask = nil
        await deps.hotkeys.unregister(.dictation)
        registeredCombo = nil
        await cancel()
    }

    /// Re-reads settings after the user changed them (combo, mode, ...).
    public func reloadSettings() async {
        let old = settings
        settings = await DictationSettings.load(from: deps.settings)
        if phase == .idle { trigger.setMode(settings.mode) }
        if old.combo != settings.combo || registeredCombo == nil { await registerHotkey() }
        warmEngine()
    }

    /// Retries hotkey registration (e.g. after the user grants Input Monitoring).
    public func retryHotkeyRegistration() async { await registerHotkey() }

    /// Feeds a hotkey event directly (menu bar "Start dictation" button, tests).
    public func handle(_ event: HotkeyEvent) async {
        switch trigger.handle(event, at: clock()) {
        case .start: await beginSession()
        case .finish: await finishSession()
        case .cancel: await cancel()
        case nil: break
        }
    }

    /// Cancels any running session without inserting (Escape, app quit).
    public func cancel() async {
        trigger.sessionEnded()
        guard phase == .listening, let s = session else { return }
        session = nil
        phase = .idle
        s.task.cancel()
        await s.source.stop()
        await deps.hud.dismiss()
        hub.publish(.idle)
    }

    // MARK: Hotkey and permissions

    private func registerHotkey() async {
        hotkeyTask?.cancel()
        do {
            let stream = try await deps.hotkeys.register(.dictation, combo: settings.combo)
            registeredCombo = settings.combo
            hotkeyTask = Task { [weak self] in
                for await event in stream { await self?.handle(event) }
            }
            if hub.current == .hotkeyUnavailable { hub.publish(.idle) }
        } catch HotkeyError.conflict(let other) {
            registeredCombo = nil
            hub.publish(.failed("This shortcut is already used by another Earmark action (\(other.rawValue))."))
        } catch {
            registeredCombo = nil
            hub.publish(.hotkeyUnavailable)
        }
    }

    private func observePermissions() {
        permissionTask?.cancel()
        let changes = deps.permissions.changes()
        permissionTask = Task { [weak self] in
            for await (kind, status) in changes { await self?.permissionChanged(kind, status) }
        }
    }

    private func permissionChanged(_ kind: PermissionKind, _ status: PermissionStatus) async {
        guard kind == .accessibility, status == .granted else { return }
        await deps.onboarding.dismissAccessibilityOnboarding()
        if hub.current == .needsAccessibility { hub.publish(.idle) }
        if registeredCombo == nil { await registerHotkey() }
    }

    private func ensureAccessibility() async -> Bool {
        var status = await deps.permissions.status(.accessibility)
        if status != .granted { status = await deps.permissions.request(.accessibility) }
        if status == .granted { return true }
        hub.publish(.needsAccessibility)
        await deps.onboarding.presentAccessibilityOnboarding(settingsURL: deps.permissions.settingsURL(for: .accessibility))
        return false
    }

    private func warmEngine() {
        let provider = deps.engineProvider
        let s = settings
        Task {
            if let r = try? await provider(s), let m = r.model { try? await r.engine.prepare(model: m) }
        }
    }

    // MARK: Session

    private func beginSession() async {
        guard phase == .idle else {
            trigger.sessionEnded()
            return
        }
        phase = .listening  // claim the slot before any suspension point
        guard await ensureAccessibility() else {
            phase = .idle
            trigger.sessionEnded()
            return
        }
        let info = DictationHUDInfo(
            hint: DictationHint.text(mode: settings.mode, combo: settings.combo), position: settings.hudPosition)
        let id = UUID()
        let source = deps.makeAudioSource(settings.deviceUID)
        let task = Self.makeCaptureTask(
            id: id, source: source, settings: settings, deps: deps, hub: hub,
            onFailure: { [weak self] id, error in await self?.captureFailed(id, error) })
        session = Session(id: id, source: source, task: task)
        hub.publish(.listening(partial: ""))
        await deps.hud.show(info)
    }

    private func finishSession() async {
        guard phase == .listening, let s = session else { return }
        phase = .finalizing
        hub.publish(.finalizing)
        await deps.hud.showProcessing()
        await s.source.stop()
        let outcome = await awaitOutcome(s.task)
        session = nil
        if let error = outcome.error {
            await fail(error)
            return
        }
        let snapshot = settings
        guard let final = await deps.pipeline.finalize(segments: outcome.segments, settings: snapshot) else {
            await deps.hud.dismiss()  // empty after processing: never insert (DICT-AC-07)
            end()
            return
        }
        await deps.hud.dismiss()
        do {
            try await deps.inserter.insert(final.text, method: snapshot.insertionMethod)
        } catch {
            await handleInsertionFailure(error)
            return
        }
        await deps.history.record(final.text, language: final.language, settings: snapshot)
        if final.translationFailed {
            await deps.notifier.notify(
                DictationNotice(kind: .warning, message: "Translation failed, so the original text was inserted."))
        }
        end()
    }

    private func end() {
        phase = .idle
        session = nil
        trigger.sessionEnded()
        hub.publish(.idle)
    }

    private func fail(_ error: Error) async {
        let message = Self.message(for: error)
        await deps.hud.dismissWithError(message)  // never insert partial text (DICT-AC-14)
        phase = .idle
        session = nil
        trigger.sessionEnded()
        hub.publish(.failed(message))
    }

    private func handleInsertionFailure(_ error: Error) async {
        if let app = error as? AppError, app == .permissionDenied(.accessibility) {
            hub.publish(.needsAccessibility)
            await deps.onboarding.presentAccessibilityOnboarding(settingsURL: deps.permissions.settingsURL(for: .accessibility))
            phase = .idle
            trigger.sessionEnded()
            return
        }
        let message = Self.message(for: error)
        await deps.notifier.notify(DictationNotice(kind: .error, message: message))
        phase = .idle
        trigger.sessionEnded()
        hub.publish(.failed(message))
    }

    /// The capture task failed while the user was still holding the key: dismiss now (DICT-AC-14).
    private func captureFailed(_ id: UUID, _ error: AppError) async {
        guard phase == .listening, session?.id == id, let s = session else { return }
        session = nil
        await s.source.stop()
        await fail(error)
    }

    private func awaitOutcome(_ task: Task<CaptureOutcome, Never>) async -> CaptureOutcome {
        let timeout = finalizeTimeout
        let result: CaptureOutcome? = await withTaskGroup(of: CaptureOutcome?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        if let result { return result }
        task.cancel()
        return CaptureOutcome(segments: [], error: .engineFailure("dictation", reason: "timed out finishing transcription"))
    }

    static func message(for error: Error) -> String {
        if let e = error as? DictationError { return e.localizedDescription }
        if let e = error as? AppError {
            switch e {
            case .permissionDenied(let k): return "Earmark needs \(k.rawValue) permission for dictation."
            case .deviceUnavailable: return "The microphone is unavailable."
            case .modelNotInstalled: return "The dictation model isn't installed yet."
            case .engineFailure(_, let reason): return "Dictation failed: \(reason)"
            case .unsupportedLanguage(let l): return "Dictation doesn't support \(l.rawValue) yet."
            default: return "Dictation failed."
            }
        }
        return "Dictation failed."
    }

    // MARK: Capture (runs off the actor; only Sendable pieces captured)

    private static func makeCaptureTask(
        id: UUID, source: any AudioSource, settings: DictationSettings, deps: DictationDependencies,
        hub: DictationStateHub, onFailure: @escaping @Sendable (UUID, AppError) async -> Void
    ) -> Task<CaptureOutcome, Never> {
        let hud = deps.hud
        let notifier = deps.notifier
        let provider = deps.engineProvider
        return Task {
            var segments: [Segment] = []
            var side: [Task<Void, Never>] = []
            defer { for t in side { t.cancel() } }
            do {
                let resolved = try await provider(settings)
                if resolved.isExperimental { await hud.showExperimentalBadge() }
                if let model = resolved.model { try await resolved.engine.prepare(model: model) }
                let chunks = try await source.start()
                side.append(
                    Task {
                        var last = ContinuousClock.now
                        for await level in source.levels {
                            let now = ContinuousClock.now
                            guard now - last >= .milliseconds(33) else { continue }  // HUD updates <= 30 Hz
                            last = now
                            await hud.update(level: level)
                        }
                    })
                side.append(
                    Task {
                        for await health in source.health {
                            switch health {
                            case .deviceChanged:
                                await notifier.notify(
                                    DictationNotice(kind: .info, message: "The dictation microphone was unplugged. Using the default input."))
                            case .silent:
                                await notifier.notify(
                                    DictationNotice(kind: .warning, message: "No audio is reaching Earmark. Check microphone access."))
                            default: break
                            }
                        }
                    })
                let options = TranscriptionOptions(
                    languageMode: settings.languageMode, useCase: .dictation, modelID: settings.modelID,
                    vocabulary: settings.vocabulary, wordTimestamps: false)
                for try await event in resolved.engine.stream(audio: chunks, options: options) {
                    switch event {
                    case .partial(let p):
                        hub.publishPartial(p.text)
                        await hud.update(partial: p.text)
                    case .final(let seg):
                        segments.append(seg)
                        let text = segments.map(\.text).joined(separator: " ")
                        hub.publishPartial(text)
                        await hud.update(partial: text)
                    default: break
                    }
                }
                return CaptureOutcome(segments: segments, error: nil)
            } catch {
                let app: AppError =
                    (error as? AppError) ?? (error is CancellationError ? .cancelled : .other(String(describing: error)))
                if app != .cancelled { await onFailure(id, app) }
                return CaptureOutcome(segments: [], error: app)
            }
        }
    }
}
