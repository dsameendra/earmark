import CoreAudio
import Foundation

enum CA {
    static func addr(_ sel: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, default d: T) -> T? {
        var a = addr(sel, scope); var v = d; var size = UInt32(MemoryLayout<T>.size)
        let st = withUnsafeMutablePointer(to: &v) { AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0) }
        return st == noErr ? v : nil
    }

    static func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var a = addr(sel, scope); var cf: Unmanaged<CFString>?; var size = UInt32(MemoryLayout<CFString?>.size)
        let st = AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &cf)
        return st == noErr ? cf?.takeRetainedValue() as String? : nil
    }

    static func ids(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var a = addr(sel, scope); var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var out = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &out) == noErr else { return [] }
        return out
    }

    static func channelCount(_ dev: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var a = addr(kAudioDevicePropertyStreamConfiguration, scope); var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16); defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static var defaultInput: AudioObjectID { CA.get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, default: AudioObjectID(0)) ?? 0 }
    static var defaultOutput: AudioObjectID { CA.get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(0)) ?? 0 }
    static var allDevices: [AudioObjectID] { ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices) }

    struct Dev { let id: AudioObjectID; let uid: String; let name: String; let inCh: Int; let outCh: Int; let transport: UInt32; let runningSomewhere: Bool }
    static func devices() -> [Dev] {
        allDevices.map { d in
            Dev(id: d, uid: string(d, kAudioDevicePropertyDeviceUID) ?? "?", name: string(d, kAudioObjectPropertyName) ?? "?",
                inCh: channelCount(d, scope: kAudioDevicePropertyScopeInput), outCh: channelCount(d, scope: kAudioDevicePropertyScopeOutput),
                transport: get(d, kAudioDevicePropertyTransportType, default: UInt32(0)) ?? 0,
                runningSomewhere: (get(d, kAudioDevicePropertyDeviceIsRunningSomewhere, default: UInt32(0)) ?? 0) != 0)
        }
    }

    /// Headphone hint: built-in output whose data source is headphones ('hdpn'), or Bluetooth/USB/etc. transport.
    static func outputLooksLikeHeadphones(_ dev: AudioObjectID) -> Bool {
        let t = get(dev, kAudioDevicePropertyTransportType, default: UInt32(0)) ?? 0
        if t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE { return true } // maybe a speaker, only a hint
        if let ds: UInt32 = get(dev, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput, default: UInt32(0)) {
            return ds == 0x6864706E /* 'hdpn' */
        }
        return false
    }

    /// Observe a property; returns a token to keep alive. Handler runs on the given queue.
    final class Listener {
        let obj: AudioObjectID; var a: AudioObjectPropertyAddress; let q: DispatchQueue; let block: AudioObjectPropertyListenerBlock
        init(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
             queue: DispatchQueue = .main, handler: @escaping () -> Void) {
            self.obj = obj; a = CA.addr(sel, scope); q = queue; block = { _, _ in handler() }
            AudioObjectAddPropertyListenerBlock(obj, &a, q, block)
        }
        deinit { AudioObjectRemovePropertyListenerBlock(obj, &a, q, block) }
    }
}

// MARK: - Per-process audio objects (macOS 14.2+; bundleIDs on CATapDescription macOS 26+)
struct AudioProc { let objectID: AudioObjectID; let pid: pid_t; let bundleID: String; let running: Bool; let runningInput: Bool; let runningOutput: Bool }

func audioProcesses() -> [AudioProc] {
    CA.ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).map { o in
        AudioProc(objectID: o,
                  pid: CA.get(o, kAudioProcessPropertyPID, default: pid_t(0)) ?? 0,
                  bundleID: CA.string(o, kAudioProcessPropertyBundleID) ?? "",
                  running: (CA.get(o, kAudioProcessPropertyIsRunning, default: UInt32(0)) ?? 0) != 0,
                  runningInput: (CA.get(o, kAudioProcessPropertyIsRunningInput, default: UInt32(0)) ?? 0) != 0,
                  runningOutput: (CA.get(o, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) ?? 0) != 0)
    }
}

struct MeetingApp { let name: String; let bundlePrefixes: [String] }
let meetingApps = [
    MeetingApp(name: "Zoom", bundlePrefixes: ["us.zoom.xos", "us.zoom.CptHost", "us.zoom.caphost"]),
    MeetingApp(name: "Teams", bundlePrefixes: ["com.microsoft.teams2", "com.microsoft.teams"]),
]
