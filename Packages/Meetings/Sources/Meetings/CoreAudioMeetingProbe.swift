import AppCore
import AppKit
import CoreAudio
import Foundation
import os

/// Which running apps and audio processes belong to each meeting app. Matching is by bundle-ID **prefix** so helper
/// processes (Teams `...teams2.helper`, Zoom helpers) count; the research could only confirm Zoom's main ID.
public struct MeetingAppSignature: Sendable, Equatable {
    public var app: MeetingApp
    public var bundleIDPrefixes: [String]
    public init(app: MeetingApp, bundleIDPrefixes: [String]) {
        self.app = app
        self.bundleIDPrefixes = bundleIDPrefixes
    }

    /// Zoom: `us.zoom.xos`. Teams: new client `com.microsoft.teams2`, classic `com.microsoft.teams`. Capture-only Zoom
    /// helpers (`us.zoom.CptHost`, `us.zoom.caphost`) never carry call audio so including them is harmless.
    public static let defaults: [MeetingAppSignature] = [
        MeetingAppSignature(app: .zoom, bundleIDPrefixes: ["us.zoom."]),
        MeetingAppSignature(app: .teams, bundleIDPrefixes: ["com.microsoft.teams"]),
    ]

    public func matches(_ bundleID: String) -> Bool { bundleIDPrefixes.contains { bundleID.hasPrefix($0) } }
}

/// Real probe: `NSWorkspace` running applications plus Core Audio per-process `IsRunningInput/Output` and the default
/// input device's `IsRunningSomewhere`. No Accessibility, no polling: launch/quit notifications and Core Audio property
/// listeners signal changes. Listening and reading need no TCC permission (research §4).
public final class CoreAudioMeetingProbe: MeetingProbe {
    private let signatures: [MeetingAppSignature]
    private let hub: AudioListenerHub

    public init(signatures: [MeetingAppSignature] = MeetingAppSignature.defaults) {
        self.signatures = signatures
        self.hub = AudioListenerHub()
    }

    public func activity(for app: MeetingApp) async -> AppAudioActivity {
        guard let signature = signatures.first(where: { $0.app == app }) else { return .inactive }
        return Self.snapshot(signature)
    }

    public func changes() -> AsyncStream<Void> { hub.changes() }

    // MARK: Reading

    static func snapshot(_ signature: MeetingAppSignature) -> AppAudioActivity {
        let running = NSWorkspace.shared.runningApplications.contains { app in
            app.bundleIdentifier.map(signature.matches) ?? false
        }
        guard running else { return .inactive }
        var input = false
        var output = false
        for process in CoreAudioReads.processObjects() {
            guard let bundle = CoreAudioReads.string(process, selector: kAudioProcessPropertyBundleID), signature.matches(bundle) else {
                continue
            }
            if CoreAudioReads.uint32(process, selector: kAudioProcessPropertyIsRunningInput) == 1 { input = true }
            if CoreAudioReads.uint32(process, selector: kAudioProcessPropertyIsRunningOutput) == 1 { output = true }
        }
        return AppAudioActivity(
            isAppRunning: true, micInput: input, audioOutput: output, deviceMicInUse: CoreAudioReads.defaultInputRunning())
    }
}

enum CoreAudioReads {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress
    {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func processObjects() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func uint32(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func string(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func defaultInputDevice() -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &device) == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    static func defaultInputRunning() -> Bool {
        guard let device = defaultInputDevice() else { return false }
        return uint32(device, selector: kAudioDevicePropertyDeviceIsRunningSomewhere) == 1
    }
}

/// Owns the Core Audio property listeners and workspace observers. Listeners are re-attached to per-process objects
/// whenever the process list changes. Everything is torn down when the last `changes()` stream terminates.
final class AudioListenerHub: @unchecked Sendable {
    private struct Registration {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private let queue = DispatchQueue(label: "lk.dumindu.earmark.meetings.probe")
    private let lock = OSAllocatedUnfairLock()
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var registrations: [Registration] = []
    private var processRegistrations: [AudioObjectID: [Registration]] = [:]
    private var inputDeviceRegistration: Registration?
    private var observers: [any NSObjectProtocol] = []

    func changes() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            let first = lock.withLock { () -> Bool in
                continuations[id] = continuation
                return continuations.count == 1
            }
            continuation.onTermination = { [weak self] _ in self?.remove(id) }
            if first { queue.async { self.attach() } }
        }
    }

    private func remove(_ id: UUID) {
        let last = lock.withLock { () -> Bool in
            continuations.removeValue(forKey: id)
            return continuations.isEmpty
        }
        if last { queue.async { self.detach() } }
    }

    private func notify() {
        let targets = lock.withLock { Array(continuations.values) }
        for target in targets { target.yield(()) }
    }

    // Must run on `queue`.
    private func attach() {
        let relist = makeBlock { [weak self] in
            self?.syncProcessListeners()
            self?.syncInputDeviceListener()
            self?.notify()
        }
        add(CoreAudioReads.system, CoreAudioReads.address(kAudioHardwarePropertyProcessObjectList), relist, into: &registrations)
        let defaultInput = makeBlock { [weak self] in
            self?.syncInputDeviceListener()
            self?.notify()
        }
        add(CoreAudioReads.system, CoreAudioReads.address(kAudioHardwarePropertyDefaultInputDevice), defaultInput, into: &registrations)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.notify() })
        }
        syncProcessListeners()
        syncInputDeviceListener()
        notify()
    }

    private func detach() {
        for r in registrations { remove(r) }
        registrations = []
        for list in processRegistrations.values { for r in list { remove(r) } }
        processRegistrations = [:]
        if let r = inputDeviceRegistration { remove(r) }
        inputDeviceRegistration = nil
        for o in observers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        observers = []
    }

    private func syncProcessListeners() {
        let current = Set(CoreAudioReads.processObjects())
        for (object, list) in processRegistrations where !current.contains(object) {
            for r in list { remove(r) }
            processRegistrations[object] = nil
        }
        for object in current where processRegistrations[object] == nil {
            var list: [Registration] = []
            for selector in [kAudioProcessPropertyIsRunningInput, kAudioProcessPropertyIsRunningOutput] {
                add(object, CoreAudioReads.address(selector), makeBlock { [weak self] in self?.notify() }, into: &list)
            }
            processRegistrations[object] = list
        }
    }

    private func syncInputDeviceListener() {
        if let r = inputDeviceRegistration { remove(r) }
        inputDeviceRegistration = nil
        guard let device = CoreAudioReads.defaultInputDevice() else { return }
        var list: [Registration] = []
        add(
            device, CoreAudioReads.address(kAudioDevicePropertyDeviceIsRunningSomewhere), makeBlock { [weak self] in self?.notify() },
            into: &list)
        inputDeviceRegistration = list.first
    }

    private func makeBlock(_ body: @escaping @Sendable () -> Void) -> AudioObjectPropertyListenerBlock {
        { _, _ in body() }
    }

    private func add(
        _ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ block: @escaping AudioObjectPropertyListenerBlock,
        into list: inout [Registration]
    ) {
        var addr = address
        if AudioObjectAddPropertyListenerBlock(object, &addr, queue, block) == noErr {
            list.append(Registration(object: object, address: address, block: block))
        }
    }

    private func remove(_ registration: Registration) {
        var addr = registration.address
        AudioObjectRemovePropertyListenerBlock(registration.object, &addr, queue, registration.block)
    }
}
