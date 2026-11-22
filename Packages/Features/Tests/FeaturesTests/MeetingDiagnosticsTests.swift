import AppCore
import FeatureSettings
import Foundation
import Testing
import os

private final class FakeDiagnostics: MeetingDiagnosing {
    let outcome: MeetingTestPromptOutcome
    private let sent = OSAllocatedUnfairLock(initialState: 0)
    var testPromptsSent: Int { sent.withLock { $0 } }
    init(outcome: MeetingTestPromptOutcome) { self.outcome = outcome }

    func snapshot() async -> MeetingDiagnosticsSnapshot {
        MeetingDiagnosticsSnapshot(
            apps: [
                MeetingAppDiagnostics(
                    app: .zoom, isRunning: true, micInput: false, audioOutput: true, deviceMicInUse: false, callHelperPresent: true,
                    phase: "candidate"),
                MeetingAppDiagnostics(
                    app: .teams, isRunning: false, micInput: false, audioOutput: false, deviceMicInUse: false, callHelperPresent: false,
                    phase: "idle"),
            ], activeAudioProcesses: ["us.zoom.xos"])
    }

    func sendTestPrompt() async -> MeetingTestPromptOutcome {
        sent.withLock { $0 += 1 }
        return outcome
    }
}

/// Permissions whose status can change between calls (the user toggles a switch in System Settings).
private final class FlippingPermissions: PermissionsServicing {
    private let value = OSAllocatedUnfairLock(initialState: PermissionStatus.denied)
    func flip(to status: PermissionStatus) { value.withLock { $0 = status } }
    func status(_ kind: PermissionKind) async -> PermissionStatus { value.withLock { $0 } }
    func request(_ kind: PermissionKind) async -> PermissionStatus { value.withLock { $0 } }
    func settingsURL(for kind: PermissionKind) -> URL { URL(fileURLWithPath: "/") }
    func changes() -> AsyncStream<(PermissionKind, PermissionStatus)> { AsyncStream { _ in } }
}

@Suite @MainActor struct MeetingDiagnosticsTests {
    @Test func snapshotDescribesRunningAppsAndSignals() async {
        let model = MeetingDiagnosticsModel(source: FakeDiagnostics(outcome: .delivered))
        await model.refresh()
        #expect(model.snapshot.apps.count == 2)
        let zoom = model.snapshot.apps[0]
        #expect(MeetingDiagnosticsModel.signalLine(zoom).contains("audio out on"))
        #expect(MeetingDiagnosticsModel.signalLine(zoom).contains("call helper present"))
        #expect(MeetingDiagnosticsModel.signalLine(model.snapshot.apps[1]) == "Not running")
        #expect(MeetingDiagnosticsModel.phaseLabel("candidate").contains("starting"))
        #expect(model.snapshot.activeAudioProcesses == ["us.zoom.xos"])
    }

    @Test func testPromptReportsDeliveryOrInAppFallback() async {
        let ok = FakeDiagnostics(outcome: .delivered)
        let delivered = MeetingDiagnosticsModel(source: ok)
        await delivered.sendTestPrompt()
        #expect(ok.testPromptsSent == 1 && delivered.testOutcome == .delivered && delivered.testMessage?.contains("Sent") == true)

        let denied = MeetingDiagnosticsModel(source: FakeDiagnostics(outcome: .notificationsDenied))
        await denied.sendTestPrompt()
        #expect(denied.testMessage?.contains("only appear inside Earmark") == true)
    }

    @Test func absentSourceHidesTheSection() {
        #expect(!MeetingDiagnosticsModel(source: nil).isAvailable)
    }

    @Test func recheckPicksUpAToggleMadeInSystemSettings() async {
        let service = FlippingPermissions()
        let model = PermissionsSettingsModel(service: service)
        await model.load()
        #expect(model.rowState(.microphone).showsRecheck)
        service.flip(to: .granted)
        await model.recheck(.microphone)
        #expect(model.status(.microphone) == .granted)
        #expect(model.rowState(.microphone).action == .none && !model.rowState(.microphone).showsRecheck)
        // The same refresh runs on app activation through `load()`.
        service.flip(to: .denied)
        await model.load()
        #expect(model.status(.microphone) == .denied)
    }
}
