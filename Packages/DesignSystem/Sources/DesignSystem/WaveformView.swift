import AppKit
import SwiftUI

/// What the waveform has to show while its peaks are not (yet) available.
public enum WaveformLoadState: Sendable, Equatable {
    /// Decoding: a smooth placeholder (shimmering, or static under Reduce Motion).
    case loading
    case ready
    /// No audio track, or the media is missing: a flat line, the ribbon and the scrubber still work.
    case unavailable
}

public enum WaveformStyle: Sendable, Equatable {
    /// Vertical bars (3 pt, 2 pt gaps) centred in the view.
    case bars
    /// A thin progress track, for when the user turned the waveform off.
    case track
}

/// Bar-style waveform scrubber: played bars in Ember, unplayed muted, a thin Ember playhead, optional speaker ribbon,
/// bookmark flags and a highlighted active segment. Click or drag to scrub; Command or Option plus scroll, or the zoom buttons,
/// to zoom. Pinch zooms only when `pinchZooms` is set: players leave it off so a pinch resizes the player window instead.
///
/// Generic on purpose: it knows nothing about transcripts. Feed it peaks, segments and a clock closure. The closure is
/// called only by the playhead layer, so the bars and ribbon are not redrawn when time advances, and between 30 Hz
/// player ticks the playhead is interpolated at display rate while playing (no timer runs while paused).
public struct WaveformView: View {
    private let peaks: PeakPyramid?
    private let loadState: WaveformLoadState
    private let duration: TimeInterval
    private let segments: [WaveformSegment]
    private let bookmarks: [WaveformBookmark]
    private let activeSegment: Int?
    private let style: WaveformStyle
    private let clock: @MainActor () -> WaveformClockSample
    @Binding private var viewport: WaveformViewport
    private let onSeek: (TimeInterval) -> Void
    private let onAdjust: (TimeInterval) -> Void
    private let label: String
    private let identifier: String
    private let pinchZooms: Bool

    @State private var hoverPoint: CGPoint?
    @State private var dragOrigin: CGPoint?
    @State private var dragMoved = false
    @State private var dragPansView = false
    @State private var dragIgnored = false
    @State private var dragStartViewport = WaveformViewport()
    @State private var magnifyStart: WaveformViewport?

    public init(
        peaks: PeakPyramid?, loadState: WaveformLoadState, duration: TimeInterval, segments: [WaveformSegment] = [],
        bookmarks: [WaveformBookmark] = [], activeSegment: Int? = nil, style: WaveformStyle = .bars,
        viewport: Binding<WaveformViewport>, clock: @escaping @MainActor () -> WaveformClockSample,
        onSeek: @escaping (TimeInterval) -> Void, onAdjust: @escaping (TimeInterval) -> Void,
        label: String = "Playback position", identifier: String = "waveform", pinchZooms: Bool = false
    ) {
        self.peaks = peaks
        self.loadState = loadState
        self.duration = duration
        self.segments = segments
        self.bookmarks = bookmarks
        self.activeSegment = activeSegment
        self.style = style
        self.clock = clock
        self._viewport = viewport
        self.onSeek = onSeek
        self.onAdjust = onAdjust
        self.label = label
        self.identifier = identifier
        self.pinchZooms = pinchZooms
    }

