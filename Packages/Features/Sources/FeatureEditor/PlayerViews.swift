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

/// The player area: video, or the large waveform for audio-only media in the detached window, or the media-missing state
/// (EDIT-AC-16, 19).
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
                    VideoPanel(model: model, player: engine.player)
                } else {
                    EditorWaveformView(model: model, identifier: "editor.player.waveform")
                        .frame(minHeight: 80)
                        .padding(DSSpacing.lg)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Color.black.opacity(playback.isVideo ? 1 : 0))
        .background(DSColor.solidChrome)
        .dsAnimation(.glide, value: playback.mediaState)
    }
}

/// Video with pinch to scale (50 % to 300 %), drag to pan when scaled up, double-click for 100 %, and Command or Option
/// plus scroll to zoom. The same scale is driven by View > Zoom In / Out / Actual Size while the pointer is over the video.
private struct VideoPanel: View {
    let model: TranscriptEditorModel
    let player: AVPlayer
    @State private var magnifyStart: Double?
    @State private var panStart: CGSize?

    var body: some View {
        let zoom = model.playback.zoom
        GeometryReader { proxy in
            VideoSurface(player: player)
                .scaleEffect(zoom.videoScale)
                .offset(Self.clamped(zoom.videoOffset, scale: zoom.videoScale, in: proxy.size))
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .overlay {
                    Color.clear.contentShape(Rectangle())
                        .gesture(
                            MagnifyGesture()
                                .onChanged { value in
                                    if magnifyStart == nil { magnifyStart = zoom.videoScale }
                                    zoom.setVideoScale((magnifyStart ?? 1) * value.magnification)
                                }
                                .onEnded { _ in magnifyStart = nil }
                        )
                        .simultaneousGesture(
                            DragGesture()
                                .onChanged { value in
                                    guard zoom.videoScale > 1 else { return }
                                    if panStart == nil { panStart = zoom.videoOffset }
                                    let start = panStart ?? .zero
                                    zoom.videoOffset = Self.clamped(
                                        CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height),
                                        scale: zoom.videoScale, in: proxy.size)
                                }
                                .onEnded { _ in panStart = nil }
                        )
                        .onTapGesture(count: 2) { zoom.resetVideo() }
                }
                .onHover { if $0 { zoom.target = .video } }
                .background(
                    ScrollWheelCatcher { delta, _, modifiers in
                        if modifiers.contains(.command) || modifiers.contains(.option) {
                            zoom.setVideoScale(zoom.videoScale * exp(Double(delta.height) * 0.01))
                            return true
                        }
                        guard zoom.videoScale > 1 else { return false }
                        zoom.videoOffset = Self.clamped(
                            CGSize(width: zoom.videoOffset.width + delta.width, height: zoom.videoOffset.height + delta.height),
                            scale: zoom.videoScale, in: proxy.size)
                        return true
                    }
                )
                .accessibilityAction(named: "Zoom in") { zoom.setVideoScale(zoom.videoScale * PlayerZoomModel.videoStep) }
                .accessibilityAction(named: "Zoom out") { zoom.setVideoScale(zoom.videoScale / PlayerZoomModel.videoStep) }
                .accessibilityAction(named: "Actual size") { zoom.resetVideo() }
                .accessibilityIdentifier("editor.player.video")
        }
    }

    /// Keeps the scaled video from being dragged entirely out of view.
    static func clamped(_ offset: CGSize, scale: Double, in size: CGSize) -> CGSize {
        guard scale > 1 else { return .zero }
        let limitX = size.width * CGFloat(scale - 1) / 2
        let limitY = size.height * CGFloat(scale - 1) / 2
        return CGSize(width: min(limitX, max(-limitX, offset.width)), height: min(limitY, max(-limitY, offset.height)))
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

// glass-layer: floater (the one floating player dock; transcript and inspector are solid)
/// Floating player dock; shortcuts, rate, waveform and detachment share the existing playback model.
struct TransportBar: View {
    let model: TranscriptEditorModel
    /// False in the detached audio window, where the large waveform above already scrubs.
    var inlineWaveform = true

    var body: some View {
        let playback = model.playback
        VStack(spacing: DSSpacing.sm) {
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
                .buttonStyle(DSPressButtonStyle()).disabled(!playback.canPlay)
                .accessibilityLabel(playback.isPlaying ? "Pause" : "Play").help("Play/Pause (Space or K)")
                .accessibilityValue(playback.isPlaying ? "Playing" : "Paused")
                .accessibilityIdentifier("editor.player.play")
                Text(TimeFormat.clock(playback.currentTime)).font(DSTypography.timestamp).monospacedDigit()
                    .accessibilityLabel("Playback position")
                    .accessibilityValue(String(format: "%.2f", playback.currentTime))
                    .accessibilityIdentifier("editor.player.position")
                if inlineWaveform {
                    EditorWaveformView(model: model).frame(minWidth: 120, minHeight: 44, maxHeight: 44)
                } else {
                    Spacer(minLength: 0)
                }
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
        .frame(maxWidth: .infinity)
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
        let host = NSHostingController(rootView: content)
        // The window, not the SwiftUI content, owns its size: resizing stays smooth and never snaps to an ideal size.
        host.sizingOptions = []
        window.contentViewController = host
        window.minSize = NSSize(width: 420, height: 240)
        window.animationBehavior = .documentWindow
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
        model.playback.isDetached = false
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
            TransportBar(model: model, inlineWaveform: model.playback.isVideo)
        }
        .frame(minWidth: 420, minHeight: 240)
        .background(PlaybackKeyboardCapture(playback: model.playback).allowsHitTesting(false))
        .background(DSColor.paper)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor.detachedPlayer")
    }
}
