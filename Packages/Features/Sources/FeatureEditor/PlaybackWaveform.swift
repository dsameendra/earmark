import AppCore
import DesignSystem
import SwiftUI

/// Features adapter for the generic ``WaveformView``: maps the transcript's segments, speakers and bookmarks onto it.
extension TranscriptEditorModel {
    /// Segment ribbon pieces, sorted by start. Ignored segments are included and dimmed.
    public var waveformSegments: [WaveformSegment] { cachedRibbon() }

    func buildWaveformSegments() -> [WaveformSegment] {
        let names = Dictionary(speakers.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let colors = Dictionary(
            speakers.map { ($0.id, EditorColors.color(color(for: $0.id))) }, uniquingKeysWith: { first, _ in first })
        let fallback = EditorColors.color(color(for: nil))
        return segments.map { segment in
            WaveformSegment(
                start: segment.start, end: max(segment.start, segment.end),
                color: segment.speakerID.flatMap { colors[$0] } ?? fallback, isDimmed: segment.isIgnored,
                label: segment.speakerID.flatMap { names[$0] } ?? "", snippet: Self.snippet(segment.text))
        }
    }

    public var waveformBookmarks: [WaveformBookmark] { cachedBookmarks() }

    func buildWaveformBookmarks() -> [WaveformBookmark] {
        bookmarks.map { WaveformBookmark(time: $0.time, label: $0.note.isEmpty ? "Bookmark" : $0.note) }
    }

    /// Index into ``waveformSegments`` of the segment being spoken (or held in the gap just after it).
    public func waveformActiveIndex(_ id: SegmentID?) -> Int? {
        guard let id else { return nil }
        return segmentIndex(of: id)
    }

    static func snippet(_ text: String, limit: Int = 90) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return flat.count <= limit ? flat : String(flat.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// The scrubber for an editor's playback: dock (about 44 pt) or the large detached-audio view.
struct EditorWaveformView: View {
    let model: TranscriptEditorModel
    var identifier = "editor.player.seek"

    var body: some View {
        let playback = model.playback
        let zoom = playback.zoom
        let loadState: WaveformLoadState = playback.mediaState.isUnavailable ? .unavailable : model.waveformState
        WaveformView(
            peaks: model.waveformPyramid, loadState: loadState, duration: max(playback.duration, model.waveform?.duration ?? 0),
            segments: model.waveformSegments, bookmarks: model.waveformBookmarks,
            activeSegment: model.waveformActiveIndex(playback.activeRef?.segmentID),
            style: model.showWaveform ? .bars : .track, viewport: Bindable(zoom).viewport,
            clock: { WaveformClockSample(time: playback.currentTime, isPlaying: playback.isPlaying, rate: playback.speed) },
            onSeek: { time in
                guard playback.canPlay else { return }
                playback.seek(to: time)
            },
            onAdjust: { playback.skip(by: $0) }, label: "Playback position", identifier: identifier
        )
        .onHover {
            if $0 {
                zoom.target = .waveform
                PlayerZoomRegistry.shared.activate(zoom)  // after a mini-player hover, the menu commands come back to the dock
            }
        }
        .opacity(playback.canPlay ? 1 : 0.5)
        .allowsHitTesting(playback.canPlay)
    }
}
