import AVFoundation
import AppKit
import CoreAudio

setvbuf(stdout, nil, _IOLBF, 0)
let args = Array(CommandLine.arguments.dropFirst())
let cmd = args.first ?? "help"

func prefixes(_ name: String) -> [String] {
    meetingApps.first { $0.name.lowercased() == name.lowercased() }?.bundlePrefixes ?? [name]
}

func sleepSec(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }

func rms(_ p: UnsafePointer<Float>, _ n: Int) -> Float { var s: Float = 0; for i in 0..<n { s += p[i]*p[i] }; return n > 0 ? (s/Float(n)).squareRoot() : 0 }

func drain(_ ring: SPSCRing, label: String, seconds: Double) async {
    let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 16_000); defer { scratch.deallocate() }
    let end = Date().addingTimeInterval(seconds); var total = 0
    while Date() < end {
        let n = ring.read(into: scratch, max: 16_000); total += n
        if n > 0 { print("[\(label)] +\(n) samples rms=\(String(format: "%.4f", rms(scratch, n)))") }
        await sleepSec(0.5)
    }
    print("[\(label)] total samples \(total) dropped \(ring.dropped.load(ordering: .relaxed))")
}

switch cmd {
case "devices":
    let d = CA.defaultInput, o = CA.defaultOutput
    for dev in CA.devices() {
        print("\(dev.id == d ? "IN*" : "   ")\(dev.id == o ? "OUT*" : "    ") id=\(dev.id) uid=\(dev.uid) name=\(dev.name) in=\(dev.inCh) out=\(dev.outCh) transport=\(String(dev.transport, radix: 16)) running=\(dev.runningSomewhere)")
    }
    print("default output headphone hint: \(CA.outputLooksLikeHeadphones(o))")
case "detect": detectOnce()
case "watch": detectWatch(seconds: Double(args.dropFirst().first ?? "60") ?? 60)
case "mic":   // capture-spike mic [seconds] [deviceUID]   (needs Microphone TCC)
    let secs = Double(args.dropFirst().first ?? "5") ?? 5
    guard await micAuthorization() else { print("Microphone permission denied"); exit(2) }
    let m = MicCapture(); m.deviceUID = args.count > 2 ? args[2] : nil
    try m.start(); await drain(m.ring, label: "mic16k", seconds: secs); m.stop()
case "tap":   // capture-spike tap zoom|teams|<bundle prefix> [seconds]   (needs System Audio Recording TCC)
    let name = args.dropFirst().first ?? "zoom"; let secs = Double(args.dropFirst(2).first ?? "10") ?? 10
    let objs = targetProcessObjects(bundlePrefixes: prefixes(name))
    guard !objs.isEmpty else { print("No audio process objects for \(name). Process must be running and have opened audio (join a meeting / play sound)."); exit(3) }
    let t = ProcessTap(); try t.start(processObjectIDs: objs)
    await drain(t.ring, label: "tap48k-interleaved", seconds: secs); t.stop()
    print("frames=\(t.totalFrames) nonZeroFrames=\(t.nonZeroFrames) peak=\(t.peak)")
    print(t.looksSilentlyDenied ? "VERDICT: all-zero audio -> permission denied silently OR the app was silent. Re-run while audio is playing; check System Settings > Privacy & Security > Screen & System Audio Recording." : "VERDICT: audio captured")
case "sck":   // capture-spike sck zoom [seconds]   (needs Screen Recording TCC)
    let name = args.dropFirst().first ?? "zoom"; let secs = Double(args.dropFirst(2).first ?? "10") ?? 10
    let s = SCKAudio(); try await s.start(bundleID: prefixes(name)[0]); await sleepSec(secs); await s.stop()
    print("sck buffers=\(s.buffers) peak=\(s.peak)")
case "record": // capture-spike record zoom|teams <seconds> <outdir>  : mic.mp4 + remote.mp4 + mix.m4a
    let name = args.dropFirst().first ?? "zoom"; let secs = Double(args.dropFirst(2).first ?? "15") ?? 15
    let dir = URL(fileURLWithPath: args.count > 3 ? args[3] : "./out", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    guard await micAuthorization() else { print("Microphone permission denied"); exit(2) }
    let objs = targetProcessObjects(bundlePrefixes: prefixes(name))
    let mic = MicCapture(); let tap = ProcessTap()
    var micW: AACTrackWriter?
    mic.onNative = { buf, _ in
        if micW == nil { micW = try? AACTrackWriter(url: dir.appendingPathComponent("mic.mp4"), sampleRate: buf.format.sampleRate, channels: 1) }
        if let p = buf.floatChannelData?[0] { micW?.append(interleaved: p, frames: Int(buf.frameLength)) }  // ch0 only (mono)
    }
    try mic.start()
    var remoteW: AACTrackWriter?
    if !objs.isEmpty {
        try tap.start(processObjectIDs: objs)
        tap.onBuffer = { abl, fmt, _ in
            let b = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))[0]
            if remoteW == nil { remoteW = try? AACTrackWriter(url: dir.appendingPathComponent("remote.mp4"), sampleRate: fmt.mSampleRate, channels: Int(fmt.mChannelsPerFrame)) }
            if let p = b.mData?.assumingMemoryBound(to: Float.self) { remoteW?.append(interleaved: p, frames: Int(b.mDataByteSize) / Int(fmt.mBytesPerFrame)) }
        }
    } else { print("No \(name) audio process; recording mic only") }
    await sleepSec(secs)
    mic.stop(); tap.stop()
    await micW?.finish(); await remoteW?.finish()
    print("tap peak=\(tap.peak) silentlyDenied=\(tap.looksSilentlyDenied)")
    let tracks = [micW != nil ? dir.appendingPathComponent("mic.mp4") : nil, remoteW != nil ? dir.appendingPathComponent("remote.mp4") : nil].compactMap { $0 }
    try await mixTracks(tracks, to: dir.appendingPathComponent("mix.m4a"))
    print("wrote \(dir.path)")
default:
    print("usage: capture-spike devices | detect | watch [sec] | mic [sec] [deviceUID] | tap zoom|teams [sec] | sck zoom [sec] | record zoom|teams <sec> <outdir>")
}
