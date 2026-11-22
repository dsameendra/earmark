import AppCore
import AppKit
import Foundation

/// One attached display. `id` is the `CGDirectDisplayID` (`NSScreenNumber`).
public struct DisplayInfo: Sendable, Hashable {
    public var id: UInt32
    public var frame: CGRect
    /// Frame minus menu bar / notch safe area and Dock.
    public var visibleFrame: CGRect
    public var isPrimary: Bool
    /// Localised display name (for example "Studio Display"), shown in Settings.
    public var name: String
    public init(id: UInt32, frame: CGRect, visibleFrame: CGRect? = nil, isPrimary: Bool = false, name: String = "Display") {
        self.id = id
        self.name = name
        self.frame = frame
        self.visibleFrame = visibleFrame ?? frame
        self.isPrimary = isPrimary
    }
}

/// Supplies the current displays; the system implementation reads `NSScreen`, tests pass fixed lists.
@MainActor
public protocol DisplayProviding: Sendable {
    func displays() -> [DisplayInfo]
    /// The display holding the frontmost other app's window, else the mouse (nil when unknown).
    func activeDisplayID() -> UInt32?
}

extension DisplayProviding {
    public func activeDisplayID() -> UInt32? { nil }
}

@MainActor
public struct SystemDisplayProvider: DisplayProviding {
    public init() {}
    public func displays() -> [DisplayInfo] {
        NSScreen.screens.enumerated().compactMap { index, screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return DisplayInfo(
                id: number.uint32Value, frame: screen.frame, visibleFrame: screen.visibleFrame, isPrimary: index == 0,
                name: screen.localizedName)
        }
    }

    public func activeDisplayID() -> UInt32? {
        let list = displays()
        if let rect = Self.frontmostWindowRect(), let id = OverlayPlacement.displayID(containing: CGPoint(x: rect.midX, y: rect.midY), in: list) {
            return id
        }
        return OverlayPlacement.displayID(containing: NSEvent.mouseLocation, in: list)
    }

    /// Frame (AppKit coordinates) of the front-most on-screen window of the frontmost app, unless that app is this one.
    private static func frontmostWindowRect() -> CGRect? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
            let primaryHeight = NSScreen.screens.first?.frame.height,
            let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for window in info {
            guard (window[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier,
                (window[kCGWindowLayer as String] as? Int) == 0,
                let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDict), bounds.width > 40, bounds.height > 40
            else { continue }
            return OverlayPlacement.appKitRect(fromGlobalDisplayRect: bounds, primaryHeight: primaryHeight)
        }
        return nil
    }
}

/// Overlay frame relative to its display's origin, so it survives display rearrangement.
public struct StoredOverlayFrame: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Pure snap / clamp / restore math (LIVE-AC-03). All coordinates are AppKit screen coordinates.
public enum OverlayPlacement {
    public static let snapThreshold: CGFloat = 12
    public static let edgeMargin: CGFloat = 24
    public static let minimumSize = CGSize(width: 240, height: 56)

    /// Snaps each edge to the matching `bounds` edge when within `threshold` points.
    public static func snap(_ rect: CGRect, within bounds: CGRect, threshold: CGFloat = snapThreshold) -> CGRect {
        var r = rect
        if abs(r.minX - bounds.minX) <= threshold {
            r.origin.x = bounds.minX
        } else if abs(r.maxX - bounds.maxX) <= threshold {
            r.origin.x = bounds.maxX - r.width
        }
        if abs(r.minY - bounds.minY) <= threshold {
            r.origin.y = bounds.minY
        } else if abs(r.maxY - bounds.maxY) <= threshold {
            r.origin.y = bounds.maxY - r.height
        }
        return r
    }