    public var body: some View {
        GeometryReader { proxy in
            let metrics = WaveformMetrics(size: proxy.size, hasRibbon: !segments.isEmpty)
            ZStack(alignment: .topLeading) {
                WaveformBarsLayer(
                    peaks: peaks, loadState: loadState, metrics: metrics, viewport: viewport, style: style
                )
                .equatable()
                WaveformRibbonLayer(segments: segments, bookmarks: bookmarks, metrics: metrics, viewport: viewport, duration: duration)
                    .equatable()
                WaveformActiveSegmentLayer(
                    segments: segments, active: activeSegment, metrics: metrics, viewport: viewport, duration: duration)
                WaveformPlayheadLayer(
                    clock: clock, peaks: peaks, loadState: loadState, metrics: metrics, viewport: $viewport, style: style,
                    duration: duration, label: label, identifier: identifier, onAdjust: onAdjust)
            }
            .contentShape(Rectangle())
            .gesture(scrubGesture(metrics: metrics))
            .simultaneousGesture(magnifyGesture(width: metrics.size.width), including: pinchZooms ? .all : .none)
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hoverPoint = point
                case .ended: hoverPoint = nil
                }
            }
            .overlay(alignment: .topLeading) { hoverOverlay(metrics: metrics) }
            .overlay(alignment: .topTrailing) { zoomBadge }
            .background(
                ScrollWheelCatcher { delta, location, modifiers in
                    handleScroll(delta: delta, location: location, modifiers: modifiers, width: metrics.size.width)
                }
            )
            .accessibilityAction(named: "Zoom in") { viewport.zoom(by: 2) }
            .accessibilityAction(named: "Zoom out") { viewport.zoom(by: 0.5) }
            .accessibilityAction(named: "Fit whole recording") { viewport.reset() }
        }
    }

    // MARK: Gestures

    private func hit(at point: CGPoint, metrics: WaveformMetrics) -> WaveformHit {
        WaveformHitTesting.hit(
            at: point, metrics: metrics, viewport: viewport, duration: duration, segments: segments, bookmarks: bookmarks)
    }

    private func scrubGesture(metrics: WaveformMetrics) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragOrigin == nil {
                    dragOrigin = value.startLocation
                    dragMoved = false
                    dragStartViewport = viewport
                    dragIgnored = false
                    dragPansView = viewport.isZoomed && NSEvent.modifierFlags.contains(.option)
                    if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                        viewport.reset()
                        dragIgnored = true
                    }
                }
                guard let origin = dragOrigin, !dragIgnored else { return }
                let travelled = hypot(value.location.x - origin.x, value.location.y - origin.y)
                if travelled > 3 { dragMoved = true }
                if dragPansView {
                    var panned = dragStartViewport
                    panned.pan(byViewFraction: -Double((value.location.x - origin.x) / max(1, metrics.size.width)))
                    panned.follows = false
                    viewport = panned
                    return
                }
                // A press on a segment or flag is a click on that target; it only scrubs once it becomes a drag.
                if case .time = hit(at: origin, metrics: metrics), duration > 0 {
                    scrub(to: value.location.x, width: metrics.size.width)
                } else if dragMoved {
                    scrub(to: value.location.x, width: metrics.size.width)
                }
            }
            .onEnded { value in
                defer {
                    dragOrigin = nil
                    dragMoved = false
                    dragPansView = false
                    dragIgnored = false
                }
                guard let origin = dragOrigin, !dragIgnored, !dragMoved, !dragPansView else { return }
                switch hit(at: origin, metrics: metrics) {
                case .segment(let index):
                    viewport.follows = true
                    onSeek(segments[index].start)
                case .bookmark(let index):
                    viewport.follows = true
                    onSeek(bookmarks[index].time)
                case .time: break
                }
            }
    }

    private func scrub(to x: CGFloat, width: CGFloat) {
        viewport.follows = true
        onSeek(WaveformGeometry.time(atX: x, width: width, viewport: viewport, duration: duration))
    }

    private func magnifyGesture(width: CGFloat) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if magnifyStart == nil { magnifyStart = viewport }
                guard var next = magnifyStart else { return }
                next.setZoom(next.zoom * value.magnification, anchor: value.startAnchor.x)
                next.follows = false
                viewport = next
            }
            .onEnded { _ in magnifyStart = nil }
    }

    private func handleScroll(delta: CGSize, location: CGPoint, modifiers: NSEvent.ModifierFlags, width: CGFloat) -> Bool {
        guard width > 0 else { return false }
        if modifiers.contains(.command) || modifiers.contains(.option) {
            let amount = abs(delta.height) >= abs(delta.width) ? delta.height : delta.width
            guard amount != 0 else { return true }
            viewport.zoom(by: exp(Double(amount) * 0.02), anchor: Double(location.x / width))
            viewport.follows = false
            return true
        }
        guard viewport.isZoomed, abs(delta.width) > abs(delta.height) else { return false }
        viewport.pan(byViewFraction: -Double(delta.width / width))
        viewport.follows = false
        return true
    }

    // MARK: Hover and zoom badge

    @ViewBuilder
    private func hoverOverlay(metrics: WaveformMetrics) -> some View {
        if let point = hoverPoint, duration > 0 {
            let hit = hit(at: point, metrics: metrics)
            let time = WaveformGeometry.time(atX: point.x, width: metrics.size.width, viewport: viewport, duration: duration)
            let segment = WaveformHitTesting.segmentIndex(at: time, in: segments).map { segments[$0] }
            ZStack(alignment: .topLeading) {
                Rectangle().fill(DSColor.secondaryText.opacity(0.45)).frame(width: 1, height: metrics.size.height)
                    .offset(x: point.x - 0.5)
                WaveformTooltip(
                    time: WaveformAccessibility.clock(time), speaker: tooltipSpeaker(hit: hit, segment: segment),
                    detail: tooltipDetail(hit: hit, segment: segment)
                )
                .modifier(TooltipPlacement(x: point.x, width: metrics.size.width))
            }
            // Full-size, top-leading: the line and tooltip are positioned in the waveform's own coordinates, so the overlay
            // must not shrink to its content and be re-centred by the parent (that displaced both from the pointer).
            .frame(width: metrics.size.width, height: metrics.size.height, alignment: .topLeading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func tooltipSpeaker(hit: WaveformHit, segment: WaveformSegment?) -> String? {
        if case .bookmark(let index) = hit { return bookmarks[index].label.isEmpty ? "Bookmark" : bookmarks[index].label }
        return segment.flatMap { $0.label.isEmpty ? nil : $0.label }
    }

    private func tooltipDetail(hit: WaveformHit, segment: WaveformSegment?) -> String? {
        if case .bookmark = hit { return nil }
        return segment.flatMap { $0.snippet.isEmpty ? nil : $0.snippet }
    }

    @ViewBuilder
    private var zoomBadge: some View {
        if viewport.isZoomed {
            HStack(spacing: DSSpacing.xs) {
                Text(String(format: "%.1f×", viewport.zoom)).font(DSTypography.badge).monospacedDigit()
                Button("Fit") {
                    viewport.reset()
                }
                .buttonStyle(.plain)
                .font(DSTypography.badge)
                .foregroundStyle(DSColor.accentText)
                .help("Fit the whole recording (⌘0)")
                .accessibilityLabel("Fit whole recording")
                .accessibilityIdentifier("\(identifier).fit")
            }
            .foregroundStyle(DSColor.secondaryText)
            .padding(.horizontal, DSSpacing.sm).padding(.vertical, 2)
            .background(DSColor.insetBackground, in: Capsule())
            .overlay(Capsule().stroke(DSColor.hairline))
            .padding(.top, 1)
            .dsTransition(.glide)
        }
    }
}

// MARK: - Tooltip

private struct TooltipPlacement: ViewModifier {
    let x: CGFloat
    let width: CGFloat
    @State private var tipWidth: CGFloat = 120

    func body(content: Content) -> some View {
        content
            .fixedSize()
            .background(GeometryReader { proxy in Color.clear.onAppear { tipWidth = proxy.size.width }.onChange(of: proxy.size.width) { _, new in tipWidth = new } })
            .offset(x: min(max(0, x - tipWidth / 2), max(0, width - tipWidth)), y: -56)
    }
}

private struct WaveformTooltip: View {
    let time: String
    let speaker: String?
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: DSSpacing.xs) {
                if let speaker { Text(speaker).font(DSTypography.badge).foregroundStyle(DSColor.primaryText) }
                Text(time).font(DSTypography.timestamp).foregroundStyle(DSColor.secondaryText)
            }
            if let detail {
                Text(detail).font(DSTypography.caption).foregroundStyle(DSColor.primaryText).lineLimit(2).frame(maxWidth: 220, alignment: .leading)
            }
        }
        .padding(.horizontal, DSSpacing.sm).padding(.vertical, DSSpacing.xs)
        .background(DSColor.contentBackground, in: RoundedRectangle(cornerRadius: DSRadius.small))
        .overlay(RoundedRectangle(cornerRadius: DSRadius.small).stroke(DSColor.hairlineStrong))
        .shadow(color: DSColor.shadow.opacity(0.14), radius: 8, y: 2)
    }
}

