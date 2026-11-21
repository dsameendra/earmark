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
                            Image(systemName: "waveform").font(.largeTitle).foregroundStyle(DSColor.secondaryText)
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
        let regions = SpeakerRegions.make(from: model.segments)
        let colors = Dictionary(
            uniqueKeysWithValues: model.speakers.map { ($0.id, EditorColors.color(model.color(for: $0.id))) })
        GeometryReader { proxy in
        Canvas { context, size in
            for region in regions {
                let rect = CGRect(
                    x: region.start / duration * size.width, y: 0, width: max(1, (region.end - region.start) / duration * size.width),
                    height: size.height)
                let color = region.speakerID.flatMap { colors[$0] } ?? Color.gray
                context.fill(Path(rect), with: .color(color.opacity(0.22)))
            }
            if let peaks = model.waveform?.peaks, !peaks.isEmpty {
                let barWidth = size.width / CGFloat(peaks.count)
                for (index, peak) in peaks.enumerated() {
                    let height = max(1, CGFloat(peak) * size.height * 0.9)
                    let rect = CGRect(
                        x: CGFloat(index) * barWidth, y: (size.height - height) / 2, width: max(1, barWidth - 0.5), height: height)
                    context.fill(Path(rect), with: .color(.secondary))
                }
            }
            for bookmark in model.bookmarks {
                let x = bookmark.time / duration * size.width
                context.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(.orange))
            }
            let x = playback.currentTime / duration * size.width
            context.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(.accentColor))
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
        .accessibilityValue(TimeFormat.clock(playback.currentTime))
        .accessibilityAdjustableAction { direction in
            playback.skip(by: direction == .increment ? 5 : -5)
        }
    }
}

/// Play/pause, skips, time, speed, waveform toggle, detach (EDIT-AC-05, 17, 19).
struct TransportBar: View {
    let model: TranscriptEditorModel

    var body: some View {
        let playback = model.playback
        HStack(spacing: DSSpacing.sm) {
            Button { playback.skip(by: -PlaybackShortcut.longSkip) } label: { Image(systemName: "gobackward.15") }
                .help("Back 15 seconds")
            Button { playback.skip(by: -PlaybackShortcut.shortSkip) } label: { Image(systemName: "gobackward.5") }
                .help("Back 5 seconds (J or ←)")
            Button { playback.togglePlay() } label: { Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill") }
                .help("Play/Pause (Space or K)")
            Button { playback.skip(by: PlaybackShortcut.shortSkip) } label: { Image(systemName: "goforward.5") }
                .help("Forward 5 seconds (L or →)")
            Button { playback.skip(by: PlaybackShortcut.longSkip) } label: { Image(systemName: "goforward.15") }
                .help("Forward 15 seconds")
            Text("\(TimeFormat.clock(playback.currentTime)) / \(TimeFormat.clock(playback.duration))")
                .font(DSTypography.timestamp).foregroundStyle(DSColor.secondaryText)
            if playback.canPlay, !playback.isVideo || playback.isDetached == false {
                Slider(
                    value: Binding(get: { playback.currentTime }, set: { playback.seek(to: $0) }),
                    in: 0...max(playback.duration, 1)
                )
                .controlSize(.small)
                .accessibilityLabel("Seek")
            } else {
                Spacer()
            }
            Menu {
                ForEach(PlaybackSpeed.steps, id: \.self) { speed in
                    Button { model.setPlaybackSpeed(speed) } label: {
                        if speed == playback.speed { Label(speedLabel(speed), systemImage: "checkmark") } else { Text(speedLabel(speed)) }
                    }
                }
            } label: {
                Text(speedLabel(playback.speed)).monospacedDigit()
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Playback speed")
            Toggle(isOn: Binding(get: { model.showWaveform }, set: { model.setShowWaveform($0) })) {
                Image(systemName: "waveform")
            }
            .toggleStyle(.button).help("Show waveform")
            Button { playback.isDetached.toggle() } label: {
                Image(systemName: playback.isDetached ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle")
            }
            .help(playback.isDetached ? "Dock player" : "Detach player")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, DSSpacing.md)
        .padding(.vertical, DSSpacing.xs)
        .background(DSColor.solidChrome)
        .overlay(alignment: .top) { Divider() }
        .opacity(playback.canPlay ? 1 : 0.6)
        .allowsHitTesting(playback.canPlay)
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
