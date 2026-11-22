import AppCore
import DesignSystem
import SwiftUI

// glass-layer: floater (the persistent mini-player; replaces the editor's player dock whenever the editor is not on screen)
/// Compact player shown on every screen while the shared playback session exists and its editor is not showing.
public struct MiniPlayerView: View {
    private let center: PlaybackCenter
    private let onOpenTranscript: (TranscriptID) -> Void

    public init(center: PlaybackCenter, onOpenTranscript: @escaping (TranscriptID) -> Void) {
        self.center = center
        self.onOpenTranscript = onOpenTranscript
    }

    public var body: some View {
        if let session = center.session {
            content(session)
        }
    }

    private func content(_ session: PlaybackSession) -> some View {
        let playback = session.playback
        return HStack(spacing: DSSpacing.md) {
            Button {
                playback.togglePlay()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(DSTypography.headline)
                    .frame(width: 32, height: 32)
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
                Text(session.title).font(DSTypography.headline).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 220, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("Open \(session.title)")
            .accessibilityLabel("Open \(session.title)")
            .accessibilityIdentifier("miniPlayer.title")
            Text(TimeFormat.clock(playback.currentTime)).font(DSTypography.timestamp).monospacedDigit()
                .accessibilityLabel("Playback position")
                .accessibilityValue(String(format: "%.2f", playback.currentTime))
                .accessibilityIdentifier("miniPlayer.position")
            Slider(
                value: Binding(get: { playback.currentTime }, set: { playback.seek(to: $0) }), in: 0...max(playback.duration, 1)
            )
            .accessibilityLabel("Seek").disabled(!playback.canPlay)
            .accessibilityIdentifier("miniPlayer.seek")
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
        .padding(DSSpacing.md)
        .frame(maxWidth: .infinity)
        .dsGlass(.clear, radius: DSRadius.panel)
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