// MARK: - Drawing

enum WaveformDrawing {
    static let muted = DSColor.secondaryText.opacity(0.32)

    /// One path for all bars (a single fill per layer).
    static func barsPath(metrics: WaveformMetrics, grid: WaveformGeometry.BarGrid, bars: [Float]) -> Path {
        var path = Path()
        let band = metrics.waveBand
        for (index, peak) in bars.enumerated() {
            let height = max(2, CGFloat(pow(Double(min(1, max(0, peak))), 0.75)) * band.height)
            let x = grid.offsetX + CGFloat(index) * WaveformGeometry.barPitch
            guard x + WaveformGeometry.barWidth > 0, x < metrics.size.width else { continue }
            path.addRoundedRect(
                in: CGRect(x: x, y: band.midY - height / 2, width: WaveformGeometry.barWidth, height: height),
                cornerSize: CGSize(width: 1.5, height: 1.5))
        }
        return path
    }

    static func bars(peaks: PeakPyramid?, loadState: WaveformLoadState, metrics: WaveformMetrics, viewport: WaveformViewport) -> (WaveformGeometry.BarGrid, [Float]) {
        let grid = WaveformGeometry.barGrid(viewport: viewport, width: metrics.size.width)
        switch (loadState, peaks) {
        case (.ready, .some(let peaks)):
            return (grid, peaks.bars(startFraction: grid.startFraction, pitchFraction: grid.pitchFraction, count: grid.count))
        case (.loading, _):
            // Smooth, calm placeholder shape.
            let first = Int((grid.startFraction / max(grid.pitchFraction, .leastNonzeroMagnitude)).rounded())
            return (grid, placeholderBars(first: first, count: grid.count))
        default:
            return (grid, [Float](repeating: 0, count: grid.count))
        }
    }

