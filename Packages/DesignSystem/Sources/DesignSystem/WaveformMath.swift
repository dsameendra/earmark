import CoreGraphics
import Foundation
import SwiftUI

// Pure, UI-free math behind ``WaveformView``: the peak pyramid, zoom and pan, bar grid, hit testing and ribbon layout.
// Everything here is deterministic and unit-tested; the view only draws what these types describe.

/// An immutable max-pyramid over normalised (0...1) peak buckets.
///
/// Level 0 is the input, level `k` holds the maximum of `2^k` neighbouring input buckets. A range maximum is then
/// answered from at most about `2 log2(n)` entries, so drawing a frame costs O(visible bars), never O(buckets) (a
/// two-hour file is about 200 000 buckets). A reference type so views can compare it by identity instead of diffing arrays.
public final class PeakPyramid: Sendable {
    let levels: [[Float]]

    /// Number of base buckets.
    public var count: Int { levels[0].count }
    public var isEmpty: Bool { count == 0 }

    public init(peaks: [Float]) {
        var levels = [peaks]
        while let previous = levels.last, previous.count > 1 {
            var next = [Float]()
            next.reserveCapacity((previous.count + 1) / 2)
            var index = 0
            while index < previous.count {
                next.append(index + 1 < previous.count ? max(previous[index], previous[index + 1]) : previous[index])
                index += 2
            }
            levels.append(next)
        }
        self.levels = levels
    }

    /// The base buckets.
    public var base: [Float] { levels[0] }

    /// Exact maximum over the base buckets in `range` (clamped to the data); 0 for an empty range.
    public func peak(in range: Range<Int>) -> Float {
        var lower = max(0, range.lowerBound)
        let upper = min(count, range.upperBound)
        var result: Float = 0
        while lower < upper {
            // Largest aligned block that starts at `lower` and fits before `upper`.
            var level = lower == 0 ? levels.count - 1 : lower.trailingZeroBitCount
            level = min(level, levels.count - 1)
            while level > 0 && lower + (1 << level) > upper { level -= 1 }
            result = max(result, levels[level][lower >> level])
            lower += 1 << level
        }
        return result
    }

    /// Peaks for `count` consecutive bars; bar `i` covers `[start + i * pitch, start + (i + 1) * pitch)` where both are
    /// fractions of the whole timeline. Bars outside the data are 0.
    public func bars(startFraction start: Double, pitchFraction pitch: Double, count barCount: Int) -> [Float] {
        guard barCount > 0, !isEmpty, pitch > 0 else { return [Float](repeating: 0, count: max(0, barCount)) }
        let n = Double(count)
        return (0..<barCount).map { index in
            let from = Int(((start + Double(index) * pitch) * n).rounded(.down))
            let to = Int(((start + Double(index + 1) * pitch) * n).rounded(.down))
            return peak(in: from..<max(to, from + 1))
        }
    }
}

/// The visible window of the timeline: zoom 1x (all of it) to 16x, and where it starts.
public struct WaveformViewport: Equatable, Sendable {
    public static let zoomRange: ClosedRange<Double> = 1...16
    /// The visible window is "fit" at or below this zoom.
    static let fitTolerance = 1.0001

    public private(set) var zoom: Double
    /// Left edge of the window, as a fraction of the duration.
    public private(set) var start: Double
    /// Whether the window pages along with the playhead. Manual pan and zoom turn it off; a click or Fit turns it on.
    public var follows: Bool

    public init(zoom: Double = 1, start: Double = 0, follows: Bool = true) {
        let z = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, zoom))
        self.zoom = z
        self.start = min(max(0, start), 1 - 1 / z)
        self.follows = follows
    }

    public var span: Double { 1 / zoom }
    public var end: Double { start + span }
    public var isZoomed: Bool { zoom > Self.fitTolerance }

    /// Sets the zoom, keeping the time under `anchor` (0...1 across the view) where it is.
    public mutating func setZoom(_ newZoom: Double, anchor: Double = 0.5) {
        let a = min(1, max(0, anchor))
        let pinned = start + a * span
        zoom = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, newZoom))
        start = Self.clamp(pinned - a * span, span: span)
    }

    public mutating func zoom(by factor: Double, anchor: Double = 0.5) { setZoom(zoom * factor, anchor: anchor) }

    /// Moves the window by `fraction` of its own width (positive reveals later time).
    public mutating func pan(byViewFraction fraction: Double) { start = Self.clamp(start + fraction * span, span: span) }

    /// Back to the whole timeline.
    public mutating func reset() {
        zoom = 1
        start = 0
        follows = true
    }

    /// Pages the window so `fraction` of the timeline is visible, with the playhead a little in from the left edge.
    public mutating func reveal(_ fraction: Double) {
        guard fraction < start || fraction > end else { return }
        start = Self.clamp(fraction - 0.1 * span, span: span)
    }

    /// Whether `fraction` is inside the window.
    public func contains(_ fraction: Double) -> Bool { fraction >= start && fraction <= end }

    private static func clamp(_ start: Double, span: Double) -> Double { min(max(0, start), max(0, 1 - span)) }
}

