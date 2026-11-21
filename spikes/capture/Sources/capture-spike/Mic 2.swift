import AVFoundation
import CoreAudio

/// Mic capture: AVAudioEngine input tap -> AVAudioConverter -> 16 kHz mono Float32 -> SPSC ring.
/// Also forwards native-rate buffers to `onNative` (for recording at full quality).
final class MicCapture {
    let ring = SPSCRing(capacityFrames: 16_000 * 30)
    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    var onNative: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private var cfgObs: NSObjectProtocol?
    private var listeners: [CA.Listener] = []
    var deviceUID: String?   // nil = system default

    func start() throws {
        engine = AVAudioEngine()
        if let uid = deviceUID, let dev = CA.devices().first(where: { $0.uid == uid }) {
            // Select a specific input device (does not change system default).
            var d = dev.id
            let au = engine.inputNode.audioUnit!
            let st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &d, UInt32(MemoryLayout<AudioDeviceID>.size))
            if st != noErr { print("[mic] set device failed \(st)") }
        }
        if ProcessInfo.processInfo.environment["EARMARK_VPIO"] == "1" {
            // Voice-processing IO (AEC + noise suppression). Side effects: ducks other audio, may change format/channel count, BT -> HFP.
            try engine.inputNode.setVoiceProcessingEnabled(true)
            engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        }
        let input = engine.inputNode
        let inFmt = input.outputFormat(forBus: 0)           // hardware-side format after device selection
        guard inFmt.sampleRate > 0 else { throw NSError(domain: "mic", code: 1, userInfo: [NSLocalizedDescriptionKey: "no input format (permission denied or no device)"]) }
        converter = AVAudioConverter(from: inFmt, to: target)
        input.installTap(onBus: 0, bufferSize: 4096, format: inFmt) { [weak self] buf, time in
            guard let self, let conv = self.converter else { return }
            self.onNative?(buf, time)
            let cap = AVAudioFrameCount(Double(buf.frameLength) * 16_000 / inFmt.sampleRate) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: self.target, frameCapacity: cap) else { return }
            var fed = false
            var err: NSError?
            conv.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buf
            }
            if err == nil, let p = out.floatChannelData?[0] { self.ring.write(p, count: Int(out.frameLength)) }
        }
        // Route/config change (device unplugged, default changed, sample-rate change): engine stops itself; rebuild.
        cfgObs = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            print("[mic] AVAudioEngineConfigurationChange -> restarting")
            self?.restart()
        }
        listeners = [
            CA.Listener(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice) { print("[mic] default input device changed") },
            CA.Listener(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices) { print("[mic] device list changed (hot-plug)") },
        ]
        engine.prepare()
        try engine.start()
        print("[mic] started. hw format \(inFmt), device=\(deviceUID ?? "default")")
    }

    private func restart() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let o = cfgObs { NotificationCenter.default.removeObserver(o) }
        do { try start() } catch { print("[mic] restart failed: \(error)") }
    }

    func stop() { engine.inputNode.removeTap(onBus: 0); engine.stop() }
}

func micAuthorization() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return true
    case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
    default: return false
    }
}
