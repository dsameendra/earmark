import AppCore
import Foundation
import Testing

@testable import Permissions

/// Scriptable probe: `states` is what the OS reports, `onRequest` what a prompt results in.
final class FakeProbe: PermissionProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [PermissionKind: RawPermissionState] = [:]
    private var outcomes: [PermissionKind: RawPermissionState] = [:]
    private(set) var requests: [PermissionKind] = []

    func set(_ kind: PermissionKind, _ state: RawPermissionState) { lock.withLock { states[kind] = state } }
    /// A request moves the OS state to `state` (as the real prompt would).
    func onRequest(_ kind: PermissionKind, becomes state: RawPermissionState) { lock.withLock { outcomes[kind] = state } }

    func rawState(_ kind: PermissionKind) async -> RawPermissionState { lock.withLock { states[kind] ?? .notDetermined } }
    func performRequest(_ kind: PermissionKind) async -> RawPermissionState {
        lock.withLock {
            requests.append(kind)
            let outcome = outcomes[kind] ?? .denied
            if outcome == .granted || kind == .microphone || kind == .notifications { states[kind] = outcome }
            return outcome
        }
    }
    func inputMonitoringGranted() -> Bool { false }
    func requestInputMonitoring() -> Bool { false }
    var requested: [PermissionKind] { lock.withLock { requests } }
}

@Suite struct PermissionsServiceTests {
    func make(_ probe: FakeProbe = FakeProbe()) -> (PermissionsService, FakeProbe) {
        (PermissionsService(probe: probe, memory: InMemoryPermissionMemory()), probe)
    }

    @Test func mapsRawStates() async {
        let (service, probe) = make()
        probe.set(.microphone, .granted)
        probe.set(.notifications, .denied)
        probe.set(.screenRecording, .restricted)
        #expect(await service.status(.microphone) == .granted)
        #expect(await service.status(.notifications) == .denied)
        #expect(await service.status(.screenRecording) == .restricted)
        #expect(await service.status(.accessibility) == .notDetermined)
        #expect(await service.status(.systemAudioRecording) == .notDetermined)
    }

    @Test func requestPromptsOnlyWhenNotDetermined() async {
        let (service, probe) = make()
        probe.onRequest(.microphone, becomes: .granted)
        #expect(await service.request(.microphone) == .granted)
        #expect(await service.request(.microphone) == .granted)
        #expect(probe.requested == [.microphone])  // second call did not prompt
    }

    @Test func deniedIsNeverRePrompted() async {
        let (service, probe) = make()
        probe.set(.microphone, .denied)
        #expect(await service.request(.microphone) == .denied)
        #expect(probe.requested.isEmpty)
    }

    @Test func undistinguishableDenialBecomesDeniedAfterRequest() async {
        // Accessibility reports "not trusted" both before and after a refused prompt.
        let (service, probe) = make()
        probe.onRequest(.accessibility, becomes: .denied)
        #expect(await service.status(.accessibility) == .notDetermined)
        #expect(await service.request(.accessibility) == .denied)
        #expect(await service.status(.accessibility) == .denied)
        #expect(await service.request(.accessibility) == .denied)
        #expect(probe.requested == [.accessibility])
    }

    @Test func systemAudioUsesObservedOutcomeBecauseOSHasNoStatus() async {
        let (service, probe) = make()
        probe.set(.systemAudioRecording, .indeterminate)
        probe.onRequest(.systemAudioRecording, becomes: .indeterminate)
        #expect(await service.status(.systemAudioRecording) == .notDetermined)
        // Tap probe succeeded: granted. The fake keeps the OS state indeterminate, as the real one does without TCC.
        let granted = FakeProbe()
        granted.set(.systemAudioRecording, .indeterminate)
        let memory = InMemoryPermissionMemory()
        let svc = PermissionsService(probe: ProbeReturning(granted, .granted), memory: memory)
        #expect(await svc.request(.systemAudioRecording) == .granted)
        #expect(await svc.status(.systemAudioRecording) == .granted)
        let denied = PermissionsService(probe: ProbeReturning(FakeProbe(), .denied), memory: InMemoryPermissionMemory())
        #expect(await denied.request(.systemAudioRecording) == .denied)
        _ = service
    }

    @Test func silentDenialFlipsToDeniedUntilAudioIsHeard() async {
        let (service, probe) = make()
        probe.set(.systemAudioRecording, .granted)
        #expect(await service.status(.systemAudioRecording) == .granted)
        await service.reportSilentDenial()
        #expect(await service.status(.systemAudioRecording) == .denied)
        await service.reportAudioActivity()
        #expect(await service.status(.systemAudioRecording) == .granted)
    }

    @Test func changesStreamEmitsOnlyRealTransitions() async {
        let (service, probe) = make()
        probe.set(.microphone, .notDetermined)
        _ = await service.status(.microphone)  // baseline, no event
        var iterator = service.changes().makeAsyncIterator()
        probe.set(.microphone, .granted)
        await service.refresh()
        let first = await iterator.next()
        #expect(first?.0 == .microphone && first?.1 == .granted)
        await service.refresh()  // unchanged: no event
        probe.set(.microphone, .denied)
        await service.refresh()
        let second = await iterator.next()
        #expect(second?.0 == .microphone && second?.1 == .denied)
    }

    @Test func deepLinksTargetSystemSettings() {
        let (service, _) = make()
        for kind in PermissionKind.allCases { #expect(service.settingsURL(for: kind).scheme == "x-apple.systempreferences") }
        #expect(service.settingsURL(for: .microphone).absoluteString.hasSuffix("Privacy_Microphone"))
        #expect(service.settingsURL(for: .systemAudioRecording).absoluteString.hasSuffix("Privacy_AudioCapture"))
        #expect(service.settingsURL(for: .screenRecording).absoluteString.hasSuffix("Privacy_ScreenCapture"))
        #expect(service.settingsURL(for: .accessibility).absoluteString.hasSuffix("Privacy_Accessibility"))
        #expect(service.settingsURL(for: .notifications).absoluteString.contains("Notifications"))
        #expect(PermissionsService.inputMonitoringSettingsURL.absoluteString.hasSuffix("Privacy_ListenEvent"))
    }

    @Test func memoryPersistsAcrossServiceInstances() async {
        let memory = InMemoryPermissionMemory()
        let probe = FakeProbe()
        probe.onRequest(.screenRecording, becomes: .denied)
        let first = PermissionsService(probe: probe, memory: memory)
        _ = await first.request(.screenRecording)
        let second = PermissionsService(probe: probe, memory: memory)
        #expect(await second.status(.screenRecording) == .denied)
    }
}

/// Probe whose prompt reports a fixed outcome while the OS state stays indeterminate (System Audio Recording).
struct ProbeReturning: PermissionProbing {
    let base: FakeProbe
    let outcome: RawPermissionState
    init(_ base: FakeProbe, _ outcome: RawPermissionState) {
        self.base = base
        self.outcome = outcome
    }
    func rawState(_ kind: PermissionKind) async -> RawPermissionState { .indeterminate }
    func performRequest(_ kind: PermissionKind) async -> RawPermissionState { outcome }
    func inputMonitoringGranted() -> Bool { false }
    func requestInputMonitoring() -> Bool { false }
}
