import AppCore
import CoreAudio
import Foundation

/// Thin Core Audio HAL helpers (property reads, listeners, process objects). Internal; hardware-only.
enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T>(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, default value: T
    ) -> T? {
        var addr = address(selector, scope)
        var result = value
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &result) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0) }
        return status == noErr ? result : nil
    }

    static func string(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> String? {
        var addr = address(selector, scope)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        return status == noErr ? value?.takeRetainedValue() as String? : nil
    }

    static func objectIDs(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [AudioObjectID] {
        var addr = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &result) == noErr else { return [] }
        return result
    }

    static func channelCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static var defaultInputID: AudioObjectID? {
        let id = get(system, kAudioHardwarePropertyDefaultInputDevice, default: AudioObjectID(0)) ?? 0
        return id == 0 ? nil : id
    }

    static var defaultOutputID: AudioObjectID? {
        let id = get(system, kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(0)) ?? 0
        return id == 0 ? nil : id
    }

    static func deviceID(forUID uid: String) -> AudioObjectID? {
        objectIDs(system, kAudioHardwarePropertyDevices).first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    static func audioDevice(_ id: AudioObjectID) -> AudioDevice? {
        guard let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let transport = get(id, kAudioDevicePropertyTransportType, default: UInt32(0)) ?? 0
        return AudioDevice(
            id: uid, name: string(id, kAudioObjectPropertyName) ?? uid,
            isInput: channelCount(id, scope: kAudioDevicePropertyScopeInput) > 0,
            isOutput: channelCount(id, scope: kAudioDevicePropertyScopeOutput) > 0,
            isBluetooth: transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE)
    }

    /// Headphone hint: Bluetooth transport (may be a speaker), or built-in output whose data source is 'hdpn'.
    static func outputLooksLikeHeadphones(_ device: AudioObjectID) -> Bool {
        let transport = get(device, kAudioDevicePropertyTransportType, default: UInt32(0)) ?? 0
        if transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE { return true }
        let source: UInt32 = get(device, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput, default: UInt32(0)) ?? 0
        return source == 0x6864_706E  // 'hdpn'
    }

    // MARK: Processes (macOS 14.2+)

    struct AudioProcess {
        var objectID: AudioObjectID
        var pid: pid_t
        var bundleID: String
    }

    static func audioProcesses() -> [AudioProcess] {
        objectIDs(system, kAudioHardwarePropertyProcessObjectList).map {
            AudioProcess(
                objectID: $0, pid: get($0, kAudioProcessPropertyPID, default: pid_t(0)) ?? 0,
                bundleID: string($0, kAudioProcessPropertyBundleID) ?? "")
        }
    }

    /// Process objects whose bundle ID is `bundleID` or one of its helpers (`bundleID.something`).
    static func processObjects(bundleID: String) -> [AudioObjectID] {
        audioProcesses().filter { $0.bundleID == bundleID || $0.bundleID.hasPrefix(bundleID + ".") }.map(\.objectID)
    }

    static func ownProcessObject() -> AudioObjectID? {
        var pid = getpid()
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            system, &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    // MARK: Listeners

    /// Property listener, removed on deinit. The handler runs on `queue`.
    final class Listener: @unchecked Sendable {
        private let object: AudioObjectID
        private var addr: AudioObjectPropertyAddress
        private let queue: DispatchQueue
        private let block: AudioObjectPropertyListenerBlock

        init(
            _ object: AudioObjectID, _ selector: AudioObjectPropertySelector, queue: DispatchQueue,
            handler: @escaping @Sendable () -> Void
        ) {
            self.object = object
            addr = HAL.address(selector)
            self.queue = queue
            block = { _, _ in handler() }
            AudioObjectAddPropertyListenerBlock(object, &addr, queue, block)
        }

        deinit { AudioObjectRemovePropertyListenerBlock(object, &addr, queue, block) }
    }
}
