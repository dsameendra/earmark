import AVFoundation
import AppCore
import CoreVideo
import Foundation

#if DEBUG
    /// A silent, local WAV lets UI tests exercise the real media player without capture permissions or user recordings.
    @MainActor enum MockPlaybackMedia {
        static func makeAsset() throws -> MediaAsset {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("EarmarkUITestMedia", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("playback-demo-v2.wav")
            let byteCount = 72 * 16_000 * 2
            if !FileManager.default.fileExists(atPath: url.path) {
                var data = Data()
                func append<T: FixedWidthInteger>(_ number: T) {
                    var value = number.littleEndian
                    withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
                }
                data.append(Data("RIFF".utf8))
                append(UInt32(36 + byteCount))
                data.append(Data("WAVEfmt ".utf8))
                append(UInt32(16))
                append(UInt16(1))
                append(UInt16(1))
                append(UInt32(16_000))
                append(UInt32(32_000))
                append(UInt16(2))
                append(UInt16(16))
                data.append(Data("data".utf8))
                append(UInt32(byteCount))
                // Speech-like phrases (a 140 Hz carrier under a slow syllable envelope with pauses) so the waveform has shape.
                var samples = Data(capacity: byteCount)
                for index in 0..<(byteCount / 2) {
                    let t = Double(index) / 16_000
                    let phrase = max(0, sin(t * 0.9 + 0.4 * sin(t * 0.23)))
                    let syllable = 0.35 + 0.65 * abs(sin(t * 5.1 + sin(t * 1.7)))
                    let gate = phrase > 0.12 ? 1.0 : 0.04
                    let value = sin(t * 2 * .pi * 140) * 0.5 + sin(t * 2 * .pi * 310) * 0.25
                    var sample = Int16(max(-1, min(1, value * phrase * syllable * gate)) * 16_000).littleEndian
                    withUnsafeBytes(of: &sample) { samples.append(contentsOf: $0) }
                }
                data.append(samples)
                try data.write(to: url, options: .atomic)
            }
            if UITestConfiguration.value("-EarmarkTestVideo") == "YES", let video = try? makeVideoAsset(in: folder) { return video }
            return MediaAsset(kind: .audio, bookmark: try url.bookmarkData(options: .withSecurityScope), duration: 72)
        }
    
        /// A tiny generated H.264 clip (one frame per second) so UI tests exercise the video player layout.
        private static func makeVideoAsset(in folder: URL) throws -> MediaAsset {
            let seconds = 72
            let url = folder.appendingPathComponent("playback-demo-video.mp4")
            if !FileManager.default.fileExists(atPath: url.path) {
                let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
                let input = AVAssetWriterInput(
                    mediaType: .video,
                    outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360])
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: input,
                    sourcePixelBufferAttributes: [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 640,
                        kCVPixelBufferHeightKey as String: 360,
                    ])
                writer.add(input)
                writer.startWriting()
                writer.startSession(atSourceTime: .zero)
                for second in 0..<seconds {
                    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
                    var buffer: CVPixelBuffer?
                    CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, nil, &buffer)
                    guard let buffer else { continue }
                    CVPixelBufferLockBaseAddress(buffer, [])
                    if let base = CVPixelBufferGetBaseAddress(buffer) {
                        let shade = UInt8(40 + (second * 3) % 160)
                        memset(base, Int32(shade), CVPixelBufferGetBytesPerRow(buffer) * 360)
                    }
                    CVPixelBufferUnlockBaseAddress(buffer, [])
                    adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(second), timescale: 1))
                }
                input.markAsFinished()
                let done = DispatchSemaphore(value: 0)
                writer.finishWriting { done.signal() }
                done.wait()
                guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            }
            return MediaAsset(kind: .video, bookmark: try url.bookmarkData(options: .withSecurityScope), duration: Double(seconds))
        }
    }
#endif
