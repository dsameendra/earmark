import AppCore
import Foundation
import Testing

@testable import Permissions

/// The "Request access" path for every permission: prompt when never asked, raise the prompts macOS lets us raise again,
/// otherwise re-read and send the user to System Settings; plus the tccutil reset hint per service.
@Suite struct PermissionRecoveryTests {
    func make() -> (PermissionsService, FakeProbe) {
        let probe = FakeProbe()
        return (PermissionsService(probe: probe, memory: InMemoryPermissionMemory()), probe)
    }

    @Test func notDeterminedPromptsForEveryKind() async {
        for kind in PermissionKind.allCases {
            let (service, probe) = make()
            probe.onRequest(kind, becomes: .granted)
            #expect(await service.requestAgain(kind) == .granted, "\(kind)")
            #expect(probe.requested == [kind], "\(kind)")
        }
    }

    @Test func deniedAccessibilityRaisesThePromptAgainAndPicksUpTheNewGrant() async {
        let (service, probe) = make()
        _ = await service.request(.accessibility)  // first ask: denied (memory notes it was requested)
        #expect(await service.status(.accessibility) == .denied)
        probe.onRequest(.accessibility, becomes: .granted)
        #expect(await service.requestAgain(.accessibility) == .granted)
        #expect(probe.requested == [.accessibility, .accessibility])
    }

    @Test func deniedScreenRecordingCallsTheRequestApiAgain() async {
        let (service, probe) = make()
        _ = await service.request(.screenRecording)
        _ = await service.requestAgain(.screenRecording)
        #expect(probe.requested == [.screenRecording, .screenRecording])
        #expect(await service.status(.screenRecording) == .denied)
    }

    @Test func deniedMicrophoneNotificationsAndAudioTapAreOnlyReRead() async {
        for kind in [PermissionKind.microphone, .notifications] {
            let (service, probe) = make()
            probe.set(kind, .denied)
            #expect(await service.requestAgain(kind) == .denied)
            #expect(probe.requested.isEmpty, "\(kind) must not prompt again; macOS ignores it")
            probe.set(kind, .granted)  // the user flipped the switch in System Settings
            #expect(await service.requestAgain(kind) == .granted)
        }
        let (service, probe) = make()
        _ = await service.request(.systemAudioRecording)
        probe.set(.systemAudioRecording, .indeterminate)
        let before = probe.requested.count
        #expect(await service.requestAgain(.systemAudioRecording) == .denied)
        #expect(probe.requested.count == before)
    }

    @Test func requestAgainPublishesTheChange() async {
        let (service, probe) = make()
        probe.set(.microphone, .denied)
        _ = await service.status(.microphone)
        var iterator = service.changes().makeAsyncIterator()
        probe.set(.microphone, .granted)
        _ = await service.requestAgain(.microphone)
        let change = await iterator.next()
        #expect(change?.0 == .microphone && change?.1 == .granted)
    }

    @Test func restrictedStaysRestrictedWithoutPrompting() async {
        let (service, probe) = make()
        probe.set(.microphone, .restricted)
        #expect(await service.requestAgain(.microphone) == .restricted)
        #expect(probe.requested.isEmpty)
    }

    @Test func resetHintsNameTheRightTccService() {
        let id = "lk.dumindu.earmark.Earmark"
        #expect(PermissionKind.microphone.resetCommand(bundleID: id) == "tccutil reset Microphone \(id)")
        #expect(PermissionKind.systemAudioRecording.resetCommand(bundleID: id) == "tccutil reset AudioCapture \(id)")
        #expect(PermissionKind.screenRecording.resetCommand(bundleID: id) == "tccutil reset ScreenCapture \(id)")
        #expect(PermissionKind.accessibility.resetCommand(bundleID: id) == "tccutil reset Accessibility \(id)")
        #expect(PermissionKind.notifications.resetCommand(bundleID: id) == nil)
        #expect(PermissionKind.notifications.resetHint(bundleID: id).contains("System Settings"))
        #expect(PermissionKind.microphone.resetHint(bundleID: nil) == "tccutil reset Microphone lk.dumindu.earmark.Earmark")
    }

    @Test func settingsLinksPointAtTheExactPane() {
        #expect(PermissionsService.settingsURL(for: .screenRecording).absoluteString.hasSuffix("Privacy_ScreenCapture"))
        #expect(PermissionsService.settingsURL(for: .accessibility).absoluteString.hasSuffix("Privacy_Accessibility"))
        #expect(PermissionsService.settingsURL(for: .microphone).absoluteString.hasSuffix("Privacy_Microphone"))
        #expect(PermissionsService.settingsURL(for: .systemAudioRecording).absoluteString.hasSuffix("Privacy_AudioCapture"))
        #expect(PermissionsService.inputMonitoringSettingsURL.absoluteString.hasSuffix("Privacy_ListenEvent"))
    }
}
