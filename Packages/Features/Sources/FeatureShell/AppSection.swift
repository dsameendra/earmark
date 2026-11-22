import AppCore
import DesignSystem
import FeatureSupport
import Foundation

/// Sidebar sections in display order. ⌘1…⌘6 select by position (NAV-AC-02).
public enum AppSection: String, CaseIterable, Identifiable, Sendable {
    case home, queue, meetings, live, library, recentlyDeleted

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .home: "Home"
        case .queue: "Queue"
        case .meetings: "Meetings"
        case .live: "Live"
        case .library: "Library"
        case .recentlyDeleted: "Recently Deleted"
        }
    }

    /// Duotone symbol for the sidebar row (rule A3; the seam T34 renders).
    public var symbol: DSSymbol {
        switch self {
        case .home: .home
        case .queue: .queue
        case .meetings: .meetings
        case .live: .liveCaptions
        case .library: .library
        case .recentlyDeleted: .recentlyDeleted
        }
    }

    /// Stock SF Symbol fallback of `symbol`, kept for existing call sites.
    public var systemImage: String { symbol.systemImageName }

    /// 1-based keyboard shortcut digit.
    public var shortcutNumber: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    /// The key equivalent character for ⌘1…⌘6.
    public var shortcutKey: Character { Character(String(shortcutNumber)) }

    /// The section selected by ⌘`digit` (1-based); `nil` outside 1...6 (NAV-AC-02).
    public init?(shortcutDigit digit: Int) {
        guard digit >= 1, digit <= Self.allCases.count else { return nil }
        self = Self.allCases[digit - 1]
    }

    /// Stable accessibility identifier of the sidebar row (rule A6).
    public var accessibilityIdentifier: String { "sidebar.\(rawValue)" }
}

/// Persists the last-selected section through `SettingsStore` (NAV-AC-15). Home is the first-launch default (NAV-AC-01).
public struct SectionPersistence: Sendable {
    private let store: any SettingsStore

    public init(store: any SettingsStore) { self.store = store }

    public func load() async -> AppSection {
        guard let raw = await store.value(for: SettingsKey.lastSection, as: String.self), let section = AppSection(rawValue: raw) else {
            return .home
        }
        return section
    }

    public func save(_ section: AppSection) async {
        await store.set(section.rawValue, for: SettingsKey.lastSection)
    }
}
