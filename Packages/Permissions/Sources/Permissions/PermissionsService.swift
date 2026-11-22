import AppCore
import Foundation
import os

/// Real `PermissionsServicing`: status, just-in-time requests, System Settings deep links and a change stream.
///
/// Denied never blocks the app: nothing here throws, and a denied or restricted result is simply reported.
/// All OS access goes through the injected `PermissionProbing`.
public final class PermissionsService: PermissionsServicing {
    private typealias Continuation = AsyncStream<(PermissionKind, PermissionStatus)>.Continuation
    private struct State {
        var subscribers: [UUID: Continuation] = [:]
        var lastKnown: [PermissionKind: PermissionStatus] = [:]
        var silentlyDenied: Set<PermissionKind> = []
        var polling: Task<Void, Never>?
    }

    /// Permissions whose OS status separates "never asked" from "denied"; the requested-flag memory is ignored for them.
    static let osDistinguishesDenial: Set<PermissionKind> = [.microphone, .notifications]

    private let probe: any PermissionProbing
    private let memory: any PermissionMemory
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(probe: any PermissionProbing = SystemPermissionProbe(), memory: any PermissionMemory = UserDefaultsPermissionMemory()) {
        self.probe = probe
        self.memory = memory
    }

    deinit { state.withLock { $0.polling?.cancel() } }

    // MARK: PermissionsServicing

    public func status(_ kind: PermissionKind) async -> PermissionStatus {
        let resolved = await resolve(kind)
        publish(kind, resolved)
        return resolved
    }

    /// Prompts only when the OS has not been asked yet; a denied permission is returned as is (the user must use System Settings).
    public func request(_ kind: PermissionKind) async -> PermissionStatus {
        let current = await resolve(kind)
        guard current == .notDetermined else {
            publish(kind, current)
            return current
        }
        memory.markRequested(kind)
        let outcome = await probe.performRequest(kind)
        if kind == .systemAudioRecording {
            switch outcome {
            case .granted: memory.setLastOutcome(kind, .granted)
            case .denied: memory.setLastOutcome(kind, .denied)
            default: break
            }
        }
        state.withLock { _ = $0.silentlyDenied.remove(kind) }
        let resolved = await resolve(kind)
        publish(kind, resolved)
        return resolved
    }

    public func settingsURL(for kind: PermissionKind) -> URL { Self.settingsURL(for: kind) }

    public func changes() -> AsyncStream<(PermissionKind, PermissionStatus)> {
        let id = UUID()
        return AsyncStream { continuation in
            state.withLock { $0.subscribers[id] = continuation }
            continuation.onTermination = { [weak self] _ in self?.state.withLock { _ = $0.subscribers.removeValue(forKey: id) } }
        }
    }

    // MARK: Refresh, polling and silent denial

    /// Re-reads one permission from the OS (the "Re-check" action) and publishes a change.
    @discardableResult
    public func recheck(_ kind: PermissionKind) async -> PermissionStatus { await status(kind) }

    /// Re-reads every permission and emits a change for each one that differs from the last read.
    /// Call when the app becomes active again (the user may have toggled a switch in System Settings).
    public func refresh() async {
        for kind in PermissionKind.allCases { _ = await status(kind) }
    }

    /// Polls `refresh()` until `stopPolling()`; useful while a System Settings round trip is pending.
    public func startPolling(every interval: Duration = .seconds(2)) {
        state.withLock { state in
            state.polling?.cancel()
            state.polling = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard !Task.isCancelled, let self else { return }
                    await self.refresh()
                }
            }
        }
    }

    public func stopPolling() {
        state.withLock {
            $0.polling?.cancel()
            $0.polling = nil
        }
    }

    /// Silent-denial hook. A process tap can be created while the permission is denied and then deliver only silence;
    /// capture code calls this when a granted-looking source produces nothing, and the status flips to `.denied`
    /// until `reportAudioActivity(_:)` or a fresh `request(_:)` clears it.
    public func reportSilentDenial(_ kind: PermissionKind = .systemAudioRecording) async {
        state.withLock { _ = $0.silentlyDenied.insert(kind) }
        publish(kind, await resolve(kind))
    }

    /// Clears a previously reported silent denial after real audio was observed.
    public func reportAudioActivity(_ kind: PermissionKind = .systemAudioRecording) async {
        state.withLock { _ = $0.silentlyDenied.remove(kind) }
        if kind == .systemAudioRecording { memory.setLastOutcome(kind, .granted) }
        publish(kind, await resolve(kind))
    }

    // MARK: Input Monitoring (outside the frozen `PermissionKind`)

    public func inputMonitoringStatus() -> PermissionStatus { probe.inputMonitoringGranted() ? .granted : .notDetermined }
    public func requestInputMonitoring() -> Bool { probe.requestInputMonitoring() }
    public static let inputMonitoringSettingsURL = securityURL("Privacy_ListenEvent")

    // MARK: Internals

    private func resolve(_ kind: PermissionKind) async -> PermissionStatus {
        if state.withLock({ $0.silentlyDenied.contains(kind) }) { return .denied }
        switch await probe.rawState(kind) {
        case .granted: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined:
            // Microphone and notifications report an exact OS state, so "not determined" really means "never asked"
            // (for example after a TCC reset or an identity change). Only panes that cannot tell use the memory heuristic.
            if Self.osDistinguishesDenial.contains(kind) { return .notDetermined }
            return memory.hasRequested(kind) ? .denied : .notDetermined
        case .indeterminate: return memory.lastOutcome(kind) ?? .notDetermined
        }
    }

    private func publish(_ kind: PermissionKind, _ status: PermissionStatus) {
        let (changed, targets) = state.withLock { state -> (Bool, [Continuation]) in
            let previous = state.lastKnown.updateValue(status, forKey: kind)
            return (previous != nil && previous != status, Array(state.subscribers.values))
        }
        if changed { for target in targets { target.yield((kind, status)) } }
    }

    private static func securityURL(_ anchor: String) -> URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") ?? URL(fileURLWithPath: "/")
    }

    /// Deep link to the System Settings pane that owns `kind`.
    public static func settingsURL(for kind: PermissionKind) -> URL {
        switch kind {
        case .microphone: securityURL("Privacy_Microphone")
        case .systemAudioRecording: securityURL("Privacy_AudioCapture")
        case .screenRecording: securityURL("Privacy_ScreenCapture")
        case .accessibility: securityURL("Privacy_Accessibility")
        case .notifications:
            URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") ?? URL(fileURLWithPath: "/")
        }
    }
}
