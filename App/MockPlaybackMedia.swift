import AppCore
import Foundation

#if DEBUG
    /// A silent, local WAV lets UI tests exercise the real media player without capture permissions or user recordings.
    enum MockPlaybackMedia {
        static func makeAsset() throws -> MediaAsset {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("EarmarkUITestMedia", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("playback-demo.wav")
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
                data.append(Data(count: byteCount))
                try data.write(to: url, options: .atomic)
            }
            return MediaAsset(kind: .audio, bookmark: try url.bookmarkData(options: .withSecurityScope), duration: 72)
        }
    }
#endif
