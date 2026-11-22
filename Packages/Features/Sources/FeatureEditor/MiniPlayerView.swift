import AppCore
import DesignSystem
import SwiftUI

// glass-layer: floater (the persistent mini-player; replaces the editor's player dock whenever the editor is not on screen)
/// Compact player shown on every screen while the shared playback session exists and its editor is not showing.
public struct MiniPlayerView: View {
    private let center: PlaybackCenter
    private let onOpenTranscript: (TranscriptID) -> Void
    @State private var size: MiniPlayerSizeModel
    private let registry: PlayerSizeRegistry

    /// A pinch on the mini-player scales the player itself between compact, regular and large (never the waveform), and
    /// View > Make Player Larger / Smaller step through the same presets.
    public init(
        center: PlaybackCenter, onOpenTranscript: @escaping (TranscriptID) -> Void, size: MiniPlayerSizeModel? = nil,
        registry: PlayerSizeRegistry = .shared
    ) {
        self.center = center
        self.onOpenTranscript = onOpenTranscript
        _size = State(initialValue: size ?? MiniPlayerSizeModel())
        self.registry = registry
    }

    public var body: some View {
        if let session = center.session {
            content(session)
        }
    }

    private func content(_ session: PlaybackSession) -> some View {
        let playback = session.playback
        let scale = size.scale
        return HStack(spacing: DSSpacing.md * scale) {
            Button {
                playback.togglePlay()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(DSTypography.headline)
                    .frame(width: 32 * scale, height: 32 * scale)
                    .foregroundStyle(DSColor.primaryText)
                    .background(DSColor.accentTint, in: Circle())
            }
            .buttonStyle(.plain).disabled(!playback.canPlay)
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
            .accessibilityValue(playback.isPlaying ? "Playing" : "Paused")
            .help("Play/Pause (Space or K)")
            .accessibilityIdentifier("miniPlayer.play")
            Button {
                onOpenTranscript(session.transcriptID)
            } label: {
                Text(session.title).font(size.preset == .compact ? DSTypography.body : DSTypography.headline).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 220 * scale, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("Open \(session.title)")
            .accessibilityLabel("Open \(session.title)")
            .accessibilityIdentifier("miniPlayer.title")
            Text(TimeFormat.clock(playback.currentTime)).font(DSTypography.timestamp).monospacedDigit()
                .accessibilityLabel("Playback position")
                .accessibilityValue(String(format: "%.2f", playback.currentTime))
                .accessibilityIdentifier("miniPlayer.position")
            MiniPlayerWaveform(session: session)
                .frame(minWidth: 120 * scale, minHeight: 36 * scale, maxHeight: 36 * scale)
            Text(TimeFormat.clock(playback.duration)).font(DSTypography.timestamp).foregroundStyle(DSColor.secondaryText)
            Button {
                center.stop()
            } label: {
                Image(systemName: "xmark").font(DSTypography.caption).frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help("Stop playback and close the player")
            .accessibilityLabel("Close player")
            .accessibilityIdentifier("miniPlayer.close")
        }
        .padding(DSSpacing.md * scale)
        .frame(maxWidth: .infinity)
        .dsGlass(.clear, radius: DSRadius.panel)
        .dsAnimation(.glide, value: size.preset)
        .gesture(
            MagnifyGesture()
                .onChanged { size.pinch(magnification: $0.magnification) }
                .onEnded { _ in size.endPinch() }
        )
        .onHover { if $0 { registry.activate(size) } else { registry.deactivate(size) } }
        .onDisappear { registry.deactivate(size) }
        .accessibilityAction(named: "Make larger") { size.makeLarger() }
        .accessibilityAction(named: "Make smaller") { size.makeSmaller() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mini player")
        .accessibilityIdentifier("miniPlayer")
    }
}

/// Space / K / J / L / arrows for the shared session while no editor is on screen. Mount it once in the shell and keep
/// ``isEnabled`` false whenever the editor for the session's transcript is visible (it installs its own capture).
public struct SharedPlaybackShortcuts: View {
    private let center: PlaybackCenter
    private let isEnabled: () -> Bool

    public init(center: PlaybackCenter, isEnabled: @escaping () -> Bool = { true }) {
        self.center = center
        self.isEnabled = isEnabled
    }

    public var body: some View {
        if let session = center.session {
            PlaybackKeyboardCapture(playback: session.playback, isEnabled: isEnabled).allowsHitTesting(false)
        } else {
            Color.clear.allowsHitTesting(false)
        }
    }
}


/// The mini-player's scrubber: the shared ``WaveformView`` fed by the session's own peaks and ribbon, so it needs no editor.
struct MiniPlayerWaveform: View {
    let session: PlaybackSession
    var identifier = "miniPlayer.seek"

    var body: some View {
        let playback = session.playback
        let zoom = playback.zoom
        WaveformView(
            peaks: session.waveformPyramid, loadState: session.waveformLoadState,
            duration: max(playback.duration, session.waveformPeaks?.duration ?? 0),
            segments: session.waveformSegments, bookmarks: session.waveformBookmarks,
            activeSegment: session.waveformActiveIndex, style: .bars, viewport: Bindable(zoom).viewport,
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
                PlayerZoomRegistry.shared.activate(zoom)  // View > Zoom In / Out / Actual Size act on this player while it is hovered
            }
        }
        .opacity(playback.canPlay ? 1 : 0.5)
        .allowsHitTesting(playback.canPlay)
    }
}
