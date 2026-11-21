import AVFoundation
import AppCore
import Foundation

/// Downsampled amplitude envelope of a media file for the scrubber (EDIT-AC-16).
public struct WaveformPeaks: Sendable, Equatable {
    /// Peak amplitude (0...1) per bin.
    public var peaks: [Float]
    public var duration: TimeInterval
    public init(peaks: [Float], duration: TimeInterval) {
        self.peaks = peaks
        self.duration = duration
    }

    /// Reduces `samples` to `bins` peaks. Pure; used by ``compute(url:bins:)`` and tests.
    public static func reduce(samples: [Float], bins: Int) -> [Float] {
        guard bins > 0, !samples.isEmpty else { return [] }
        var out = [Float](repeating: 0, count: bins)
        for (index, sample) in samples.enumerated() {
            let bin = min(bins - 1, index * bins / samples.count)
            out[bin] = max(out[bin], abs(sample))
        }
        return out
    }

    /// Reads the first audio track with `AVAssetReader` (works for audio and video files) and builds `bins` peaks.
    public static func compute(url: URL, bins: Int = 800) async -> WaveformPeaks? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
            let duration = try? await asset.load(.duration).seconds, duration > 0,
            let reader = try? AVAssetReader(asset: asset)
        else { return nil }
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 16_000,
            ])
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        var peaks = [Float](repeating: 0, count: bins)
        var position = 0
        let total = max(1, Int(duration * 16_000))
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            var data = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            data.withUnsafeMutableBytes { raw in
                if let base = raw.baseAddress { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base) }
            }
            for sample in data {
                let bin = min(bins - 1, position * bins / total)
                peaks[bin] = max(peaks[bin], abs(sample))
                position += 1
            }
            if Task.isCancelled { return nil }
        }
        let top = peaks.max() ?? 0
        if top > 0 { peaks = peaks.map { $0 / top } }
        return WaveformPeaks(peaks: peaks, duration: duration)
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
