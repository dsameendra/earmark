import DesignSystem
import Observation
import SwiftUI

/// Zoom state of one player, shared by the docked and detached surfaces and by View > Zoom In / Out / Actual Size.
@MainActor @Observable
public final class PlayerZoomModel {
    /// What the menu commands act on: whatever the pointer touched last.
    public enum Target: Sendable { case waveform, video }

    public var viewport = WaveformViewport()
    public private(set) var videoScale = 1.0
    /// Pan of the scaled video, in points.
    public var videoOffset = CGSize.zero
    public var target: Target = .waveform

    public static let videoScaleRange: ClosedRange<Double> = 0.5...3
    /// One menu step: half an octave, so 16x is reached in eight steps.
    public static let waveformStep = 2.0.squareRoot()
    public static let videoStep = 1.25

    public init() {}

    public func setVideoScale(_ scale: Double) {
        videoScale = min(Self.videoScaleRange.upperBound, max(Self.videoScaleRange.lowerBound, scale))
        if videoScale <= 1 { videoOffset = .zero }
    }

    public func zoomIn() {
        switch target {
        case .waveform:
            viewport.zoom(by: Self.waveformStep, anchor: 0.5)
            viewport.follows = true
        case .video: setVideoScale(videoScale * Self.videoStep)
        }
    }

    public func zoomOut() {
        switch target {
        case .waveform:
            viewport.zoom(by: 1 / Self.waveformStep, anchor: 0.5)
            viewport.follows = true
        case .video: setVideoScale(videoScale / Self.videoStep)
        }
    }

    /// Back to the whole recording and the video at 100 %.
    public func actualSize() {
        viewport.reset()
        setVideoScale(1)
        videoOffset = .zero
    }

    public func resetVideo() {
        setVideoScale(1)
        videoOffset = .zero
    }
}

/// The player the View menu commands act on. The editor registers its player while it is on screen.
@MainActor @Observable
public final class PlayerZoomRegistry {
    public static let shared = PlayerZoomRegistry()
    public private(set) var active: PlayerZoomModel?

    public init() {}

    public func activate(_ model: PlayerZoomModel) { active = model }
    public func deactivate(_ model: PlayerZoomModel) { if active === model { active = nil } }
}

/// View > Zoom In (⌘+), Zoom Out (⌘−), Actual Size (⌘0) for the player's waveform, or its video in the detached window.
public struct PlayerZoomCommands: Commands {
    private let registry: PlayerZoomRegistry

    public init(registry: PlayerZoomRegistry = .shared) { self.registry = registry }

    public var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Zoom In") { registry.active?.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(registry.active == nil)
            Button("Zoom Out") { registry.active?.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(registry.active == nil)
            Button("Actual Size") { registry.active?.actualSize() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(registry.active == nil)
        }
    }
}
