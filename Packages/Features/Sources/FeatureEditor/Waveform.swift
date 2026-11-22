import AVFoundation
import AppCore
import CryptoKit
import DesignSystem
import Foundation

/// Downsampled amplitude envelope of a media file for the scrubber (EDIT-AC-16).
public struct WaveformPeaks: Sendable, Equatable {
    /// Peak amplitude (0...1) per bucket.
    public var peaks: [Float]
    public var duration: TimeInterval
    public init(peaks: [Float], duration: TimeInterval) {
        self.peaks = peaks
        self.duration = duration
    }

    /// Target resolution: 25 buckets per second, never more than ``maxBuckets`` (two hours is 180 000).
    public static let bucketsPerSecond = 25
    public static let maxBuckets = 200_000
    /// Decode rate; far above what a 3 pt bar can show and cheap to read.
    static let sampleRate = 16_000

    /// The max-pyramid the view draws from.
    public var pyramid: PeakPyramid { PeakPyramid(peaks: peaks) }

    /// Reduces `samples` to `bins` peaks. Pure; used by tests.
    public static func reduce(samples: [Float], bins: Int) -> [Float] {
        guard bins > 0, !samples.isEmpty else { return [] }
        var out = [Float](repeating: 0, count: bins)
        for (index, sample) in samples.enumerated() {
            let bin = min(bins - 1, index * bins / samples.count)
            out[bin] = max(out[bin], abs(sample))
        }
        return out
    }

    /// Samples folded into one bucket for a file of `duration` seconds.
    static func samplesPerBucket(duration: TimeInterval) -> Int {
        max(sampleRate / bucketsPerSecond, Int((duration * Double(sampleRate) / Double(maxBuckets)).rounded(.up)))
    }

    /// Scales raw bucket maxima so the loud end (98th percentile) reaches 1; silent media stays flat.
    static func normalized(_ raw: [Float]) -> [Float] {
        guard !raw.isEmpty else { return raw }
        let sorted = raw.sorted()
        let reference = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.98))]
        guard reference > 0.0005 else { return [Float](repeating: 0, count: raw.count) }
        return raw.map { min(1, $0 / reference) }
    }

    /// Decodes the first audio track with `AVAssetReader` (audio and video files alike) straight into peak buckets.
    ///
    /// Runs off the caller's actor (`@concurrent`), holds one decoded buffer at a time plus the bucket array, checks
    /// cancellation per decoded buffer (cancelling the reader) so a superseded load stops within a fraction of a second. Returns nil when there is no audio
    /// track, the file cannot be read, or the task was cancelled.
    @concurrent
    public static func extract(url: URL) async -> WaveformPeaks? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
            let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0,
            let reader = try? AVAssetReader(asset: asset)
        else { return nil }
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1,
                AVSampleRateKey: sampleRate,
            ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        let perBucket = samplesPerBucket(duration: duration)
        var buckets: [Float] = []
        buckets.reserveCapacity(Int(duration * Double(sampleRate)) / perBucket + 1)
        var current: Float = 0
        var filled = 0
        var scratch = [Float]()

        while !Task.isCancelled, let buffer = output.copyNextSampleBuffer() {
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                let length = CMBlockBufferGetDataLength(block)
                let count = length / MemoryLayout<Float>.size
                if scratch.count < count { scratch = [Float](repeating: 0, count: count) }
                let copied = scratch.withUnsafeMutableBytes { raw -> Bool in
                    guard let base = raw.baseAddress else { return false }
                    return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size, destination: base)
                        == kCMBlockBufferNoErr
                }
                guard copied else { continue }
                scratch.withUnsafeBufferPointer { samples in
                    for index in 0..<count {
                        let value = abs(samples[index])
                        if value > current { current = value }
                        filled += 1
                        if filled == perBucket {
                            buckets.append(current)
                            current = 0
                            filled = 0
                        }
                    }
                }
            }
        if Task.isCancelled {
            reader.cancelReading()
            return nil
        }
        guard reader.status != .failed else { return nil }
        if filled > 0 { buckets.append(current) }
        guard !buckets.isEmpty else { return nil }
        return WaveformPeaks(peaks: normalized(buckets), duration: duration)
    }
}

