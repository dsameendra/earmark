import AppCore
import DesignSystem
import Foundation
import SwiftUI

/// Built-in presets and preset management (LIVE-AC-08, LIVE-AC-11).
public enum CaptionPresetCatalog {
    /// Stable ids so built-ins survive restarts and the active-preset setting keeps pointing at them.
    public static let subtleID = PresetID(UUID(uuidString: "5B1E0001-0000-4000-8000-000000000001")!)
    public static let presentationID = PresetID(UUID(uuidString: "5B1E0001-0000-4000-8000-000000000002")!)
    public static let highContrastID = PresetID(UUID(uuidString: "5B1E0001-0000-4000-8000-000000000003")!)

    public static let subtle = CaptionPreset(
        id: subtleID, name: "Subtle", fontSize: 22, fontWeight: 0.23, background: .liquidGlass, backgroundOpacity: 0.55,
        cornerRadius: 14, visibleLines: 2, maxWidth: 760, isBuiltIn: true)
    public static let presentation = CaptionPreset(
        id: presentationID, name: "Presentation", fontSize: 40, fontWeight: 0.3, background: .liquidGlass,
        backgroundOpacity: 0.85, cornerRadius: 20, visibleLines: 2, maxWidth: 1200, isBuiltIn: true)
    public static let highContrast = CaptionPreset(
        id: highContrastID, name: "High contrast", fontSize: 32, fontWeight: 0.4, textColorHex: "#FFFFFF",
        background: .solid, backgroundOpacity: 1, cornerRadius: 12, visibleLines: 3, maxWidth: 1000, textOutline: true,
        isBuiltIn: true)

    public static let builtIns: [CaptionPreset] = [subtle, presentation, highContrast]
    public static var defaultPreset: CaptionPreset { subtle }

    public static func isBuiltIn(_ id: PresetID) -> Bool { builtIns.contains { $0.id == id } }

    /// Clamps values to what the overlay can render: 1...6 lines, sane size, opacity 0...1.
    public static func sanitized(_ preset: CaptionPreset) -> CaptionPreset {
        var p = preset
        p.visibleLines = min(6, max(1, p.visibleLines))
        p.fontSize = min(96, max(12, p.fontSize))
        p.backgroundOpacity = min(1, max(0, p.backgroundOpacity))
        p.cornerRadius = min(48, max(0, p.cornerRadius))
        p.maxWidth = max(240, p.maxWidth)
        if let hide = p.autoHideAfterSilence, hide <= 0 { p.autoHideAfterSilence = nil }
        return p
    }
}

public enum CaptionPresetError: Error, Equatable {
    case builtInPresetIsReadOnly
}

