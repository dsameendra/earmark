import AppCore
import Foundation

// MARK: - Position

public enum OverlayVertical: Int, Sendable, Hashable, CaseIterable { case top, middle, bottom }
public enum OverlayHorizontal: Int, Sendable, Hashable, CaseIterable { case left, center, right }

/// Where the caption overlay sits on its display: one of nine grid cells, or `custom` (set by dragging it).
public enum OverlayPosition: String, Codable, Sendable, Hashable, CaseIterable {
    case topLeft, topCenter, topRight
    case middleLeft, middleCenter, middleRight
    case bottomLeft, bottomCenter, bottomRight
    case custom

    /// The default, and the position the overlay always used before this was configurable.
    public static let `default`: OverlayPosition = .bottomCenter

    /// The nine grid cells in reading order, as three rows of three.
    public static let gridRows: [[OverlayPosition]] = [
        [.topLeft, .topCenter, .topRight],
        [.middleLeft, .middleCenter, .middleRight],
        [.bottomLeft, .bottomCenter, .bottomRight],
    ]

    public init(_ vertical: OverlayVertical, _ horizontal: OverlayHorizontal) {
        self = Self.gridRows[vertical.rawValue][horizontal.rawValue]
    }

    public var vertical: OverlayVertical? {
        switch self {
        case .topLeft, .topCenter, .topRight: .top
        case .middleLeft, .middleCenter, .middleRight: .middle
        case .bottomLeft, .bottomCenter, .bottomRight: .bottom
        case .custom: nil
        }
    }

    public var horizontal: OverlayHorizontal? {
        switch self {
        case .topLeft, .middleLeft, .bottomLeft: .left
        case .topCenter, .middleCenter, .bottomCenter: .center
        case .topRight, .middleRight, .bottomRight: .right
        case .custom: nil
        }
    }

    /// Left/right centre: a tall, narrow column, so lines wrap in a narrower width.
    public var isSideColumn: Bool { self == .middleLeft || self == .middleRight }

    public var title: String {
        switch self {
        case .topLeft: "Top left"
        case .topCenter: "Top centre"
        case .topRight: "Top right"
        case .middleLeft: "Middle left"
        case .middleCenter: "Centre"
        case .middleRight: "Middle right"
        case .bottomLeft: "Bottom left"
        case .bottomCenter: "Bottom centre"
        case .bottomRight: "Bottom right"
        case .custom: "Custom"
        }
    }

    /// Name of the cell glyph for the picker grid (kept here so views never hold symbol strings, rule A3).
    public var systemImage: String {
        switch self {
        case .custom: "hand.draw"
        default: "rectangle.dashed"
        }
    }
}

// MARK: - Display choice

/// Which display the overlay appears on.
public enum DisplayChoice: Sendable, Hashable {
    case main
    /// The display of the frontmost other app's window, else of the mouse.
    case followActive
    case display(UInt32)

    public var rawValue: String {
        switch self {
        case .main: "main"
        case .followActive: "follow"
        case .display(let id): "display:\(id)"
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "main": self = .main
        case "follow": self = .followActive
        default:
            guard rawValue.hasPrefix("display:"), let id = UInt32(rawValue.dropFirst("display:".count)) else { return nil }
            self = .display(id)
        }
    }

    public var specificID: UInt32? {
        if case .display(let id) = self { id } else { nil }
    }
}

// MARK: - Display names

public enum DisplayNaming {
    /// Names for the picker: duplicates get a counter ("Studio Display (2)"); the primary display is tagged "Main".
    public static func names(for displays: [DisplayInfo]) -> [UInt32: String] {
        var totals: [String: Int] = [:]
        for d in displays { totals[d.name, default: 0] += 1 }
        var seen: [String: Int] = [:]
        var result: [UInt32: String] = [:]
        for d in displays {
            seen[d.name, default: 0] += 1
            var label = totals[d.name, default: 1] > 1 ? "\(d.name) (\(seen[d.name] ?? 1))" : d.name
            if d.isPrimary { label += " - Main" }
            result[d.id] = label
        }
        return result
    }
}

// MARK: - Pure placement maths

extension OverlayPlacement {
    /// Gap between the overlay and the visible-frame edge (the visible frame already excludes menu bar, notch area and Dock).
    public static let gridInset: CGFloat = edgeMargin
    /// The bottom row sits higher, clear of an auto-hidden Dock's reveal zone; matches the historic default.
    public static let bottomInset: CGFloat = edgeMargin + 24
    /// Widest the narrow left/right-centre column gets.
    public static let sideColumnMaxWidth: CGFloat = 340
    /// Corners and side columns never take more than this share of the display width.
    public static let cornerWidthShare: CGFloat = 0.5
    public static let sideColumnWidthShare: CGFloat = 0.3

    /// Overlay size for a preset at a position: `maxWidth` capped to the display, narrower for side positions, and
    /// taller for the side columns where lines wrap more.
    public static func size(for preset: CaptionPreset, position: OverlayPosition, on display: DisplayInfo) -> CGSize {
        let visible = display.visibleFrame
        var width = min(preset.maxWidth, visible.width - 2 * edgeMargin)
        var sized = preset
        switch position {
        case .middleLeft, .middleRight:
            let narrow = max(minimumSize.width, min(sideColumnMaxWidth, visible.width * sideColumnWidthShare))
            width = min(width, narrow)
            sized.visibleLines = min(6, preset.visibleLines * 2)
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            width = min(width, max(minimumSize.width, visible.width * cornerWidthShare))
        default:
            break
        }
        return CGSize(width: max(width, minimumSize.width), height: min(CaptionStyle.panelHeight(for: sized), visible.height))
    }

