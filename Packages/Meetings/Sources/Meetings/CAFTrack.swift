import Foundation

/// Crash-safe track file: a hand-written CAF (16 kHz mono signed 16-bit little-endian PCM) whose `data` chunk size is
/// `-1` ("until end of file", allowed by the CAF spec for the last chunk). Samples are appended and flushed
/// regularly, so a `kill -9` leaves a file any CAF reader (AVAudioFile, QuickTime) plays up to the last flush; the
/// size is patched on a clean close and by ``CAFTrackRecovery`` after a crash.
enum CAFLayout {
    static let headerBytes = 8 + 12 + 32  // file header + 'desc' chunk
    static let dataChunkHeaderOffset = headerBytes
    static let audioOffset = headerBytes + 12 + 4  // 'data' chunk header + edit count
    static let sampleRate: Double = 16_000
    static let bytesPerFrame = 2

    static func header() -> Data {
        var d = Data()
        d.append(contentsOf: Array("caff".utf8))
        d.appendBE(UInt16(1))  // version
        d.appendBE(UInt16(0))  // flags
        d.append(contentsOf: Array("desc".utf8))
        d.appendBE(Int64(32))
        d.appendBE(sampleRate.bitPattern)
        d.append(contentsOf: Array("lpcm".utf8))
        d.appendBE(UInt32(2))  // kCAFLinearPCMFormatFlagIsLittleEndian
        d.appendBE(UInt32(bytesPerFrame))  // bytes per packet
        d.appendBE(UInt32(1))  // frames per packet
        d.appendBE(UInt32(1))  // channels
        d.appendBE(UInt32(16))  // bits per channel
        d.append(contentsOf: Array("data".utf8))
        d.appendBE(Int64(-1))  // unknown size: until EOF
        d.appendBE(UInt32(0))  // edit count
        return d
    }
}

extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }
}

enum CAFTrackError: Error, Equatable { case notACAFTrack, cannotOpen }

/// Appends 16 kHz mono samples to a CAF track. Not thread safe: owned by the recorder actor.
final class CAFTrackWriter {
    let url: URL
    private var handle: FileHandle?
    private(set) var framesWritten: Int = 0

    init(url: URL) throws {
        self.url = url
        guard FileManager.default.createFile(atPath: url.path, contents: CAFLayout.header()) else { throw CAFTrackError.cannotOpen }
        handle = try FileHandle(forWritingTo: url)
        try handle?.seekToEnd()
    }

    func append(_ samples: [Float]) throws {
        guard !samples.isEmpty, let handle else { return }
        var bytes = [UInt8]()
        bytes.reserveCapacity(samples.count * 2)
        for s in samples {
            let clamped = max(-1, min(1, s.isNaN ? 0 : s))
            let v = Int16(clamped * 32767).littleEndian
            bytes.append(UInt8(truncatingIfNeeded: v))
            bytes.append(UInt8(truncatingIfNeeded: v >> 8))
        }
        try handle.write(contentsOf: Data(bytes))
        framesWritten += samples.count
    }

    func appendSilence(frames: Int) throws {
        guard frames > 0 else { return }
        // Written in blocks so a long gap does not allocate one huge buffer.
        var remaining = frames
        let block = [Float](repeating: 0, count: 16_000)
        while remaining > 0 {
            let n = min(remaining, block.count)
            try append(n == block.count ? block : Array(block.prefix(n)))
            remaining -= n
        }
    }

    /// Pushes written bytes to disk so a crash loses at most the unflushed tail.
    func flush() throws { try handle?.synchronize() }

    /// Patches the data chunk size and closes the file.
    func close() throws {
        guard let handle else { return }
        try handle.synchronize()
        try handle.close()
        self.handle = nil
        _ = try CAFTrackRecovery.repair(url)
    }
}

/// Repairs a track left open by a crash: finds the real frame count from the file length and patches the chunk size.
public enum CAFTrackRecovery {
    /// Returns the number of whole frames in the track.
    @discardableResult
    public static func repair(_ url: URL) throws -> Int {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        guard end >= UInt64(CAFLayout.audioOffset) else { throw CAFTrackError.notACAFTrack }
        try handle.seek(toOffset: 0)
        guard let magic = try handle.read(upToCount: 4), magic == Data("caff".utf8) else { throw CAFTrackError.notACAFTrack }
        let audioBytes = Int(end) - CAFLayout.audioOffset
        let frames = audioBytes / CAFLayout.bytesPerFrame
        // Drop a torn trailing sample, then record the exact size (edit count 4 bytes + audio).
        let usable = frames * CAFLayout.bytesPerFrame
        if usable != audioBytes { try handle.truncate(atOffset: UInt64(CAFLayout.audioOffset + usable)) }
        var size = Data()
        size.appendBE(Int64(4 + usable))
        try handle.seek(toOffset: UInt64(CAFLayout.dataChunkHeaderOffset + 4))
        try handle.write(contentsOf: size)
        return frames
    }

    /// Number of frames without modifying the file.
    public static func frameCount(_ url: URL) throws -> Int {
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        return max(0, size - CAFLayout.audioOffset) / CAFLayout.bytesPerFrame
    }
}

/// Reads frames back from a track written by ``CAFTrackWriter`` (used by the mixer).
final class CAFTrackReader {
    private let handle: FileHandle
    private(set) var framesRemaining: Int

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        framesRemaining = try CAFTrackRecovery.frameCount(url)
        try handle.seek(toOffset: UInt64(CAFLayout.audioOffset))
    }

    func read(maxFrames: Int) throws -> [Float] {
        let n = min(maxFrames, framesRemaining)
        guard n > 0, let data = try handle.read(upToCount: n * CAFLayout.bytesPerFrame) else { return [] }
        framesRemaining -= data.count / CAFLayout.bytesPerFrame
        var out = [Float]()
        out.reserveCapacity(data.count / 2)
        data.withUnsafeBytes { raw in
            for i in 0..<(data.count / 2) {
                let lo = UInt16(raw[2 * i])
                let hi = UInt16(raw[2 * i + 1])
                out.append(Float(Int16(bitPattern: lo | hi << 8)) / 32768)
            }
        }
        return out
    }

    func close() { try? handle.close() }
}
