import Foundation
import AVFoundation

/// One speaker turn. Engine-neutral.
public struct Turn: Sendable, Codable {
    public var speaker: String
    public var start: Double
    public var end: Double
    public init(speaker: String, start: Double, end: Double) { self.speaker = speaker; self.start = start; self.end = end }
}

/// Engine-neutral output: turns + one centroid embedding per speaker label (voice-profile material).
public struct DiarOutput: Sendable, Codable {
    public var turns: [Turn]
    public var embeddings: [String: [Float]]
    public var embeddingModel: String
    public init(turns: [Turn], embeddings: [String: [Float]], embeddingModel: String) {
        self.turns = turns; self.embeddings = embeddings; self.embeddingModel = embeddingModel
    }
}

public protocol DiarizationEngine: Sendable {
    var name: String { get }
    /// 16 kHz mono Float32 samples in, labelled turns out. `cacheDir` = where models live (no ~/Library writes).
    func diarize(samples: [Float], cacheDir: URL) async throws -> DiarOutput
}

public enum Audio {
    /// Load any audio file as 16 kHz mono Float32.
    public static func load16kMono(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        guard let conv = AVAudioConverter(from: file.processingFormat, to: outFmt) else {
            throw NSError(domain: "Audio", code: 1)
        }
        var out = [Float]()
        if file.processingFormat.sampleRate == 16000 && file.processingFormat.channelCount == 1 {
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { throw NSError(domain: "Audio", code: 2) }
            try file.read(into: buf)
            return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
        }
        let inCap: AVAudioFrameCount = 65536
        while true {
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: inCap) else { break }
            if file.framePosition >= file.length { break }
            try file.read(into: inBuf)
            if inBuf.frameLength == 0 { break }
            let ratio = 16000 / file.processingFormat.sampleRate
            let outCap = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 64
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCap) else { break }
            nonisolated(unsafe) var fed = false
            var err: NSError?
            conv.convert(to: outBuf, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return inBuf
            }
            if let err { throw err }
            out.append(contentsOf: UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
        }
        return out
    }
}

public enum RTTM {
    public static func write(_ turns: [Turn], uri: String, to url: URL) throws {
        let lines = turns.sorted { $0.start < $1.start }.map {
            String(format: "SPEAKER %@ 1 %.3f %.3f <NA> <NA> %@ <NA> <NA>", uri, $0.start, $0.end - $0.start, $0.speaker)
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

public enum Vec {
    public static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .nan }
        var d: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count { d += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return 1 - d / max((na.squareRoot() * nb.squareRoot()), 1e-9)
    }
}