/// On-disk cache of extracted peaks, one small file per media asset, keyed by asset id and the file's mtime and size so a
/// replaced or edited file is decoded again. Lives in the app's caches directory (the system may purge it; it is rebuilt).
public struct WaveformCache: Sendable {
    public let directory: URL
    /// Bump when the peak format or resolution changes.
    static let version = 1
    static let maxFiles = 300

    public init(directory: URL) { self.directory = directory }

    public static var `default`: WaveformCache {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let owner = Bundle.main.bundleIdentifier ?? "Earmark"
        return WaveformCache(directory: caches.appendingPathComponent(owner, isDirectory: true).appendingPathComponent("Waveforms", isDirectory: true))
    }

    /// Cache key for `url`, or nil when the file cannot be inspected (missing).
    public static func key(assetID: String?, url: URL) -> String? {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        guard let values = try? fresh.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
            let modified = values.contentModificationDate
        else { return nil }
        let identity = assetID ?? url.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(identity.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(digest)-\(Int(modified.timeIntervalSince1970 * 1000))-\(values.fileSize ?? 0)-v\(version)"
    }

    private func fileURL(_ key: String) -> URL { directory.appendingPathComponent(key).appendingPathExtension("peaks") }

    public func contains(_ key: String) -> Bool { FileManager.default.fileExists(atPath: fileURL(key).path) }

    /// Layout: "EWP1", duration (Double LE), count (UInt32 LE), then one byte per bucket.
    public func load(_ key: String) -> WaveformPeaks? {
        guard let data = try? Data(contentsOf: fileURL(key)), data.count >= 16, data.prefix(4) == Data("EWP1".utf8) else { return nil }
        let duration = data.subdata(in: 4..<12).withUnsafeBytes { Double(bitPattern: UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self))) }
        let count = Int(data.subdata(in: 12..<16).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) })
        guard data.count == 16 + count, duration.isFinite, duration > 0 else { return nil }
        return WaveformPeaks(peaks: data.dropFirst(16).map { Float($0) / 255 }, duration: duration)
    }

    public func store(_ peaks: WaveformPeaks, key: String) {
        var data = Data("EWP1".utf8)
        withUnsafeBytes(of: peaks.duration.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(peaks.peaks.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: peaks.peaks.map { UInt8((min(1, max(0, $0)) * 255).rounded()) })
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(key), options: .atomic)
        prune()
    }

    /// Keeps the newest ``maxFiles`` files so the cache cannot grow without bound.
    private func prune() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys),
            files.count > Self.maxFiles
        else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast) }
        for (file, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - Self.maxFiles) { try? FileManager.default.removeItem(at: file) }
    }
}

/// Peaks for a media file: from the cache when present, otherwise decoded (off the main thread) and cached.
public struct WaveformService: Sendable {
    public enum Source: Sendable, Equatable { case cache, decoded, unavailable }
    public let cache: WaveformCache

    public init(cache: WaveformCache = .default) { self.cache = cache }

    @concurrent
    public func peaks(for url: URL, assetID: String?) async -> (peaks: WaveformPeaks?, source: Source) {
        let key = WaveformCache.key(assetID: assetID, url: url)
        if let key, let hit = cache.load(key) { return (hit, .cache) }
        guard let decoded = await WaveformPeaks.extract(url: url), !Task.isCancelled else { return (nil, .unavailable) }
        if let key { cache.store(decoded, key: key) }
        return (decoded, .decoded)
    }
}

/// A coloured region of the scrubber belonging to one speaker.
public struct SpeakerRegion: Sendable, Hashable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var speakerID: SpeakerID?
}

public enum SpeakerRegions {
    /// Regions for the scrubber: consecutive same-speaker segments are coalesced when closer than `gap` seconds.
    public static func make(from segments: [Segment], gap: TimeInterval = 1) -> [SpeakerRegion] {
        var out: [SpeakerRegion] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) where !segment.isIgnored {
            if let last = out.last, last.speakerID == segment.speakerID, segment.start - last.end <= gap {
                out[out.count - 1].end = max(last.end, segment.end)
            } else {
                out.append(SpeakerRegion(start: segment.start, end: segment.end, speakerID: segment.speakerID))
            }
        }
        return out
    }
}
