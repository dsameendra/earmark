import AppKit
import CoreAudio

/// Read-only meeting detection snapshot. Needs NO TCC permission (process list + audio-object properties are unprivileged).
func detectOnce() {
    let running = NSWorkspace.shared.runningApplications
    let procs = audioProcesses()
    let mic = CA.devices().filter { $0.inCh > 0 }
    print("== Input devices running somewhere (any app using mic): \(mic.filter { $0.runningSomewhere }.map { $0.name })")
    for app in meetingApps {
        let apps = running.filter { r in app.bundlePrefixes.contains { (r.bundleIdentifier ?? "").hasPrefix($0) } }
        let ap = procs.filter { p in app.bundlePrefixes.contains { p.bundleID.hasPrefix($0) } }
        print("== \(app.name): running apps=\(apps.map { "\($0.bundleIdentifier ?? "?")#\($0.processIdentifier)" })")
        for p in ap { print("   audioProc obj=\(p.objectID) pid=\(p.pid) bid=\(p.bundleID) running=\(p.running) in=\(p.runningInput) out=\(p.runningOutput)") }
        let inCall = ap.contains { $0.runningInput } && ap.contains { $0.runningOutput }
        print("   heuristic inCall (mic-in AND audio-out by the app's processes) = \(inCall)")
    }
    print("== All audio processes with input running: \(procs.filter { $0.runningInput }.map { $0.bundleID })")
}

/// Live monitor: re-evaluates on property-change listeners + 2 s poll.
func detectWatch(seconds: Double) {
    detectOnce()
    let l1 = CA.Listener(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) { print("[event] process object list changed"); detectOnce() }
    let l2 = CA.Listener(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice) { print("[event] default input changed") }
    _ = (l1, l2)
    Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
        let p = audioProcesses().filter { $0.runningInput }.map { "\($0.bundleID)" }
        print("[poll] procs w/ input: \(p)")
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
    RunLoop.main.run()
}
