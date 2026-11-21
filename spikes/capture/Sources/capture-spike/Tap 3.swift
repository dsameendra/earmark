import AVFoundation
import CoreAudio

/// Core Audio process tap on meeting-app processes -> aggregate device -> IOProc.
/// Silent denial: without System Audio Recording permission the tap is created and IO runs, but buffers are all zeros.
final class ProcessTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private(set) var format = AudioStreamBasicDescription()
    let ring = SPSCRing(capacityFrames: 48_000 * 2 * 10)
    var onBuffer: ((UnsafePointer<AudioBufferList>, AudioStreamBasicDescription, UInt64) -> Void)?
    // Zero-buffer detector state (atomics-free: only touched from IO thread, read after stop)
    private(set) var totalFrames = 0, nonZeroFrames = 0
    private(set) var peak: Float = 0

    func start(processObjectIDs: [AudioObjectID]) throws {
        let desc = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        desc.uuid = UUID(); desc.name = "earmark-spike-tap"
        desc.muteBehavior = .unmuted        // never silence the user's meeting audio
        desc.isPrivate = true
        var st = AudioHardwareCreateProcessTap(desc, &tapID)
        guard st == noErr else { throw err("AudioHardwareCreateProcessTap", st) }
        // Tap format
        format = CA.get(tapID, kAudioTapPropertyFormat, default: AudioStreamBasicDescription()) ?? format

        let outUID = CA.string(CA.defaultOutput, kAudioDevicePropertyDeviceUID) ?? ""
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "earmark-spike-agg",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outUID,    // clock source; tap-only aggregate also works on recent OS
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        st = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggID)
        guard st == noErr else { throw err("AudioHardwareCreateAggregateDevice", st) }

        let q = DispatchQueue(label: "tap.io", qos: .userInteractive)
        st = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, q) { [unowned self] _, inData, inTime, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            for b in abl {
                guard let p = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let n = Int(b.mDataByteSize) / 4
                var pk: Float = 0
                for i in 0..<n { pk = max(pk, abs(p[i])) }
                self.peak = max(self.peak, pk)
                self.totalFrames += n / max(1, Int(b.mNumberChannels))
                if pk > 0 { self.nonZeroFrames += n / max(1, Int(b.mNumberChannels)) }
                self.ring.write(p, count: n)
            }
            self.onBuffer?(inData, self.format, inTime.pointee.mHostTime)
        }
        guard st == noErr else { throw err("AudioDeviceCreateIOProcIDWithBlock", st) }
        st = AudioDeviceStart(aggID, procID)
        guard st == noErr else { throw err("AudioDeviceStart", st) }
        print("[tap] running. tap format sr=\(format.mSampleRate) ch=\(format.mChannelsPerFrame) targets=\(processObjectIDs)")
    }

    var looksSilentlyDenied: Bool { totalFrames > 0 && peak == 0 }

    func stop() {
        if let p = procID { AudioDeviceStop(aggID, p); AudioDeviceDestroyIOProcID(aggID, p) }
        if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
    }
    private func err(_ w: String, _ s: OSStatus) -> NSError { NSError(domain: "tap", code: Int(s), userInfo: [NSLocalizedDescriptionKey: "\(w) failed: \(s)"]) }
}

func targetProcessObjects(bundlePrefixes: [String]) -> [AudioObjectID] {
    audioProcesses().filter { p in bundlePrefixes.contains { p.bundleID.hasPrefix($0) } }.map(\.objectID)
}