/// Bar grid and coordinate conversion. Bars are 3 pt wide with 2 pt gaps and sit on a grid fixed in timeline space, so
/// panning moves bars without changing their heights.
public enum WaveformGeometry {
    public static let barWidth: CGFloat = 3
    public static let barGap: CGFloat = 2
    public static var barPitch: CGFloat { barWidth + barGap }

    public struct BarGrid: Equatable, Sendable {
        /// Timeline fraction at the left edge of the first bar.
        public var startFraction: Double
        /// Timeline fraction covered by one bar pitch.
        public var pitchFraction: Double
        public var count: Int
        /// x of the first bar's left edge (<= 0).
        public var offsetX: CGFloat
    }

    public static func barGrid(viewport: WaveformViewport, width: CGFloat) -> BarGrid {
        guard width > 0 else { return BarGrid(startFraction: 0, pitchFraction: 1, count: 0, offsetX: 0) }
        let pitch = Double(barPitch / width) * viewport.span
        let first = (viewport.start / pitch).rounded(.down)
        let firstStart = first * pitch
        let offset = CGFloat((firstStart - viewport.start) / viewport.span) * width
        return BarGrid(
            startFraction: firstStart, pitchFraction: pitch, count: Int((width / barPitch).rounded(.up)) + 2, offsetX: offset)
    }

    /// Timeline time under `x`, clamped to `0...duration`.
    public static func time(atX x: CGFloat, width: CGFloat, viewport: WaveformViewport, duration: TimeInterval) -> TimeInterval {
        guard width > 0, duration > 0 else { return 0 }
        let fraction = viewport.start + Double(x / width) * viewport.span
        return min(duration, max(0, fraction * duration))
    }

    /// x of `time` (may lie outside `0...width`).
    public static func x(forTime time: TimeInterval, width: CGFloat, viewport: WaveformViewport, duration: TimeInterval) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat((time / duration - viewport.start) / viewport.span) * width
    }
}

/// A speaker-coloured stretch of the timeline. Generic: callers map their own segments to this.
public struct WaveformSegment: Hashable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var color: Color
    /// Ignored segments are drawn faded.
    public var isDimmed: Bool
    /// Speaker name for the tooltip.
    public var label: String
    public var snippet: String

    public init(start: TimeInterval, end: TimeInterval, color: Color, isDimmed: Bool = false, label: String = "", snippet: String = "") {
        self.start = start
        self.end = end
        self.color = color
        self.isDimmed = isDimmed
        self.label = label
        self.snippet = snippet
    }
}

public struct WaveformBookmark: Hashable, Sendable {
    public var time: TimeInterval
    public var label: String
    public init(time: TimeInterval, label: String = "") {
        self.time = time
        self.label = label
    }
}

/// Where the bands of the view sit. Short views (the dock) collapse the ribbon to a thin line and the flags to ticks.
public struct WaveformMetrics: Equatable, Sendable {
    public static let compactHeight: CGFloat = 52
    public let size: CGSize
    public let isCompact: Bool
    public let flagBand: CGRect
    public let waveBand: CGRect
    public let ribbonBand: CGRect

    public init(size: CGSize, hasRibbon: Bool = true) {
        self.size = size
        let compact = size.height < Self.compactHeight
        isCompact = compact
        let flagHeight: CGFloat = compact ? 5 : 8
        let ribbonHeight: CGFloat = hasRibbon ? (compact ? 3 : 6) : 0
        let gap: CGFloat = compact ? 2 : 4
        flagBand = CGRect(x: 0, y: 0, width: size.width, height: flagHeight)
        let waveTop = flagHeight + gap
        let waveHeight = max(4, size.height - waveTop - (hasRibbon ? ribbonHeight + gap : 0))
        waveBand = CGRect(x: 0, y: waveTop, width: size.width, height: waveHeight)
        ribbonBand = CGRect(x: 0, y: waveBand.maxY + (hasRibbon ? gap : 0), width: size.width, height: ribbonHeight)
    }
}

/// What a pointer position means.
public enum WaveformHit: Equatable, Sendable {
    case time(TimeInterval)
    case segment(Int)
    case bookmark(Int)
}

public enum WaveformHitTesting {
    /// Index of the segment containing `time`; `segments` must be sorted by start. Nil in gaps.
    public static func segmentIndex(at time: TimeInterval, in segments: [WaveformSegment]) -> Int? {
        var low = 0
        var high = segments.count
        while low < high {
            let mid = (low + high) / 2
            if segments[mid].start <= time { low = mid + 1 } else { high = mid }
        }
        // `low` is the first segment starting after `time`; look back over a few for overlaps.
        var index = low - 1
        var looked = 0
        while index >= 0, looked < 4 {
            if time <= segments[index].end { return index }
            index -= 1
            looked += 1
        }
        return nil
    }

