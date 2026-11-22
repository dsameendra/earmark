import AppCore
import DesignSystem
import Foundation
import SwiftUI
import Testing

@testable import FeatureEditor

/// Peak extraction, the on-disk cache and the Features adapter of the waveform scrubber.
@Suite struct WaveformPlaybackTests {
    /// A mono 16 kHz 16-bit WAV: `segments` of (seconds, amplitude) filled with a 220 Hz tone.
    private static func writeWAV(_ parts: [(seconds: Double, amplitude: Double)], to url: URL) throws {
        var samples = Data()
        var index = 0
        for part in parts {
            for _ in 0..<Int(part.seconds * 16_000) {
                var value = Int16(sin(Double(index) / 16_000 * 2 * .pi * 220) * part.amplitude * 32_000).littleEndian
                withUnsafeBytes(of: &value) { samples.append(contentsOf: $0) }
                index += 1
            }
        }
        var data = Data("RIFF".utf8)
        func put<T: FixedWidthInteger>(_ number: T) {
            var value = number.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        put(UInt32(36 + samples.count))
        data.append(Data("WAVEfmt ".utf8))
        put(UInt32(16)); put(UInt16(1)); put(UInt16(1)); put(UInt32(16_000)); put(UInt32(32_000)); put(UInt16(2)); put(UInt16(16))
        data.append(Data("data".utf8))
        put(UInt32(samples.count))
        data.append(samples)
        try data.write(to: url)
    }

    private static func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("waveform-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func extractsPeaksFromGeneratedWAV() async throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("two-levels.wav")
        try Self.writeWAV([(2, 0.8), (2, 0.2)], to: url)
        let peaks = try #require(await WaveformPeaks.extract(url: url))
        #expect(abs(peaks.duration - 4) < 0.05)
        // 25 buckets per second.
        #expect(abs(peaks.peaks.count - 100) <= 2)
        let loud = peaks.peaks[5..<45].min() ?? 0
        let quiet = peaks.peaks[55..<95].max() ?? 1
        #expect(loud > 0.95, "loud half normalises to about 1 (got \(loud))")
        #expect(abs(quiet - 0.25) < 0.06, "quiet half is a quarter of the loud half (got \(quiet))")
        #expect(peaks.peaks.allSatisfy { (0...1).contains($0) })
    }

    @Test func silentMediaStaysFlat() async throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("silence.wav")
        try Self.writeWAV([(2, 0)], to: url)
        let peaks = try #require(await WaveformPeaks.extract(url: url))
        #expect(peaks.peaks.allSatisfy { $0 == 0 })
    }

