import ScreenCaptureKit
import CoreMedia
import AVFoundation

/// ScreenCaptureKit audio fallback (needs Screen Recording TCC). App-scoped audio via SCContentFilter(including: [apps]).
final class SCKAudio: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private(set) var buffers = 0, peak: Float = 0
    func start(bundleID: String) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let app = content.applications.first(where: { $0.bundleIdentifier.hasPrefix(bundleID) }),
              let display = content.displays.first else { throw NSError(domain: "sck", code: 1, userInfo: [NSLocalizedDescriptionKey: "app not found/running"]) }
        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true; cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48_000; cfg.channelCount = 2
        cfg.width = 2; cfg.height = 2; cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1) // video is mandatory-ish; make it tiny
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "sck.audio"))
        try await s.startCapture(); stream = s
    }
    func stop() async { try? await stream?.stopCapture() }
    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid else { return }
        buffers += 1
        try? sb.withAudioBufferList { abl, _ in
            for b in abl { if let p = b.mData?.assumingMemoryBound(to: Float.self) { for i in 0..<(Int(b.mDataByteSize)/4) { peak = max(peak, abs(p[i])) } } }
        }
    }
    func stream(_ s: SCStream, didStopWithError e: Error) { print("[sck] stopped: \(e)") }
}