    /// Interprets a click at `point`: a flag in the flag band, a segment in the ribbon band, otherwise a time.
    public static func hit(
        at point: CGPoint, metrics: WaveformMetrics, viewport: WaveformViewport, duration: TimeInterval,
        segments: [WaveformSegment], bookmarks: [WaveformBookmark]
    ) -> WaveformHit {
        let width = metrics.size.width
        let time = WaveformGeometry.time(atX: point.x, width: width, viewport: viewport, duration: duration)
        if point.y <= metrics.waveBand.minY, let index = nearestBookmark(toX: point.x, metrics: metrics, viewport: viewport, duration: duration, bookmarks: bookmarks) {
            return .bookmark(index)
        }
        if metrics.ribbonBand.height > 0, point.y >= metrics.ribbonBand.minY - 3, let index = segmentIndex(at: time, in: segments) {
            return .segment(index)
        }
        return .time(time)
    }

    /// Bookmark whose flag is within 6 pt of `x`.
    public static func nearestBookmark(
        toX x: CGFloat, metrics: WaveformMetrics, viewport: WaveformViewport, duration: TimeInterval, bookmarks: [WaveformBookmark]
    ) -> Int? {
        var best: (Int, CGFloat)?
        for (index, mark) in bookmarks.enumerated() {
            let markX = WaveformGeometry.x(forTime: mark.time, width: metrics.size.width, viewport: viewport, duration: duration)
            let distance = abs(markX - x)
            if distance <= 6, distance < (best?.1 ?? .infinity) { best = (index, distance) }
        }
        return best?.0
    }
}

/// A drawn stretch of the segment ribbon.
public struct WaveformRibbonItem: Equatable, Sendable {
    public var x: CGFloat
    public var width: CGFloat
    /// Index of the first segment merged into this item.
    public var segment: Int
}

public enum WaveformRibbonLayout {
    /// Ribbon pieces for the visible window. Pieces narrower than a point are widened to 1 pt, and neighbours of the
    /// same colour and dimming that touch in the same pixel are merged, so thousands of segments stay a few hundred rects.
    /// `segments` must be sorted by start.
    public static func layout(segments: [WaveformSegment], viewport: WaveformViewport, duration: TimeInterval, width: CGFloat) -> [WaveformRibbonItem] {
        guard width > 0, duration > 0, !segments.isEmpty else { return [] }
        let windowStart = viewport.start * duration
        let windowEnd = viewport.end * duration
        // First segment that can reach the window.
        var low = 0
        var high = segments.count
        while low < high {
            let mid = (low + high) / 2
            if segments[mid].end <= windowStart { low = mid + 1 } else { high = mid }
        }
        var items: [WaveformRibbonItem] = []
        var lastIndex = -1
        var index = max(0, low - 1)
        while index < segments.count, segments[index].start <= windowEnd {
            let segment = segments[index]
            defer { index += 1 }
            guard segment.end > windowStart else { continue }
            let x0 = max(0, WaveformGeometry.x(forTime: segment.start, width: width, viewport: viewport, duration: duration))
            var x1 = min(width, WaveformGeometry.x(forTime: segment.end, width: width, viewport: viewport, duration: duration))
            guard x1 >= x0 else { continue }
            x1 = max(x1, x0 + 1)
            if var last = items.last, lastIndex >= 0, x0 < last.x + last.width + 0.5,
                segments[lastIndex].color == segment.color, segments[lastIndex].isDimmed == segment.isDimmed
            {
                last.width = max(last.width, x1 - last.x)
                items[items.count - 1] = last
            } else {
                items.append(WaveformRibbonItem(x: x0, width: x1 - x0, segment: index))
                lastIndex = index
            }
        }
        return items
    }
}

public enum WaveformAccessibility {
    /// Spoken position, for example "1 minute, 12 seconds of 48 minutes, 12 seconds". Whole seconds, so it changes at 1 Hz.
    public static func value(time: TimeInterval, duration: TimeInterval) -> String {
        func spoken(_ seconds: TimeInterval) -> String {
            Duration.seconds(max(0, seconds).rounded(.down)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
        }
        return "\(spoken(time)) of \(spoken(duration))"
    }

    /// `m:ss` or `h:mm:ss` for tooltips.
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Seconds moved by the VoiceOver increment/decrement action.
    public static let adjustStep: TimeInterval = 5
}

/// Playhead position between 30 Hz player ticks.
public struct WaveformClockSample: Equatable, Sendable {
    public var time: TimeInterval
    public var isPlaying: Bool
    public var rate: Double
    public init(time: TimeInterval, isPlaying: Bool = false, rate: Double = 1) {
        self.time = time
        self.isPlaying = isPlaying
        self.rate = rate
    }

    /// Time `elapsed` seconds after this tick; extrapolation is capped so a stalled player never runs away.
    public func extrapolated(elapsed: TimeInterval, duration: TimeInterval) -> TimeInterval {
        guard isPlaying else { return time }
        return min(duration > 0 ? duration : .infinity, time + min(max(0, elapsed), 0.1) * rate)
    }
}
