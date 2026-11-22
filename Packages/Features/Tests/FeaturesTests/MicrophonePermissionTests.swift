import AppCore
import AppCoreTesting
import FeatureMeetings
import FeatureMenuBar
import FeatureOnboarding
import FeatureSettings
import FeatureSupport
import Foundation
import Testing
import os

@testable import FeatureLive

// MARK: - Fakes

private final class FakeDevices: AudioDeviceProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var inputs: [AudioDevice]
    private var speakers: Bool
    init(_ inputs: [AudioDevice], speakers: Bool = true) {
        self.inputs = inputs
        self.speakers = speakers
    }
    func set(_ inputs: [AudioDevice]) { lock.withLock { self.inputs = inputs } }
    func devices() async -> [AudioDevice] { lock.withLock { inputs } }
    func defaultInput() async -> AudioDevice? { lock.withLock { inputs.first } }
    func changes() -> AsyncStream<Void> { AsyncStream { _ in } }
    func defaultOutputLooksLikeHeadphones() async -> Bool { lock.withLock { !speakers } }
}

private func input(_ id: String, _ name: String, transport: String? = nil) -> AudioDevice {
    AudioDevice(id: id, name: name, isInput: true, isOutput: false, transportLabel: transport)
}

/// Records every request and which flavour of request it was.
private final class RecordingPermissions: PermissionsServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var current: [PermissionKind: PermissionStatus]
    private(set) var plainRequests: [PermissionKind] = []
    private(set) var againRequests: [PermissionKind] = []
    init(_ statuses: [PermissionKind: PermissionStatus] = [:]) { current = statuses }
    func set(_ kind: PermissionKind, _ status: PermissionStatus) { lock.withLock { current[kind] = status } }
    func status(_ kind: PermissionKind) async -> PermissionStatus { lock.withLock { current[kind] ?? .notDetermined } }
    func request(_ kind: PermissionKind) async -> PermissionStatus {
        lock.withLock { plainRequests.append(kind) }
        return await status(kind)
    }
    func requestAgain(_ kind: PermissionKind) async -> PermissionStatus {
        lock.withLock { againRequests.append(kind) }
        return await status(kind)
    }
    func settingsURL(for kind: PermissionKind) -> URL { PlaceholderPermissions().settingsURL(for: kind) }
    func changes() -> AsyncStream<(PermissionKind, PermissionStatus)> { AsyncStream { _ in } }
}

private final class FailingMic: AudioSource, Sendable {
    let tag = AudioSourceTag.mic(deviceUID: nil)
    let levels = AsyncStream<Float> { $0.finish() }
    let health = AsyncStream<AudioSourceHealth> { $0.finish() }
    let error: AppError
    let requestedUID = OSAllocatedUnfairLock<String?>(initialState: nil)
    init(_ error: AppError) { self.error = error }
    func start() async throws -> AsyncStream<AudioChunk> { throw error }
    func stop() async {}
}

// MARK: - Microphone preferences

@Suite @MainActor struct MicrophonePreferenceTests {
    @Test func overrideBeatsGlobalAndEmptyMeansSystemDefault() {
        #expect(MicrophonePreference.resolve(override: "usb", global: "builtin") == "usb")
        #expect(MicrophonePreference.resolve(override: "", global: "builtin") == "builtin")
        #expect(MicrophonePreference.resolve(override: nil, global: nil) == nil)
        #expect(MicrophonePreference.resolve(override: "", global: "") == nil)
    }

    @Test func eachFeatureReadsItsOwnOverride() async {
        let store = InMemorySettingsStore()
        await store.set("global", for: SettingsKey.inputDeviceUID)
        await store.set("mtg", for: SettingsKey.meetingsInputDeviceUID)
        #expect(await MicrophonePreference.deviceUID(for: .meetings, store: store) == "mtg")
        #expect(await MicrophonePreference.deviceUID(for: .dictation, store: store) == "global")
        #expect(await MicrophonePreference.deviceUID(for: .live, store: store) == "global")
        await store.set(true, for: SettingsKey.voiceProcessing)
        #expect(await MicrophonePreference.voiceProcessing(store: store))
    }

    @Test func aMissingDeviceFallsBackToTheDefaultWithoutForgettingIt() {
        let connected = [input("a", "A")]
        #expect(MicrophonePreference.effective("a", connected: connected) == (uid: "a", fellBack: false))
        #expect(MicrophonePreference.effective("gone", connected: connected) == (uid: nil, fellBack: true))
        #expect(MicrophonePreference.effective(nil, connected: connected) == (uid: nil, fellBack: false))
    }
}

// MARK: - Settings > Audio

@Suite @MainActor struct AudioSettingsAuditTests {
    private func model(
        devices: FakeDevices, store: InMemorySettingsStore = InMemorySettingsStore(),
        preview: (@Sendable (String?) -> any AudioSource)? = nil, permissions: (any PermissionsServicing)? = nil
    ) -> AudioSettingsModel {
        AudioSettingsModel(provider: devices, store: store, microphonePreview: preview, permissions: permissions)
    }