    /// Frame for a grid cell, inside the display's visible frame. `.custom` has no grid frame and falls back to the default.
    public static func frame(for position: OverlayPosition, size: CGSize, in display: DisplayInfo) -> CGRect {
        let visible = display.visibleFrame
        let width = min(size.width, visible.width)
        let height = min(size.height, visible.height)
        let x: CGFloat
        switch position.horizontal ?? .center {
        case .left: x = visible.minX + gridInset
        case .center: x = visible.midX - width / 2
        case .right: x = visible.maxX - gridInset - width
        }
        let y: CGFloat
        switch position.vertical ?? .bottom {
        case .top: y = visible.maxY - gridInset - height
        case .middle: y = visible.midY - height / 2
        case .bottom: y = visible.minY + bottomInset
        }
        return clamp(CGRect(x: x, y: y, width: width, height: height), to: visible)
    }

    /// Picks the display to show on. A specific display that is no longer attached falls back to the main display;
    /// "follow" uses `activeDisplayID` when attached, else the main display.
    public static func resolveTarget(_ choice: DisplayChoice, in displays: [DisplayInfo], activeDisplayID: UInt32?) -> DisplayInfo? {
        let main = displays.first(where: \.isPrimary) ?? displays.first
        switch choice {
        case .main: return main
        case .followActive: return activeDisplayID.flatMap { id in displays.first { $0.id == id } } ?? main
        case .display(let id): return displays.first { $0.id == id } ?? main
        }
    }
}

// MARK: - Persistence

/// The overlay's display choice, per-display position and per-display, per-preset custom frames, in `SettingsStore`.
/// Keys are mirrored in `FeatureSupport.SettingsKey` (and checked by a test).
public struct OverlayLayoutStore: Sendable {
    public static let displayChoiceKey = "liveCaptions.overlayDisplayChoice"
    /// Position for "Main display" / "Follow the active window", which have no fixed display.
    public static let sharedPositionKey = "liveCaptions.overlayPosition"
    public static func positionKey(display id: UInt32) -> String { "liveCaptions.overlayPosition.\(id)" }
    public static func customFrameKey(display id: UInt32, preset: PresetID) -> String {
        "liveCaptions.overlayCustomFrame.\(id).\(preset.rawValue.uuidString)"
    }

    private let settings: any SettingsStore
    public init(settings: any SettingsStore) { self.settings = settings }

    public func displayChoice() async -> DisplayChoice {
        guard let raw = await settings.value(for: Self.displayChoiceKey, as: String.self) else { return .main }
        return DisplayChoice(rawValue: raw) ?? .main
    }

    public func setDisplayChoice(_ choice: DisplayChoice) async {
        await settings.set(choice.rawValue, for: Self.displayChoiceKey)
    }

    /// The stored position for the scope of `choice` (a specific display, else the shared scope), or nil when never set.
    public func storedPosition(for choice: DisplayChoice) async -> OverlayPosition? {
        let key = choice.specificID.map { Self.positionKey(display: $0) } ?? Self.sharedPositionKey
        guard let raw = await settings.value(for: key, as: String.self) else { return nil }
        return OverlayPosition(rawValue: raw)
    }

    public func setPosition(_ position: OverlayPosition, for choice: DisplayChoice) async {
        let key = choice.specificID.map { Self.positionKey(display: $0) } ?? Self.sharedPositionKey
        await settings.set(position.rawValue, for: key)
    }

    public func customFrame(display id: UInt32, preset: PresetID) async -> StoredOverlayFrame? {
        guard let f = await settings.value(for: Self.customFrameKey(display: id, preset: preset), as: StoredOverlayFrame.self),
            f.width > 0, f.height > 0
        else { return nil }
        return f
    }

    public func setCustomFrame(_ frame: StoredOverlayFrame, display id: UInt32, preset: PresetID) async {
        await settings.set(frame, for: Self.customFrameKey(display: id, preset: preset))
    }

    /// `SettingsStore` has no delete, so a cleared frame is stored as an empty one, which reads back as nil.
    public func clearCustomFrame(display id: UInt32, preset: PresetID) async {
        await settings.set(StoredOverlayFrame(x: 0, y: 0, width: 0, height: 0), for: Self.customFrameKey(display: id, preset: preset))
    }
}

extension OverlayFrameStore {
    public func clearFrame(for displayID: UInt32) async {
        await settings.set(StoredOverlayFrame(x: 0, y: 0, width: 0, height: 0), for: Self.frameKey(display: displayID))
    }
}

/// What the Settings scene needs from the live overlay: re-place it after a change, preview it without a session.
@MainActor
public protocol OverlayPlacementControlling: AnyObject, Sendable {
    /// Re-reads the saved layout and moves the overlay (live, or the test caption) right away.
    /// A non-nil `previewing` preset starts the test caption when no overlay is showing, so a change is always visible.
    func placementDidChange(previewing preset: CaptionPreset?) async
    func showTestCaption(preset: CaptionPreset) async
    func hideTestCaption() async
    var isTestCaptionActive: Bool { get }
    func setClickThrough(_ enabled: Bool) async
    /// Called when the user drags the overlay, so Settings can refresh its pickers.
    var onLayoutChange: (@MainActor () -> Void)? { get set }
}