/// Merges built-ins with user presets from the `PresetRepository` and remembers the active one.
public actor CaptionPresetStore {
    /// Same literal as `SettingsKey.activeCaptionPreset` in `FeatureSupport` (that package is not a dependency here).
    public static let activePresetKey = "liveCaptions.activePreset"

    private let repository: any PresetRepository
    private let settings: any SettingsStore

    public init(repository: any PresetRepository, settings: any SettingsStore) {
        self.repository = repository
        self.settings = settings
    }

    /// Built-ins first, then user presets (soft-deleted ones and built-in id collisions excluded).
    public func all() async throws -> [CaptionPreset] {
        let user = try await repository.captionPresets().filter {
            $0.deletedAt == nil && !CaptionPresetCatalog.isBuiltIn($0.id)
        }
        return CaptionPresetCatalog.builtIns + user.map { var p = $0; p.isBuiltIn = false; return p }
    }

    /// Save As: always creates a new user preset (also from a built-in).
    @discardableResult
    public func saveAs(_ preset: CaptionPreset, name: String) async throws -> CaptionPreset {
        var copy = CaptionPresetCatalog.sanitized(preset)
        copy.id = PresetID()
        copy.name = name
        copy.isBuiltIn = false
        copy.deletedAt = nil
        try await repository.save(copy)
        return copy
    }

    /// Saves changes to an existing user preset. Built-ins are read-only.
    public func update(_ preset: CaptionPreset) async throws {
        guard !CaptionPresetCatalog.isBuiltIn(preset.id), !preset.isBuiltIn else { throw CaptionPresetError.builtInPresetIsReadOnly }
        var p = CaptionPresetCatalog.sanitized(preset)
        p.isBuiltIn = false
        try await repository.save(p)
    }

    /// Built-ins cannot be deleted (LIVE-AC-11).
    public func delete(_ id: PresetID) async throws {
        guard !CaptionPresetCatalog.isBuiltIn(id) else { throw CaptionPresetError.builtInPresetIsReadOnly }
        try await repository.softDeletePreset(id)
        if await settings.value(for: Self.activePresetKey, as: String.self) == id.description {
            await settings.set(CaptionPresetCatalog.subtleID.description, for: Self.activePresetKey)
        }
    }

    public func activePreset() async throws -> CaptionPreset {
        let presets = try await all()
        if let raw = await settings.value(for: Self.activePresetKey, as: String.self),
            let match = presets.first(where: { $0.id.description == raw })
        {
            return match
        }
        return CaptionPresetCatalog.defaultPreset
    }

    public func setActive(_ id: PresetID) async {
        await settings.set(id.description, for: Self.activePresetKey)
    }
}

/// The three size steps and their line/opacity ranges used by the preset controls (Components board).
public enum CaptionSizeStep: String, CaseIterable, Identifiable, Sendable {
    case small, medium, large, extraLarge
    public var id: String { rawValue }
    public var fontSize: Double {
        switch self {
        case .small: 22
        case .medium: 28
        case .large: 36
        case .extraLarge: 48
        }
    }
    public var title: LocalizedStringKey {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .extraLarge: "Extra large"
        }
    }
    /// Nearest step for an arbitrary font size.
    public static func nearest(to size: Double) -> CaptionSizeStep {
        allCases.min { abs($0.fontSize - size) < abs($1.fontSize - size) } ?? .medium
    }
}

/// Appearance helpers derived from a preset (pure, testable).
public enum CaptionStyle {
    /// Parses `#RRGGBB` or `#RRGGBBAA`; returns `nil` for anything else.
    public static func rgba(fromHex hex: String) -> (r: Double, g: Double, b: Double, a: Double)? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else { return nil }
        let hasAlpha = s.count == 8
        let r = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(value & 0xFF) / 255 : 1
        return (r, g, b, a)
    }

    public static func color(fromHex hex: String) -> Color {
        guard let c = rgba(fromHex: hex) else { return DSColor.primaryText }
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
    }

    /// Maps the preset's `NSFont.Weight`-scale value (-1...1) to a SwiftUI weight.
    public static func weight(for value: Double) -> Font.Weight {
        switch value {
        case ..<(-0.6): .ultraLight
        case ..<(-0.3): .thin
        case ..<(-0.1): .light
        case ..<0.1: .regular
        case ..<0.27: .medium
        case ..<0.35: .semibold
        case ..<0.5: .bold
        case ..<0.7: .heavy
        default: .black
        }
    }

    public static func font(for preset: CaptionPreset) -> Font {
        if let family = preset.fontFamily, !family.isEmpty {
            return .custom(family, size: preset.fontSize).weight(weight(for: preset.fontWeight))
        }
        return .system(size: preset.fontSize, weight: weight(for: preset.fontWeight))
    }

    /// Panel height that fits `visibleLines` lines of text plus padding.
    public static func panelHeight(for preset: CaptionPreset) -> Double {
        let lines = Double(min(6, max(1, preset.visibleLines)))
        let perLine = preset.fontSize * 1.35
        let translation = (preset.showTranslation || preset.translatedOnly) ? perLine * 0.7 * lines : 0
        return (perLine * lines + translation + 28).rounded(.up)
    }
}
