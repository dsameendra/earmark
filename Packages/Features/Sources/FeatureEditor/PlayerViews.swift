import AVKit
import AppCore
import AppKit
import DesignSystem
import SwiftUI

/// `AVPlayerView` without its own controls (the transport bar drives playback).
struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// The player area: video, or the waveform for audio-only media, or the media-missing state (EDIT-AC-16, 19).
struct PlayerPanelView: View {
    let model: TranscriptEditorModel
    var onRelink: () -> Void

    var body: some View {
        let playback = model.playback
        Group {
            switch playback.mediaState {
            case .loading:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .missing:
                MediaMissingView(onRelink: onRelink)
            case .ready(let isVideo):
                if isVideo, let engine = playback.engine as? AVPlayerEngine {
                    VideoSurface(player: engine.player)
                } else {
                    VStack {
                        if model.showWaveform {
                            WaveformScrubber(model: model).frame(minHeight: 70)
                        } else {
                            DSIcon(.waveform).font(.largeTitle).foregroundStyle(DSColor.secondaryText)
                        }
                    }
                    .padding(DSSpacing.md)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Color.black.opacity(playback.isVideo ? 1 : 0))
        .background(DSColor.solidChrome)
    }
}

struct MediaMissingView: View {
    var onRelink: () -> Void
    var body: some View {
        VStack(spacing: DSSpacing.sm) {
            Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(DSColor.warning)
            Text("Media file not found").font(DSTypography.headline)
            Text("Playback is unavailable, but the transcript stays editable.")
                .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText).multilineTextAlignment(.center)
            Button("Relink…", action: onRelink)
        }
        .padding(DSSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Waveform with speaker-coloured regions behind it, bookmarks and the playhead; click or drag to seek (EDIT-AC-16).
struct WaveformScrubber: View {
    let model: TranscriptEditorModel

    var body: some View {
        let playback = model.playback
        let duration = max(playback.duration, model.waveform?.duration ?? 0, 0.001)
        GeometryReader { proxy in
            ZStack {
                WaveformBackdrop(model: model, duration: duration)
                PlayheadOverlay(playback: playback, duration: duration)
            }
            .background(DSColor.contentBackground, in: RoundedRectangle(cornerRadius: DSRadius.small))
            .overlay(RoundedRectangle(cornerRadius: DSRadius.small).stroke(DSColor.hairline))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    guard playback.canPlay else { return }
                    let fraction = min(1, max(0, value.location.x / max(1, proxy.size.width)))
                    playback.seek(to: fraction * duration)
                }
            )
        }
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityAdjustableAction { direction in
            playback.skip(by: direction == .increment ? 5 : -5)
        }
    }
}

/// Speaker regions, waveform and bookmarks. Does not read the playhead, so it redraws only when the document changes.
private struct WaveformBackdrop: View {
    let model: TranscriptEditorModel
    let duration: TimeInterval

    var body: some View {
        let regions = model.speakerRegions
        let colors = Dictionary(
            uniqueKeysWithValues: model.speakers.map { ($0.id, EditorColors.color(model.color(for: $0.id))) })
        let peaks = model.waveform?.peaks ?? []
        let marks = model.bookmarks.map(\.time)
        Canvas { context, size in
            for region in regions {
                let rect = CGRect(
                    x: region.start / duration * size.width, y: 0, width: max(1, (region.end - region.start) / duration * size.width),
                    height: size.height)
                let color = region.speakerID.flatMap { colors[$0] } ?? Color.gray
                context.fill(Path(rect), with: .color(color.opacity(0.22)))
            }
            if !peaks.isEmpty {
                let barWidth = size.width / CGFloat(peaks.count)
                for (index, peak) in peaks.enumerated() {
                    let height = max(1, CGFloat(peak) * size.height * 0.9)
                    let rect = CGRect(
                        x: CGFloat(index) * barWidth, y: (size.height - height) / 2, width: max(1, barWidth - 0.5), height: height)
                    context.fill(Path(rect), with: .color(.secondary))
                }
            }
            for time in marks {
                let x = time / duration * size.width
                context.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(DSColor.accent))
            }
        }
    }
}

/// The only scrubber view that reads `currentTime` (about 30 Hz).
private struct PlayheadOverlay: View {
    let playback: PlaybackModel
    let duration: TimeInterval