    /// The calm loading shape. Written with explicit types and steps: one long arithmetic closure made the Swift 6.3
    /// type-checker give up ("unable to type-check this expression in reasonable time").
    private static func placeholderBars(first: Int, count: Int) -> [Float] {
        var bars: [Float] = []
        bars.reserveCapacity(count)
        for offset in 0..<count {
            let x: Double = Double(first + offset)
            let slow: Double = 0.12 * sin(x * 0.19)
            let fast: Double = 0.06 * sin(x * 0.53)
            bars.append(Float(0.22 + slow + fast))
        }
        return bars
    }

    static func trackPath(metrics: WaveformMetrics, upTo x: CGFloat) -> Path {
        Path(roundedRect: CGRect(x: 0, y: metrics.waveBand.midY - 2, width: max(0, min(x, metrics.size.width)), height: 4), cornerRadius: 2)
    }
}

/// Muted bars (or the track). Static: redraws only when peaks, zoom, pan or size change.
private struct WaveformBarsLayer: View, Equatable {
    let peaks: PeakPyramid?
    let loadState: WaveformLoadState
    let metrics: WaveformMetrics
    let viewport: WaveformViewport
    let style: WaveformStyle

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.peaks === rhs.peaks && lhs.loadState == rhs.loadState && lhs.metrics == rhs.metrics && lhs.viewport == rhs.viewport
            && lhs.style == rhs.style
    }

    var body: some View {
        PolicyReader { policy in
            if loadState == .loading && style == .bars {
                // The only looping animation in the player, and only while peaks decode; static under Reduce Motion.
                TimelineView(.animation(paused: policy.suppressesMotion)) { timeline in
                    Canvas { context, size in
                        draw(&context, shimmerPhase: policy.suppressesMotion ? nil : timeline.date.timeIntervalSinceReferenceDate)
                    }
                }
            } else {
                Canvas { context, _ in draw(&context, shimmerPhase: nil) }
            }
        }
        .frame(width: metrics.size.width, height: metrics.size.height)
        .accessibilityHidden(true)
    }

    private func draw(_ context: inout GraphicsContext, shimmerPhase: TimeInterval?) {
        if style == .track {
            context.fill(WaveformDrawing.trackPath(metrics: metrics, upTo: metrics.size.width), with: .color(WaveformDrawing.muted))
            return
        }
        let (grid, bars) = WaveformDrawing.bars(peaks: peaks, loadState: loadState, metrics: metrics, viewport: viewport)
        context.fill(WaveformDrawing.barsPath(metrics: metrics, grid: grid, bars: bars), with: .color(WaveformDrawing.muted))
        if let phase = shimmerPhase {
            // A soft highlight sweeping across the placeholder every DSMotion.shimmerDuration seconds.
            let progress = (phase / DSMotion.shimmerDuration).truncatingRemainder(dividingBy: 1)
            let centre = CGFloat(progress) * (metrics.size.width + 160) - 80
            var lit = context
            lit.clip(to: Path(CGRect(x: centre - 60, y: 0, width: 120, height: metrics.size.height)))
            lit.fill(WaveformDrawing.barsPath(metrics: metrics, grid: grid, bars: bars), with: .color(DSColor.secondaryText.opacity(0.35)))
        }
    }
}

