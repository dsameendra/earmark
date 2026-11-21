import AppCore
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

    public var systemImage: String {
        switch self {
        case .home: "house"
        case .queue: "tray.full"
        case .meetings: "person.2.wave.2"
        case .live: "captions.bubble"
        case .library: "books.vertical"
        case .recentlyDeleted: "trash"
        }
    }

    /// 1-based keyboard shortcut digit.
    public var shortcutNumber: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }
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
