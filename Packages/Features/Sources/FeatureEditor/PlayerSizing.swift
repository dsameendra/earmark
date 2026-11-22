import DesignSystem
import Observation
import SwiftUI

/// Pure sizing rules for the popup player window. Everything is uniform scaling, so the window (and the video letterboxed
/// inside it) keeps its aspect ratio however far the user pinches.
public struct PlayerWindowSizing: Sendable, Equatable {
    public var minSize: CGSize
    public var maxSize: CGSize
    /// One View > Make Player Larger / Smaller step.
    public static let step = 1.2

    public init(minSize: CGSize = CGSize(width: 420, height: 240), maxSize: CGSize = CGSize(width: 1920, height: 1200)) {
        self.minSize = minSize
        self.maxSize = maxSize
    }

    /// Content size after scaling `size` by `factor`, clamped to the min/max (and to `available` when given) without ever
    /// changing the aspect ratio. A size that already sits outside the limits is brought back inside them.
    public func scaled(_ size: CGSize, by factor: Double, available: CGSize? = nil) -> CGSize {
        guard size.width > 0, size.height > 0, factor.isFinite, factor > 0 else { return size }
        var upper = min(maxSize.width / size.width, maxSize.height / size.height)
        if let available, available.width > 0, available.height > 0 {
            upper = min(upper, available.width / size.width, available.height / size.height)
        }
        let lower = max(minSize.width / size.width, minSize.height / size.height)
        let applied = min(max(factor, lower), max(upper, lower))
        return CGSize(width: (size.width * applied).rounded(), height: (size.height * applied).rounded())
    }

    /// A saved window frame made safe for the screens connected now: shrunk to fit the screen it overlaps most (the first one
    /// when none overlaps, as after unplugging a display) and moved fully inside it. `nil` when there are no screens.
    public static func restored(_ frame: CGRect, screens: [CGRect]) -> CGRect? {
        guard let first = screens.first, frame.width > 0, frame.height > 0 else { return nil }
        let screen = screens.max { $0.intersection(frame).area < $1.intersection(frame).area } ?? first
        let target = screen.intersection(frame).area > 0 ? screen : first
        var result = frame
        result.size.width = min(frame.width, target.width)
        result.size.height = min(frame.height, target.height)
        result.origin.x = min(max(result.origin.x, target.minX), target.maxX - result.width)
        result.origin.y = min(max(result.origin.y, target.minY), target.maxY - result.height)
        return result
    }

    /// The frame of `size` plus `extra` (title bar) with the same centre as `old`, nudged back inside `bounds` when given.
    public static func frame(centeredOn old: CGRect, size: CGSize, extra: CGSize = .zero, within bounds: CGRect? = nil) -> CGRect {
        let total = CGSize(width: size.width + extra.width, height: size.height + extra.height)
        var frame = CGRect(x: old.midX - total.width / 2, y: old.midY - total.height / 2, width: total.width, height: total.height)
        if let bounds {
            frame.origin.x = min(max(frame.origin.x, bounds.minX), max(bounds.minX, bounds.maxX - frame.width))
            frame.origin.y = min(max(frame.origin.y, bounds.minY), max(bounds.minY, bounds.maxY - frame.height))
        }
        return frame
    }
}

/// Something View > Make Player Larger / Smaller can resize.
@MainActor
public protocol PlayerResizing: AnyObject {
    func makeLarger()
    func makeSmaller()
}

/// The player the View menu size commands act on: the popup window while it is key, otherwise the hovered mini-player.
@MainActor @Observable
public final class PlayerSizeRegistry {
    public static let shared = PlayerSizeRegistry()
    public private(set) var active: (any PlayerResizing)?

    public init() {}

    public func activate(_ target: any PlayerResizing) { active = target }
    public func deactivate(_ target: any PlayerResizing) { if active === target { active = nil } }
}

/// View > Make Player Larger (⌥⌘+) and Make Player Smaller (⌥⌘−).
public struct PlayerSizeCommands: Commands {
    private let registry: PlayerSizeRegistry

    public init(registry: PlayerSizeRegistry = .shared) { self.registry = registry }

    public var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Make Player Larger") { registry.active?.makeLarger() }
                .keyboardShortcut("+", modifiers: [.command, .option])
                .disabled(registry.active == nil)
            Button("Make Player Smaller") { registry.active?.makeSmaller() }
                .keyboardShortcut("-", modifiers: [.command, .option])
                .disabled(registry.active == nil)
        }
    }
}

// MARK: - Mini-player size

/// Compact, regular and large looks of the in-app mini-player.
public enum MiniPlayerPreset: String, CaseIterable, Sendable {
    case compact, regular, large

    public var scale: Double {
        switch self {
        case .compact: 0.82
        case .regular: 1
        case .large: 1.3
        }
    }

    public var larger: MiniPlayerPreset? {
        switch self {
        case .compact: .regular
        case .regular: .large
        case .large: nil
        }
    }

    public var smaller: MiniPlayerPreset? {
        switch self {
        case .compact: nil
        case .regular: .compact
        case .large: .regular
        }
    }

    /// The preset whose scale is nearest `scale`.
    public static func nearest(to scale: Double) -> MiniPlayerPreset {
        allCases.min { abs($0.scale - scale) < abs($1.scale - scale) } ?? .regular
    }
}

/// Size of the mini-player: continuous while the user pinches, snapped to a preset (and persisted) when the pinch ends.
@MainActor @Observable
public final class MiniPlayerSizeModel: PlayerResizing {
    public static let defaultsKey = "miniPlayer.preset"
    public static let scaleRange: ClosedRange<Double> = MiniPlayerPreset.compact.scale...MiniPlayerPreset.large.scale

    public private(set) var preset: MiniPlayerPreset
    /// Live scale: the preset's scale, or the in-flight pinch value.
    public private(set) var scale: Double
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var pinchStart: Double?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.string(forKey: Self.defaultsKey).flatMap(MiniPlayerPreset.init(rawValue:)) ?? .regular
        preset = saved
        scale = saved.scale
    }

    /// Follows a pinch: `magnification` is the gesture's cumulative value (1 = unchanged).
    public func pinch(magnification: Double) {
        if pinchStart == nil { pinchStart = scale }
        guard magnification.isFinite, magnification > 0 else { return }
        scale = min(max((pinchStart ?? 1) * magnification, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
    }

    /// Ends a pinch: settles on the nearest preset.
    public func endPinch() {
        pinchStart = nil
        set(.nearest(to: scale))
    }

    public func set(_ newPreset: MiniPlayerPreset) {
        preset = newPreset
        scale = newPreset.scale
        defaults.set(newPreset.rawValue, forKey: Self.defaultsKey)
    }

    public func makeLarger() { if let next = preset.larger { set(next) } }
    public func makeSmaller() { if let next = preset.smaller { set(next) } }
}

private extension CGRect {
    /// Zero for a null or empty rectangle.
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