    @Test func missingOrNonAudioFilesAreUnavailable() async throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(await WaveformPeaks.extract(url: dir.appendingPathComponent("nope.wav")) == nil)
        let junk = dir.appendingPathComponent("junk.wav")
        try Data("not audio".utf8).write(to: junk)
        #expect(await WaveformPeaks.extract(url: junk) == nil)
        let service = WaveformService(cache: WaveformCache(directory: dir.appendingPathComponent("cache")))
        let result = await service.peaks(for: dir.appendingPathComponent("nope.wav"), assetID: "x")
        #expect(result.peaks == nil && result.source == .unavailable)
    }

    @Test func bucketSizeBoundsMemoryForLongFiles() {
        #expect(WaveformPeaks.samplesPerBucket(duration: 60) == 640)
        // Two hours: 25 buckets per second is 180 000, under the 200 000 cap.
        #expect(Int(7_200 * 16_000) / WaveformPeaks.samplesPerBucket(duration: 7_200) <= WaveformPeaks.maxBuckets)
        // Ten hours: the bucket grows so the count stays at the cap.
        #expect(Int(36_000 * 16_000) / WaveformPeaks.samplesPerBucket(duration: 36_000) <= WaveformPeaks.maxBuckets + 1)
    }

    @Test func cacheHitMissAndInvalidation() async throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("clip.wav")
        try Self.writeWAV([(1, 0.5), (1, 0.1)], to: url)
        let cache = WaveformCache(directory: dir.appendingPathComponent("cache"))
        let service = WaveformService(cache: cache)

        let key = try #require(WaveformCache.key(assetID: "asset-1", url: url))
        #expect(!cache.contains(key) && cache.load(key) == nil)  // miss

        let first = await service.peaks(for: url, assetID: "asset-1")
        #expect(first.source == .decoded && first.peaks != nil)
        #expect(cache.contains(key))

        let second = await service.peaks(for: url, assetID: "asset-1")
        #expect(second.source == .cache)
        let decoded = try #require(first.peaks)
        let cached = try #require(second.peaks)
        #expect(decoded.peaks.count == cached.peaks.count && abs(decoded.duration - cached.duration) < 1e-9)
        #expect(zip(decoded.peaks, cached.peaks).allSatisfy { abs($0 - $1) <= 1.0 / 255 })

        // A different asset id is a different entry.
        #expect(await service.peaks(for: url, assetID: "asset-2").source == .decoded)

        // The file changes (mtime and size): the old entry is not reused.
        try Self.writeWAV([(2, 0.5)], to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
        let newKey = try #require(WaveformCache.key(assetID: "asset-1", url: url))
        #expect(newKey != key)
        #expect(await service.peaks(for: url, assetID: "asset-1").source == .decoded)
    }

    @Test func corruptCacheFilesAreIgnored() throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = WaveformCache(directory: dir)
        cache.store(WaveformPeaks(peaks: [0, 0.5, 1], duration: 3), key: "k")
        #expect(cache.load("k")?.peaks.count == 3)
        try Data("EWP1garbage".utf8).write(to: dir.appendingPathComponent("k.peaks"))
        #expect(cache.load("k") == nil)
        #expect(WaveformCache.key(assetID: nil, url: dir.appendingPathComponent("missing.wav")) == nil)
    }

    // MARK: Adapter

    @MainActor @Test func adapterMapsSegmentsSpeakersAndBookmarks() async {
        var ignored = Fixtures.segment("ignored bit", start: 12, speaker: Fixtures.bob.id)
        ignored.isIgnored = true
        let (model, _) = await Fixtures.model(segments: Fixtures.segments() + [ignored])
        let segments = model.waveformSegments
        #expect(segments.count == 4)
        #expect(segments.map(\.start) == segments.map(\.start).sorted())
        #expect(segments[0].label == "Alice" && segments[1].label == "Bob")
        #expect(segments[0].snippet == "hello big world")
        #expect(segments[0].color == segments[2].color && segments[0].color != segments[1].color)
        #expect(!segments[0].isDimmed && segments[3].isDimmed)
        #expect(model.waveformActiveIndex(model.segments[1].id) == 1 && model.waveformActiveIndex(nil) == nil)
        #expect(TranscriptEditorModel.snippet(String(repeating: "word ", count: 60)).hasSuffix("…"))
        // No media: nothing to draw, and the state says so (flat line, not a spinner).
        #expect(model.waveformState == .unavailable && model.waveformPyramid == nil)
    }

    @MainActor @Test func playbackZoomStateIsSharedAndClamped() async {
        let (model, _) = await Fixtures.model()
        let zoom = model.playback.zoom
        zoom.target = .waveform
        for _ in 0..<20 { zoom.zoomIn() }
        #expect(zoom.viewport.zoom == 16)
        for _ in 0..<20 { zoom.zoomOut() }
        #expect(zoom.viewport.zoom == 1)
        zoom.target = .video
        for _ in 0..<20 { zoom.zoomIn() }
        #expect(zoom.videoScale == 3)
        for _ in 0..<20 { zoom.zoomOut() }
        #expect(zoom.videoScale == 0.5)
        zoom.zoomIn()
        zoom.target = .waveform
        zoom.zoomIn()
        zoom.actualSize()
        #expect(zoom.videoScale == 1 && !zoom.viewport.isZoomed && zoom.videoOffset == .zero)
    }

    @MainActor @Test func zoomCommandsActOnTheRegisteredPlayer() {
        let registry = PlayerZoomRegistry()
        let model = PlayerZoomModel()
        #expect(registry.active == nil)
        registry.activate(model)
        registry.active?.zoomIn()
        #expect(model.viewport.zoom > 1)
        registry.deactivate(PlayerZoomModel())
        #expect(registry.active === model)
        registry.deactivate(model)
        #expect(registry.active == nil)
    }

    @Test func scrubberSourceUsesTokensAndTheSharedComponent() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FeatureEditor")
        for name in ["PlaybackWaveform.swift", "PlayerViews.swift", "PlayerZoom.swift", "Waveform.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            for pattern in ["Color(red:", "Color(hex:", "NSColor(", "Color.gray", ".foregroundStyle(.secondary)"] {
                #expect(!text.contains(pattern), "\(name) contains \(pattern)")
            }
        }
        let views = try String(contentsOf: sources.appendingPathComponent("PlayerViews.swift"), encoding: .utf8)
        #expect(!views.contains("Slider("), "the dock scrubs with WaveformView, not a Slider")
    }
}