    @Test func missingDeviceKeepsItsNameAndIsNeverErased() async {
        let store = InMemorySettingsStore()
        let devices = FakeDevices([input("usb-1", "Blue Yeti"), input("builtin", "MacBook Microphone")])
        let first = model(devices: devices, store: store)
        await first.load()
        await first.globalDevice.set("usb-1")
        devices.set([input("builtin", "MacBook Microphone")])  // unplugged
        let again = model(devices: devices, store: store)
        await again.load()
        #expect(again.globalDevice.value == "usb-1", "the stored UID survives the device disappearing")
        #expect(again.isMissing("usb-1"))
        #expect(again.missingLabel("usb-1") == "Blue Yeti (disconnected)")
        #expect(again.missingLabel("never-seen") == "Disconnected device")
    }

    @Test func usageLineNamesTheMicrophoneEachFeatureReallyUses() async {
        let devices = FakeDevices([input("builtin", "MacBook Microphone"), input("usb", "Blue Yeti", transport: "USB")])
        let model = model(devices: devices)
        await model.load()
        #expect(model.usage(for: .live) == "Uses MacBook Microphone.")
        await model.globalDevice.set("usb")
        #expect(model.usage(for: .live) == "Uses Blue Yeti.")
        await model.meetingsDevice.set("builtin")
        #expect(model.usage(for: .meetings) == "Uses MacBook Microphone.")
        await model.dictationDevice.set("gone")
        #expect(model.usage(for: .dictation).contains("using MacBook Microphone until it is reconnected"))
        #expect(model.systemDefaultTitle == "System default (MacBook Microphone)")
    }

    @Test func sameNamedDevicesAreToldApart() async {
        let devices = FakeDevices([input("a", "USB Audio", transport: "USB"), input("b", "USB Audio", transport: "Bluetooth")])
        let model = model(devices: devices)
        await model.load()
        #expect(model.label(for: input("a", "USB Audio", transport: "USB")) == "USB Audio (USB)")
        #expect(model.label(for: input("b", "USB Audio", transport: "Bluetooth")) == "USB Audio (Bluetooth)")
    }

    @Test func echoWarningAppearsOnlyOnSpeakersWithoutVoiceProcessing() async {
        let speakers = model(devices: FakeDevices([input("a", "A")], speakers: true))
        await speakers.load()
        #expect(speakers.echoWarning != nil)
        await speakers.voiceProcessing.set(true)
        #expect(speakers.echoWarning == nil)
        let headphones = model(devices: FakeDevices([input("a", "A")], speakers: false))
        await headphones.load()
        #expect(headphones.echoWarning == nil)
    }

    @Test func startFailuresHaveDistinctMessagesAndOnlyPermissionOffersAccess() async {
        let denied = model(devices: FakeDevices([input("a", "A")]), preview: { _ in FailingMic(.permissionDenied(.microphone)) })
        await denied.startMicrophoneTest()
        #expect(denied.meterNeedsPermission && denied.meterError?.contains("microphone access") == true)
        #expect(!denied.isTestingMicrophone)
        let missing = model(devices: FakeDevices([input("a", "A")]), preview: { _ in FailingMic(.deviceUnavailable) })
        await missing.startMicrophoneTest()
        #expect(!missing.meterNeedsPermission && missing.meterError?.contains("not available") == true)
        #expect(missing.meterError != denied.meterError)
    }

    @Test func testingAMissingDeviceUsesTheDefaultAndSaysSo() async {
        let requested = OSAllocatedUnfairLock<[String?]>(initialState: [])
        let devices = FakeDevices([input("builtin", "MacBook Microphone")])
        let store = InMemorySettingsStore()
        await store.set("gone", for: SettingsKey.inputDeviceUID)
        let model = model(devices: devices, store: store) { uid in
            requested.withLock { $0.append(uid) }
            return FailingMic(.deviceUnavailable)
        }
        await model.load()
        await model.startMicrophoneTest()
        #expect(requested.withLock { $0 } == [nil], "a disconnected choice must not be handed to capture")
        await model.stopMicrophoneTest()
        #expect(model.meterNote == nil)
    }

    @Test func permissionGateIsExposedForInlineRequest() async {
        let permissions = RecordingPermissions([.microphone: .denied])
        let model = model(devices: FakeDevices([]), permissions: permissions)
        let gate = try? #require(model.permissionGate)
        await gate?.load()
        #expect(gate?.isBlocked == true)
        await gate?.requestAccess(.microphone)
        #expect(permissions.againRequests == [.microphone])
    }
}

// MARK: - Menu bar and Live keep the saved device

@Suite @MainActor struct VanishedMicrophoneTests {
    @Test func menuBarKeepsTheSavedDeviceWhenItVanishes() async {
        let store = InMemorySettingsStore()
        await store.set("usb", for: SettingsKey.inputDeviceUID)
        var services = AppServices.preview()
        services.settings = store
        services.audioDevices = FakeDevices([input("builtin", "Built-in")])
        let model = MenuBarModel(services: services)
        model.start()
        #expect(await eventually { model.inputDeviceUID == "usb" && !model.devices.isEmpty })
        #expect(model.inputDeviceIsMissing)
        #expect(await store.value(for: SettingsKey.inputDeviceUID, as: String.self) == "usb", "the choice is not wiped")
        model.stop()
    }