    var body: some View {
        let time = playback.currentTime
        Canvas { context, size in
            let x = time / duration * size.width
            context.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(DSColor.accent))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// glass-layer: floater (the one floating player dock; transcript and inspector are solid)
/// Floating player dock; shortcuts, rate, waveform and detachment share the existing playback model.
struct TransportBar: View {
    let model: TranscriptEditorModel

    var body: some View {
        let playback = model.playback
        VStack(spacing: DSSpacing.sm) {
            if model.showWaveform && playback.canPlay && !playback.isVideo {
                WaveformScrubber(model: model).frame(height: 30)
            }
            HStack(spacing: DSSpacing.md) {
                Button {
                    playback.togglePlay()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(DSTypography.headline)
                        .frame(width: 40, height: 40)
                        .foregroundStyle(DSColor.primaryText)
                        .background(DSColor.accentTint, in: Circle())
                }
                .buttonStyle(.plain).disabled(!playback.canPlay)
                .accessibilityLabel(playback.isPlaying ? "Pause" : "Play").help("Play/Pause (Space or K)")
                .accessibilityIdentifier("editor.player.play")
                Text(TimeFormat.clock(playback.currentTime)).font(DSTypography.timestamp).monospacedDigit()
                Slider(value: Binding(get: { playback.currentTime }, set: { playback.seek(to: $0) }), in: 0...max(playback.duration, 1))
                    .accessibilityLabel("Seek").disabled(!playback.canPlay)
                    .accessibilityIdentifier("editor.player.seek")
                Text(TimeFormat.clock(playback.duration)).font(DSTypography.timestamp).foregroundStyle(DSColor.secondaryText)
                Menu {
                    ForEach(PlaybackSpeed.steps, id: \.self) { speed in
                        Button(speedLabel(speed)) { model.setPlaybackSpeed(speed) }
                    }
                } label: {
                    Text(speedLabel(playback.speed)).monospacedDigit()
                }
                .menuStyle(.borderlessButton).fixedSize().help("Playback speed")
                .accessibilityIdentifier("editor.player.speed")
                Menu("Player options", systemImage: "ellipsis") {
                    Button("Back 15 seconds") { playback.skip(by: -PlaybackShortcut.longSkip) }
                    Button("Back 5 seconds") { playback.skip(by: -PlaybackShortcut.shortSkip) }
                    Button("Forward 5 seconds") { playback.skip(by: PlaybackShortcut.shortSkip) }
                    Button("Forward 15 seconds") { playback.skip(by: PlaybackShortcut.longSkip) }
                    Divider()
                    Toggle("Show waveform", isOn: Binding(get: { model.showWaveform }, set: { model.setShowWaveform($0) }))
                    Button(playback.isDetached ? "Dock player" : "Detach player") { playback.isDetached.toggle() }
                }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityIdentifier("editor.player.options")
            }
        }
        .buttonStyle(.borderless)
        .padding(DSSpacing.md)
        .frame(maxWidth: 840)
        .dsGlass(.clear, radius: DSRadius.panel)
        .accessibilityLabel("Player")
    }

    private func speedLabel(_ speed: Double) -> String {
        speed == speed.rounded() ? "\(Int(speed))×" : String(format: "%g×", speed)
    }
}

/// Hosts the player in its own window; the same `PlaybackModel` drives it, so seeking and highlighting stay in sync
/// across windows (EDIT-AC-17).
@MainActor
final class PlayerWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: TranscriptEditorModel
    private let onRelink: () -> Void

    init(model: TranscriptEditorModel, onRelink: @escaping () -> Void) {
        self.model = model
        self.onRelink = onRelink
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let content = DetachedPlayerView(model: model, onRelink: onRelink)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = model.transcript?.title ?? "Player"
        window.contentViewController = NSHostingController(rootView: content)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func close() {
        guard let window else { return }
        window.delegate = nil
        window.close()
        self.window = nil
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        model.playback.isDetached = false
    }
}

struct DetachedPlayerView: View {
    let model: TranscriptEditorModel
    var onRelink: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            PlayerPanelView(model: model, onRelink: onRelink)
            TransportBar(model: model)
        }
        .frame(minWidth: 420, minHeight: 240)
    }
}