/// Segment ribbon and bookmark flags. Static.
private struct WaveformRibbonLayer: View, Equatable {
    let segments: [WaveformSegment]
    let bookmarks: [WaveformBookmark]
    let metrics: WaveformMetrics
    let viewport: WaveformViewport
    let duration: TimeInterval

    var body: some View {
        Canvas { context, _ in
            let band = metrics.ribbonBand
            if band.height > 0 {
                for item in WaveformRibbonLayout.layout(segments: segments, viewport: viewport, duration: duration, width: metrics.size.width) {
                    let segment = segments[item.segment]
                    let inset: CGFloat = item.width > 4 ? 0.5 : 0
                    let rect = CGRect(x: item.x + inset, y: band.minY, width: max(1, item.width - inset * 2), height: band.height)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: min(band.height / 2, 2)),
                        with: .color(segment.color.opacity(segment.isDimmed ? 0.22 : 0.85)))
                }
            }
            for mark in bookmarks {
                let x = WaveformGeometry.x(forTime: mark.time, width: metrics.size.width, viewport: viewport, duration: duration)
                guard x >= -4, x <= metrics.size.width + 4 else { continue }
                let flag = metrics.flagBand
                if metrics.isCompact {
                    // A small downward tick in the dock.
                    var tick = Path()
                    tick.move(to: CGPoint(x: x - 3, y: flag.minY))
                    tick.addLine(to: CGPoint(x: x + 3, y: flag.minY))
                    tick.addLine(to: CGPoint(x: x, y: flag.maxY))
                    tick.closeSubpath()
                    context.fill(tick, with: .color(DSColor.accent))
                } else {
                    context.fill(Path(CGRect(x: x - 0.5, y: flag.minY, width: 1, height: metrics.waveBand.minY - flag.minY + 3)), with: .color(DSColor.accent))
                    context.fill(
                        Path(roundedRect: CGRect(x: x - 0.5, y: flag.minY, width: 7, height: 5), cornerRadius: 1.5),
                        with: .color(DSColor.accent))
                }
            }
        }
        .frame(width: metrics.size.width, height: metrics.size.height)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.segments == rhs.segments && lhs.bookmarks == rhs.bookmarks && lhs.metrics == rhs.metrics && lhs.viewport == rhs.viewport
            && lhs.duration == rhs.duration
    }
}

/// Tint behind the segment that is playing now. Glides between segments (a 120 ms crossfade under Reduce Motion).
private struct WaveformActiveSegmentLayer: View {
    let segments: [WaveformSegment]
    let active: Int?
    let metrics: WaveformMetrics
    let viewport: WaveformViewport
    let duration: TimeInterval
    @State private var lastActive: Int?

