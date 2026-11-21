@preconcurrency import AVFoundation
import AppCore
import Foundation

/// Decodes any AVFoundation-readable audio or video file (mp3, m4a, wav, aiff, flac, caf, mp4, mov, m4v, ...) into
/// 16 kHz mono Float32 ``AudioChunk``s using `AVAssetReader`.
///
/// Decoding is pull-based: a chunk is only decoded when the consumer asks for the next element, so at most one chunk
/// (plus one small decoder buffer) is held in memory regardless of file length. Cancelling the consuming task (or
/// dropping the stream) cancels the reader promptly. Sample-rate conversion and channel down-mixing are done by
/// AVFoundation; multiple audio tracks are mixed.
public struct AVFileDecoder: AudioFileDecoder {
    /// Creates a decoder. It is stateless; each ``decode(file:chunkSeconds:startingAt:)`` call has its own reader.
    public init() {}

    /// Streams the file as chunks of `chunkSeconds` (the last one may be shorter).
    ///
    /// - Parameters:
    ///   - file: A file URL.
    ///   - chunkSeconds: Chunk length in seconds (clamped to at least one sample).
    ///   - startingAt: Media time to start from, used to resume from a checkpoint. The first chunk's `startSeconds` is the
    ///     actual presentation time of the first decoded sample, which may differ marginally from `startingAt` for
    ///     compressed formats.
    /// - Throws (through the stream): `AppError.mediaMissing` when the file does not exist (no asset id is known at this
    ///   layer, so a fresh `MediaAssetID` is attached; callers should re-map it) and `AppError.unsupportedFormat` for
    ///   unreadable, DRM-protected, or audio-less media.
    public func decode(file: URL, chunkSeconds: TimeInterval, startingAt: TimeInterval) -> AsyncThrowingStream<AudioChunk, any Error> {
        let chunkSamples = max(1, Int((chunkSeconds * AudioChunk.sampleRate).rounded()))
        let session = DecodeSession(file: file, chunkSamples: chunkSamples, start: max(0, startingAt))
        // Pull-based: the reader is released when the stream ends, errors, is cancelled (next() observes
        // cancellation) or is dropped (AVAssetReader cancels itself on deallocation).
        return AsyncThrowingStream(unfolding: { try await session.next() })
    }

    /// The duration of the file's media in seconds.
    ///
    /// - Throws: `AppError.mediaMissing` / `AppError.unsupportedFormat` as for decoding.
    public func duration(of file: URL) async throws -> TimeInterval {
        let asset = try Self.makeAsset(file)
        do {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard !tracks.isEmpty else { throw AppError.unsupportedFormat("No audio track in \(file.lastPathComponent)") }
            let seconds = try await asset.load(.duration).seconds
            guard seconds.isFinite else { throw AppError.unsupportedFormat("Unknown duration for \(file.lastPathComponent)") }
            return max(0, seconds)
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.unsupportedFormat("\(file.lastPathComponent): \(error.localizedDescription)")
        }
    }

    static func makeAsset(_ file: URL) throws -> AVURLAsset {
        guard FileManager.default.fileExists(atPath: file.path) else { throw AppError.mediaMissing(MediaAssetID()) }
        return AVURLAsset(url: file)
    }
}

/// Owns the non-Sendable reader; actor isolation serialises all access.
private actor DecodeSession {
    private let file: URL
    private let chunkSamples: Int
    private let start: TimeInterval
    private var reader: AVAssetReader?
    private var output: AVAssetReaderAudioMixOutput?
    private var pending: [Float] = []
    private var nextStart: TimeInterval = 0
    private var opened = false
    private var finished = false

    init(file: URL, chunkSamples: Int, start: TimeInterval) {
        self.file = file
        self.chunkSamples = chunkSamples
        self.start = start
    }

    func cancel() {
        finished = true
        reader?.cancelReading()
        reader = nil
        output = nil
        pending = []
    }

    func next() async throws -> AudioChunk? {
        do {
            try Task.checkCancellation()
            if !opened { try await open() }
            guard !finished else { return nil }
            return try readChunk()
        } catch {
            cancel()
            if error is CancellationError { throw error }
            if let appError = error as? AppError { throw appError }
            throw AppError.unsupportedFormat("\(file.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func open() async throws {
        opened = true
        let asset = try AVFileDecoder.makeAsset(file)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw AppError.unsupportedFormat("No audio track in \(file.lastPathComponent)") }
        guard try await asset.load(.isReadable) else { throw AppError.unsupportedFormat("\(file.lastPathComponent) is not readable") }
        if start > 0, try await asset.load(.duration).seconds <= start {
            finished = true  // resuming at or past the end: nothing left to decode
            return
        }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioChunk.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AppError.unsupportedFormat("Cannot decode audio in \(file.lastPathComponent)") }
        reader.add(output)
        if start > 0 {
            reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 48_000), duration: .positiveInfinity)
        }
        guard reader.startReading() else {
            throw AppError.unsupportedFormat("\(file.lastPathComponent): \(reader.error?.localizedDescription ?? "cannot start reading")")
        }
        self.reader = reader
        self.output = output
        nextStart = start
        pending.reserveCapacity(chunkSamples + 65_536)
    }

    private func readChunk() throws -> AudioChunk? {
        guard let reader, let output else { return nil }
        var sawFirstBuffer = false
        while pending.count < chunkSamples {
            try Task.checkCancellation()
            guard let buffer = output.copyNextSampleBuffer() else {
                if reader.status == .failed {
                    throw AppError.unsupportedFormat("\(file.lastPathComponent): \(reader.error?.localizedDescription ?? "decode failed")")
                }
                finished = true
                break
            }
            if !sawFirstBuffer, pending.isEmpty, start > 0, nextStart == start {
                let pts = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                if pts.isFinite, abs(pts - start) < 1 { nextStart = max(0, pts) }
                sawFirstBuffer = true
            }
            append(buffer)
        }
        guard !pending.isEmpty else {
            finished = true
            return nil
        }
        let count = min(chunkSamples, pending.count)
        let samples = Array(pending[0..<count])
        pending.removeFirst(count)
        let chunk = AudioChunk(samples: samples, startSeconds: nextStart, source: .file)
        nextStart += Double(count) / AudioChunk.sampleRate
        return chunk
    }

    private func append(_ buffer: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return }
        let bytes = CMBlockBufferGetDataLength(block)
        let count = bytes / MemoryLayout<Float>.size
        guard count > 0 else { return }
        let old = pending.count
        pending.append(contentsOf: repeatElement(0, count: count))
        pending.withUnsafeMutableBytes { raw in
            _ = CMBlockBufferCopyDataBytes(
                block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                destination: raw.baseAddress! + old * MemoryLayout<Float>.size)
        }
    }
}