    /// Keeps the rect fully inside `bounds` (shrinking only if it cannot fit).
    public static func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        var r = rect
        r.size.width = min(max(r.width, minimumSize.width), bounds.width)
        r.size.height = min(max(r.height, minimumSize.height), bounds.height)
        r.origin.x = min(max(r.minX, bounds.minX), bounds.maxX - r.width)
        r.origin.y = min(max(r.minY, bounds.minY), bounds.maxY - r.height)
        return r
    }

    /// Default placement: centred horizontally near the bottom of the visible frame.
    public static func defaultFrame(size: CGSize, in visibleFrame: CGRect) -> CGRect {
        let width = min(size.width, visibleFrame.width - 2 * edgeMargin)
        let height = min(size.height, visibleFrame.height)
        return CGRect(
            x: visibleFrame.midX - width / 2, y: visibleFrame.minY + edgeMargin + 24, width: max(width, minimumSize.width),
            height: height)
    }

    /// Resizes keeping the horizontal centre and the bottom edge (used when the preset changes size).
    public static func resized(_ rect: CGRect, to size: CGSize, within bounds: CGRect) -> CGRect {
        let r = CGRect(x: rect.midX - size.width / 2, y: rect.minY, width: size.width, height: size.height)
        return clamp(r, to: bounds)
    }

    public static func store(_ rect: CGRect, on display: DisplayInfo) -> StoredOverlayFrame {
        StoredOverlayFrame(
            x: rect.minX - display.frame.minX, y: rect.minY - display.frame.minY, width: rect.width, height: rect.height)
    }

    public static func restore(_ stored: StoredOverlayFrame, on display: DisplayInfo) -> CGRect {
        let r = CGRect(
            x: display.frame.minX + stored.x, y: display.frame.minY + stored.y, width: stored.width, height: stored.height)
        return clamp(r, to: display.visibleFrame)
    }

    /// The display holding most of `rect` (ties and no overlap fall back to the primary display).
    public static func display(containing rect: CGRect, in displays: [DisplayInfo]) -> DisplayInfo? {
        var best: (DisplayInfo, CGFloat)?
        for d in displays {
            let i = d.frame.intersection(rect)
            let area = i.isNull ? 0 : i.width * i.height
            if area > (best?.1 ?? 0) { best = (d, area) }
        }
        return best?.0 ?? displays.first(where: \.isPrimary) ?? displays.first
    }

    /// Chooses the display to show on: the preferred one if still attached, else the primary (hot-plug safe).
    /// The display whose frame contains `point` (AppKit coordinates).
    public static func displayID(containing point: CGPoint, in displays: [DisplayInfo]) -> UInt32? {
        displays.first { $0.frame.contains(point) }?.id
    }

    /// Converts a Core Graphics global display rect (origin top-left of the primary display, y down) to AppKit coordinates.
    public static func appKitRect(fromGlobalDisplayRect r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    public static func resolveDisplay(preferred id: UInt32?, in displays: [DisplayInfo]) -> DisplayInfo? {
        if let id, let match = displays.first(where: { $0.id == id }) { return match }
        return displays.first(where: \.isPrimary) ?? displays.first
    }
}

/// Per-display frame memory backed by `SettingsStore` (keyed by display ID).
public struct OverlayFrameStore: Sendable {
    public static let lastDisplayKey = "liveCaptions.overlayDisplay"
    public static func frameKey(display id: UInt32) -> String { "liveCaptions.overlayFrame.\(id)" }

    let settings: any SettingsStore
    public init(settings: any SettingsStore) { self.settings = settings }

    /// A cleared frame is stored with zero size (the store has no delete) and reads back as nil.
    public func frame(for displayID: UInt32) async -> StoredOverlayFrame? {
        guard let f = await settings.value(for: Self.frameKey(display: displayID), as: StoredOverlayFrame.self), f.width > 0,
            f.height > 0
        else { return nil }
        return f
    }

    public func save(_ frame: StoredOverlayFrame, for displayID: UInt32) async {
        await settings.set(frame, for: Self.frameKey(display: displayID))
        await settings.set(Int(displayID), for: Self.lastDisplayKey)
    }

    public func lastDisplayID() async -> UInt32? {
        await settings.value(for: Self.lastDisplayKey, as: Int.self).map { UInt32(truncatingIfNeeded: $0) }
    }
}