    var body: some View {
        let shown = active ?? lastActive
        ZStack(alignment: .topLeading) {
            if let index = shown, index < segments.count, duration > 0 {
                let segment = segments[index]
                let x0 = WaveformGeometry.x(forTime: segment.start, width: metrics.size.width, viewport: viewport, duration: duration)
                let x1 = WaveformGeometry.x(forTime: segment.end, width: metrics.size.width, viewport: viewport, duration: duration)
                let rect = CGRect(x: max(0, x0), y: metrics.waveBand.minY - 2, width: max(2, min(metrics.size.width, x1) - max(0, x0)), height: metrics.size.height - metrics.waveBand.minY + 2)
                RoundedRectangle(cornerRadius: DSRadius.small, style: .continuous)
                    .fill(segment.color.opacity(segment.isDimmed ? 0.06 : 0.14))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .opacity(active == nil || x1 < 0 || x0 > metrics.size.width ? 0 : 1)
            }
        }
        .frame(width: metrics.size.width, height: metrics.size.height, alignment: .topLeading)
        .dsAnimation(.glide, value: active)
        .onChange(of: active) { _, new in if let new { lastActive = new } }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Accent bars up to the playhead, and the playhead line. The only layer that reads the clock.
private struct WaveformPlayheadLayer: View {
    let clock: @MainActor () -> WaveformClockSample
    let peaks: PeakPyramid?
    let loadState: WaveformLoadState
    let metrics: WaveformMetrics
    @Binding var viewport: WaveformViewport
    let style: WaveformStyle
    let duration: TimeInterval
    let label: String
    let identifier: String
    let onAdjust: (TimeInterval) -> Void
    @State private var stamp = TickStamp()

    var body: some View {
        let sample = clock()
        stamp.record(sample.time)
        let fraction = duration > 0 ? sample.time / duration : 0
        let outside = viewport.follows && viewport.isZoomed && !viewport.contains(fraction)
        return TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !sample.isPlaying)) { _ in
            Canvas { context, size in draw(&context, size: size, sample: sample) }
        }
        .frame(width: metrics.size.width, height: metrics.size.height)
        .onChange(of: outside) { _, isOutside in
            if isOutside { viewport.reveal(fraction) }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(WaveformAccessibility.value(time: sample.time, duration: duration))
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityAdjustableAction { direction in
            onAdjust(direction == .increment ? WaveformAccessibility.adjustStep : -WaveformAccessibility.adjustStep)
        }
        .accessibilityIdentifier(identifier)
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, sample: WaveformClockSample) {
        let elapsed = ProcessInfo.processInfo.systemUptime - stamp.uptime
        let time = sample.extrapolated(elapsed: elapsed, duration: duration)
        guard duration > 0 else { return }
        let x = WaveformGeometry.x(forTime: time, width: size.width, viewport: viewport, duration: duration)
        if x > 0 {
            var played = context
            played.clip(to: Path(CGRect(x: 0, y: 0, width: min(x, size.width), height: size.height)))
            if style == .track {
                played.fill(WaveformDrawing.trackPath(metrics: metrics, upTo: x), with: .color(DSColor.accent))
            } else if loadState != .loading {
                let (grid, bars) = WaveformDrawing.bars(peaks: peaks, loadState: loadState, metrics: metrics, viewport: viewport)
                played.fill(WaveformDrawing.barsPath(metrics: metrics, grid: grid, bars: bars), with: .color(DSColor.accent))
            }
        }
        guard x >= -1, x <= size.width + 1 else { return }
        let top = metrics.flagBand.minY
        let bottom = metrics.waveBand.maxY + 1
        context.fill(Path(roundedRect: CGRect(x: x - 0.75, y: top, width: 1.5, height: bottom - top), cornerRadius: 0.75), with: .color(DSColor.accent))
    }
}

/// When the last player tick arrived, so the playhead can be extrapolated between ticks.
private final class TickStamp {
    private(set) var time: TimeInterval = -1
    private(set) var uptime: TimeInterval = 0
    func record(_ newTime: TimeInterval) {
        guard newTime != time else { return }
        time = newTime
        uptime = ProcessInfo.processInfo.systemUptime
    }
}

// MARK: - Scroll wheel

/// Reports scroll-wheel and two-finger scroll events that land inside this view's bounds, without taking hit-testing
/// from the view it backs. Return true from `handler` to consume the event; otherwise it scrolls whatever is underneath.
/// `delta` is the precise scrolling delta; `location` is in this view's coordinates (origin top left).
public struct ScrollWheelCatcher: NSViewRepresentable {
    public typealias Handler = @MainActor (_ delta: CGSize, _ location: CGPoint, _ modifiers: NSEvent.ModifierFlags) -> Bool
    private let handler: Handler

    public init(handler: @escaping Handler) { self.handler = handler }

    public func makeNSView(context: Context) -> CatcherView { CatcherView(handler: handler) }
    public func updateNSView(_ view: CatcherView, context: Context) { view.handler = handler }
    public static func dismantleNSView(_ view: CatcherView, coordinator: ()) { view.stop() }

    @MainActor public final class CatcherView: NSView {
        var handler: Handler
        private var monitor: Any?

        init(handler: @escaping Handler) {
            self.handler = handler
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }
        override public var isFlipped: Bool { true }
        override public func hitTest(_ point: NSPoint) -> NSView? { nil }

        override public func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.consume(event) ?? false }
                return consumed ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func consume(_ event: NSEvent) -> Bool {
            guard let window, event.window === window else { return false }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else { return false }
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
            let delta = CGSize(width: event.scrollingDeltaX * scale, height: event.scrollingDeltaY * scale)
            return handler(delta, point, event.modifierFlags)
        }
    }
}
