import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import DesignSystem

@Suite("Waveform math") struct WaveformMathTests {
    private func lcg(_ seed: UInt64, count: Int) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float((state >> 40) & 0xFFFF) / 65535
        }
    }

    @Test func pyramidRangeMaxMatchesBruteForce() {
        let data = lcg(7, count: 1_237)
        let pyramid = PeakPyramid(peaks: data)
        #expect(pyramid.count == data.count)
        for (a, b) in [(0, 1), (0, 1_237), (3, 4), (5, 900), (1_000, 1_237), (512, 1_024), (511, 513), (100, 100), (-5, 10), (1_200, 5_000)] {
            let lo = max(0, a)
            let hi = min(data.count, b)
            let expected = lo < hi ? data[lo..<hi].max() ?? 0 : 0
            #expect(pyramid.peak(in: a..<b) == expected, "\(a)..<\(b)")
        }
    }

    @Test func emptyAndSingleBucketPyramids() {
        #expect(PeakPyramid(peaks: []).peak(in: 0..<10) == 0)
        #expect(PeakPyramid(peaks: [0.4]).peak(in: 0..<1) == 0.4)
        #expect(PeakPyramid(peaks: []).bars(startFraction: 0, pitchFraction: 0.1, count: 3) == [0, 0, 0])
    }

    @Test func downsamplingPerZoomLevelKeepsPeaks() {
        let data = lcg(11, count: 20_000)
        let pyramid = PeakPyramid(peaks: data)
        for zoom in [1.0, 2, 4, 8, 16] {
            let viewport = WaveformViewport(zoom: zoom, start: 0.2)
            let grid = WaveformGeometry.barGrid(viewport: viewport, width: 1_000)
            let bars = pyramid.bars(startFraction: grid.startFraction, pitchFraction: grid.pitchFraction, count: grid.count)
            #expect(bars.count == grid.count)
            // Every bar is the exact max of its bucket range.
            for index in [0, grid.count / 2, grid.count - 1] {
                let from = Int(((grid.startFraction + Double(index) * grid.pitchFraction) * 20_000).rounded(.down))
                let to = Int(((grid.startFraction + Double(index + 1) * grid.pitchFraction) * 20_000).rounded(.down))
                let expected = from >= 20_000 ? 0 : (data[max(0, from)..<min(20_000, max(to, from + 1))].max() ?? 0)
                #expect(bars[index] == expected, "zoom \(zoom) bar \(index)")
            }
        }
    }

    @Test func viewportZoomClampsAndKeepsAnchorFixed() {
        var viewport = WaveformViewport()
        viewport.setZoom(100)
        #expect(viewport.zoom == 16)
        viewport.setZoom(0.1)
        #expect(viewport.zoom == 1)
        viewport = WaveformViewport()
        viewport.setZoom(4, anchor: 0.25)
        // The time under the anchor stays at the same place in the view.
        #expect(abs((viewport.start + 0.25 * viewport.span) - 0.25) < 1e-9)
        viewport = WaveformViewport(zoom: 2, start: 0.5)
        let pinned = viewport.start + 0.5 * viewport.span
        viewport.setZoom(4, anchor: 0.5)
        #expect(abs((viewport.start + 0.5 * viewport.span) - pinned) < 1e-9)
        viewport.pan(byViewFraction: 100)
        #expect(abs(viewport.end - 1) < 1e-9)
        viewport.pan(byViewFraction: -100)
        #expect(viewport.start == 0)
        viewport.zoom(by: 0.5)
        #expect(viewport.zoom == 2)
        viewport.reset()
        #expect(!viewport.isZoomed && viewport.start == 0 && viewport.follows)
    }

    @Test func revealPagesTheWindowToThePlayhead() {
        var viewport = WaveformViewport(zoom: 4, start: 0)
        #expect(viewport.contains(0.1))
        viewport.reveal(0.5)
        #expect(viewport.contains(0.5))
        let start = viewport.start
        viewport.reveal(0.55)
        #expect(viewport.start == start)
    }

    @Test func barGridIsFixedInTimelineSpaceWhilePanning() {
        let a = WaveformGeometry.barGrid(viewport: WaveformViewport(zoom: 4, start: 0.30), width: 800)
        var panned = WaveformViewport(zoom: 4, start: 0.30)
        panned.pan(byViewFraction: 0.0125)
        let b = WaveformGeometry.barGrid(viewport: panned, width: 800)
        #expect(a.pitchFraction == b.pitchFraction)
        #expect(a.offsetX <= 0 && abs(a.offsetX) < WaveformGeometry.barPitch)
        #expect(a.count >= Int(800 / WaveformGeometry.barPitch))
        let aFirst = a.startFraction / a.pitchFraction
        #expect(abs(aFirst - aFirst.rounded()) < 1e-6)
        #expect(WaveformGeometry.barWidth == 3 && WaveformGeometry.barGap == 2)
    }

    @Test func timeAndXRoundTrip() {
        let viewport = WaveformViewport(zoom: 8, start: 0.4)
        for t in [3_000.0, 3_100, 3_500] {
            let x = WaveformGeometry.x(forTime: t, width: 900, viewport: viewport, duration: 7_200)
            let back = WaveformGeometry.time(atX: x, width: 900, viewport: viewport, duration: 7_200)
            #expect(abs(back - t) < 1e-6)
        }
        #expect(WaveformGeometry.time(atX: -50, width: 900, viewport: WaveformViewport(), duration: 100) == 0)
        #expect(WaveformGeometry.time(atX: 5_000, width: 900, viewport: WaveformViewport(), duration: 100) == 100)
        #expect(WaveformGeometry.time(atX: 10, width: 0, viewport: WaveformViewport(), duration: 100) == 0)
    }

    private let segments = [
        WaveformSegment(start: 0, end: 10, color: .red, label: "A", snippet: "one"),
        WaveformSegment(start: 12, end: 20, color: .blue, label: "B", snippet: "two"),
        WaveformSegment(start: 20, end: 40, color: .red, isDimmed: true, label: "A", snippet: "three"),
    ]

    @Test func scrubHitTesting() {
        let metrics = WaveformMetrics(size: CGSize(width: 400, height: 100))
        let viewport = WaveformViewport()
        let marks = [WaveformBookmark(time: 20, label: "m")]
        func hit(_ x: CGFloat, _ y: CGFloat) -> WaveformHit {
            WaveformHitTesting.hit(
                at: CGPoint(x: x, y: y), metrics: metrics, viewport: viewport, duration: 40, segments: segments, bookmarks: marks)
        }
        #expect(hit(100, metrics.waveBand.midY) == .time(10))
        #expect(hit(50, metrics.ribbonBand.midY) == .segment(0))
        #expect(hit(110, metrics.ribbonBand.midY) == .time(11))  // gap between segments
        #expect(hit(250, metrics.ribbonBand.midY) == .segment(2))
        #expect(hit(200, metrics.flagBand.midY) == .bookmark(0))
        #expect(hit(300, metrics.flagBand.midY) == .time(30))
        #expect(WaveformHitTesting.segmentIndex(at: 15, in: segments) == 1)
        #expect(WaveformHitTesting.segmentIndex(at: 11, in: segments) == nil)
        #expect(WaveformHitTesting.segmentIndex(at: 99, in: segments) == nil)
    }

    @Test func compactMetricsCollapseRibbonAndFlags() {
        let dock = WaveformMetrics(size: CGSize(width: 500, height: 40))
        let large = WaveformMetrics(size: CGSize(width: 500, height: 160))
        #expect(dock.isCompact && !large.isCompact)
        #expect(dock.ribbonBand.height < large.ribbonBand.height)
        #expect(dock.flagBand.height < large.flagBand.height)
        #expect(dock.waveBand.height >= 20)
        #expect(dock.ribbonBand.maxY <= 40 && large.ribbonBand.maxY <= 160)
        #expect(WaveformMetrics(size: CGSize(width: 500, height: 40), hasRibbon: false).ribbonBand.height == 0)
    }

    @Test func ribbonLayoutPlacesAndClipsSegments() {
        let items = WaveformRibbonLayout.layout(segments: segments, viewport: WaveformViewport(), duration: 40, width: 400)
        #expect(items.count == 3)
        #expect(items[0].x == 0 && abs(items[0].width - 100) < 0.001)
        let zoomed = WaveformRibbonLayout.layout(segments: segments, viewport: WaveformViewport(zoom: 4, start: 0.5), duration: 40, width: 400)
        #expect(zoomed.count == 1 && zoomed[0].segment == 2 && zoomed[0].x == 0)
        #expect(WaveformRibbonLayout.layout(segments: [], viewport: WaveformViewport(), duration: 40, width: 400).isEmpty)
    }

    @Test func ribbonLayoutMergesThousandsOfSubPixelSegments() {
        let many = (0..<20_000).map {
            WaveformSegment(start: Double($0) * 0.35, end: Double($0) * 0.35 + 0.3, color: .red)
        }
        let items = WaveformRibbonLayout.layout(segments: many, viewport: WaveformViewport(), duration: 7_000, width: 1_000)
        #expect(items.count < 1_000)
        #expect(!items.isEmpty)
    }

    @Test func accessibilityValueIsSpokenTime() {
        let value = WaveformAccessibility.value(time: 72.9, duration: 2_892)
        #expect(value.contains("1 minute") && value.contains("12 seconds") && value.contains("48 minutes"))
        #expect(WaveformAccessibility.value(time: -3, duration: 0).contains("0 seconds"))
        #expect(WaveformAccessibility.clock(72.9) == "1:12")
        #expect(WaveformAccessibility.clock(3_725) == "1:02:05")
        #expect(WaveformAccessibility.adjustStep == 5)
    }

    @Test func clockExtrapolationIsCapped() {
        let playing = WaveformClockSample(time: 10, isPlaying: true, rate: 2)
        #expect(abs(playing.extrapolated(elapsed: 0.016, duration: 100) - 10.032) < 1e-9)
        #expect(abs(playing.extrapolated(elapsed: 5, duration: 100) - 10.2) < 1e-9)
        #expect(playing.extrapolated(elapsed: 0.05, duration: 10.01) == 10.01)
        #expect(WaveformClockSample(time: 10, isPlaying: false).extrapolated(elapsed: 1, duration: 100) == 10)
    }

    @Test func twoHourFileStaysFastAtEveryZoom() {
        let pyramid = PeakPyramid(peaks: lcg(3, count: 200_000))
        let started = ContinuousClock.now
        var checksum: Float = 0
        for step in 0..<600 {
            let viewport = WaveformViewport(zoom: [1, 2, 4, 8, 16][step % 5], start: Double(step % 50) / 60)
            let grid = WaveformGeometry.barGrid(viewport: viewport, width: 1_600)
            checksum += pyramid.bars(startFraction: grid.startFraction, pitchFraction: grid.pitchFraction, count: grid.count).reduce(0, +)
        }
        let elapsed = ContinuousClock.now - started
        #expect(checksum > 0)
        // 600 frames of 322 bars must cost far less than a 16 ms frame each (debug build, generous bound).
        #expect(elapsed < .seconds(3), "took \(elapsed)")
    }

    @Test func waveformSourcesUseTokensOnly() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/DesignSystem")
        let patterns = [
            "Color(red:", "Color(hex:", "Color(white:", "Color(.sRGB", "NSColor(", "#colorLiteral", "srgbRed:", "Color.gray",
            ".foregroundStyle(.secondary)", "Color.white", "Color.black",
        ]
        for name in ["WaveformView.swift", "WaveformMath.swift"] {
            let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
                .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            for pattern in patterns { #expect(!text.contains(pattern), "\(name) contains \(pattern)") }
            #expect(!text.contains("import AppCore"))
        }
    }
}