    @Test func liveShowsTheVanishedDeviceAsDisconnectedAndKeepsTheOverride() async {
        let store = InMemorySettingsStore()
        await store.set("usb", for: SettingsKey.liveInputDeviceUID)
        var services = AppServices.preview()
        services.settings = store
        services.audioDevices = FakeDevices([input("builtin", "Built-in")])
        let model = LiveModel(services: services)
        await model.loadPreferences()
        let watching = Task { await model.watchDevices() }
        defer { watching.cancel() }
        #expect(await eventually { model.devices.contains { $0.id == "usb" } })
        #expect(model.deviceUID == "usb")
        #expect(model.devices.first { $0.id == "usb" }?.name.contains("Disconnected") == true)
        #expect(model.effectiveDeviceUID == nil, "capture falls back to the system default")
        #expect(await store.value(for: SettingsKey.liveInputDeviceUID, as: String.self) == "usb")
    }
}

// MARK: - Permissions UI state

@Suite @MainActor struct PermissionRecoveryUITests {
    @Test func everyDeniedRowOffersRequestAccessRecheckAndAResetHint() {
        let bundle = "lk.dumindu.earmark.Earmark"
        for context in [PermissionRowContext.settings, .onboarding] {
            for kind in PermissionKind.allCases {
                let row = PermissionRowState(kind: kind, status: .denied, context: context, bundleID: bundle)
                #expect(row.action == .request && row.actionTitle == "Request access", "\(kind) \(context)")
                #expect(row.showsRecheck && row.showsSettingsLink)
                let hint = row.helpNote ?? ""
                if let command = kind.resetCommand(bundleID: bundle) {
                    #expect(hint.contains(command), "\(kind) hint names its tccutil command")
                } else {
                    #expect(hint.contains("System Settings"))
                }
            }
        }
    }

    @Test func restrictedAndGrantedRowsOfferNoRequest() {
        for kind in PermissionKind.allCases {
            #expect(PermissionRowState(kind: kind, status: .restricted).action == .none)
            #expect(PermissionRowState(kind: kind, status: .granted).action == .none)
            #expect(PermissionRowState(kind: kind, status: .granted).helpNote == nil)
            #expect(PermissionRowState(kind: kind, status: .notDetermined).action == .request)
        }
    }

    @Test func settingsAndOnboardingUseRequestAgainAndRecheck() async {
        let permissions = RecordingPermissions([.accessibility: .denied])
        let settings = PermissionsSettingsModel(service: permissions)
        await settings.load()
        await settings.request(.accessibility)
        #expect(permissions.againRequests == [.accessibility] && permissions.plainRequests.isEmpty)
        let onboarding = OnboardingPermissionsModel(permissions: permissions)
        await onboarding.load()
        await onboarding.request(.accessibility)
        #expect(permissions.againRequests == [.accessibility, .accessibility])
        permissions.set(.accessibility, .granted)
        await onboarding.recheck(.accessibility)
        #expect(onboarding.rowState(for: .accessibility).status == .granted)
    }

    @Test func gateListsOnlyWhatIsMissingAndNamesTheFeature() async {
        let permissions = RecordingPermissions([.microphone: .granted, .systemAudioRecording: .denied])
        let gate = PermissionGateModel(kinds: [.microphone, .systemAudioRecording], service: permissions)
        await gate.load()
        #expect(gate.blocked == [.systemAudioRecording])
        #expect(gate.actionTitle(for: .systemAudioRecording) == "Request access")
        let message = gate.message(for: .systemAudioRecording, feature: "Meeting capture")
        #expect(message.contains("Meeting capture") && message.contains("Screen & System Audio Recording"))
        permissions.set(.systemAudioRecording, .granted)
        await gate.recheck(.systemAudioRecording)
        #expect(!gate.isBlocked)
    }

    @Test func gateNeverPromptsOnLoad() async {
        let permissions = RecordingPermissions([.microphone: .notDetermined])
        let gate = PermissionGateModel(kinds: [.microphone], service: permissions)
        await gate.load()
        #expect(permissions.againRequests.isEmpty && permissions.plainRequests.isEmpty)
        #expect(gate.actionTitle(for: .microphone) == "Allow…")
        await gate.requestAccess(.microphone)
        #expect(permissions.againRequests == [.microphone])
    }

    @Test func meetingsAndMenuBarCarryAGate() {
        #expect(MeetingsModel(services: .preview()).permissionGate.kinds == [.microphone, .systemAudioRecording])
        #expect(MenuBarModel(services: .preview()).permissionGate.kinds == [.microphone, .systemAudioRecording])
    }

    @Test func chipsAreSharedByEveryStatus() {
        #expect(PermissionStatus.granted.chipLabel == "Allowed" && PermissionStatus.denied.chipLabel == "Denied")
        #expect(PermissionStatus.notDetermined.chipLabel == "Not requested" && PermissionStatus.restricted.chipLabel == "Restricted")
    }
}
