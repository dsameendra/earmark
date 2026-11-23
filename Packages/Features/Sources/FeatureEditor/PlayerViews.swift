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
            case .absent:
                NoRecordingView()
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

/// Video with drag to pan when scaled up, double-click for 100 %, and Command or Option plus scroll to zoom (50 % to
/// 300 %). The same scale is driven by View > Zoom In / Out / Actual Size while the pointer is over the video.
/// A plain pinch is not handled here: it resizes the popup window (see ``PlayerWindowController``).
private struct VideoPanel: View {
    let model: TranscriptEditorModel
    let player: AVPlayer
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

/// A transcript that never had audio or video (for example a meeting transcribed without recording): informational only.
struct NoRecordingView: View {
    var body: some View {
        VStack(spacing: DSSpacing.sm) {
            Image(systemName: "waveform.slash").font(.title2).foregroundStyle(DSColor.secondaryText)
            Text("No recording").font(DSTypography.headline)
            Text("This transcript was saved without audio or video, so there is nothing to play. It stays fully editable.")
                .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText).multilineTextAlignment(.center)
        }
        .padding(DSSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("editor.noRecording")
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
///
/// Pinching on the window (two-finger pinch out = larger, in = smaller) or View > Make Player Larger / Smaller scales the
/// whole window about its centre, never the video inside it. Scaling is uniform, so the aspect ratio holds, and it is
/// clamped to ``PlayerWindowSizing`` and to the screen. The frame is persisted under ``autosaveName``.
@MainActor
final class PlayerWindowController: NSObject, NSWindowDelegate, PlayerResizing {
    static let defaultAutosaveName = "EarmarkPlayerWindow"

    private var window: NSWindow?
    private let model: TranscriptEditorModel
    private let onRelink: () -> Void
    private let autosaveName: String?
    private let registry: PlayerSizeRegistry
    var sizing = PlayerWindowSizing()
    private var magnifyMonitor: Any?

    init(
        model: TranscriptEditorModel, onRelink: @escaping () -> Void, autosaveName: String? = PlayerWindowController.defaultAutosaveName,
        registry: PlayerSizeRegistry = .shared
    ) {
        self.model = model
        self.onRelink = onRelink
        self.autosaveName = autosaveName
        self.registry = registry
    }

    var currentFrame: NSRect? { window?.frame }

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
        window.setContentSize(NSSize(width: 640, height: 400))  // a content controller can leave the window at the view size
        window.contentMinSize = sizing.minSize
        window.contentMaxSize = sizing.maxSize
        window.animationBehavior = .documentWindow
        window.isReleasedWhenClosed = false
        window.delegate = self
        let restored = autosaveName.map { window.setFrameUsingName($0) } ?? false
        if !restored {
            window.center()
        } else if let safe = PlayerWindowSizing.restored(window.frame, screens: NSScreen.screens.map(\.visibleFrame)), safe != window.frame {
            window.setFrame(safe, display: false)  // saved on a display that is gone, or larger than the screen now
        }
        if let autosaveName { window.setFrameAutosaveName(autosaveName) }
        window.makeKeyAndOrderFront(nil)
        self.window = window
        installMagnifyMonitor()
        if window.isKeyWindow { registry.activate(self) }
    }

    func close() {
        guard let window else { return }
        window.delegate = nil
        removeMagnifyMonitor()
        registry.deactivate(self)
        window.close()
        self.window = nil
        model.playback.isDetached = false
    }

    func windowWillClose(_ notification: Notification) {
        removeMagnifyMonitor()
        registry.deactivate(self)
        window = nil
        model.playback.isDetached = false
    }

    func windowDidBecomeKey(_ notification: Notification) { registry.activate(self) }
    func windowDidResignKey(_ notification: Notification) { registry.deactivate(self) }

    // MARK: Scaling

    func makeLarger() { scale(by: PlayerWindowSizing.step, animated: true) }
    func makeSmaller() { scale(by: 1 / PlayerWindowSizing.step, animated: true) }

    /// Scales the whole window by `factor` about its centre. Pinch events apply it per event without animation (the
    /// trackpad already smooths them); the menu steps animate.
    func scale(by factor: Double, animated: Bool) {
        guard let window else { return }
        let content = window.contentRect(forFrameRect: window.frame).size
        let visible = window.screen?.visibleFrame
        let extra = CGSize(width: window.frame.width - content.width, height: window.frame.height - content.height)
        let available = visible.map { CGSize(width: $0.width - extra.width, height: $0.height - extra.height) }
        let size = sizing.scaled(content, by: factor, available: available)
        guard size != content else { return }
        let frame = PlayerWindowSizing.frame(centeredOn: window.frame, size: size, extra: extra, within: visible)
        window.setFrame(frame, display: true, animate: animated)
    }

    private func installMagnifyMonitor() {
        removeMagnifyMonitor()
        magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handleMagnify(event) ?? false }
            return consumed ? nil : event
        }
    }

    private func removeMagnifyMonitor() {
        if let magnifyMonitor { NSEvent.removeMonitor(magnifyMonitor) }
        magnifyMonitor = nil
    }

    private func handleMagnify(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        scale(by: 1 + Double(event.magnification), animated: false)
        return true
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
