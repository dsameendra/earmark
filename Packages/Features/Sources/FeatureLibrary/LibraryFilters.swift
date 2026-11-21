import AppCore
import Foundation

/// A Library folder. Folders have no repository: only `Transcript.folderID` exists in the domain, so names live in settings.
public struct LibraryFolder: Codable, Sendable, Hashable, Identifiable {
    public var id: FolderID
    public var name: String
    public init(id: FolderID = FolderID(), name: String) {
        self.id = id
        self.name = name
    }
}

public enum LibraryLayout: String, Codable, Sendable, CaseIterable {
    case list, grid
}

public enum DatePreset: String, Sendable, CaseIterable, Identifiable {
    case any, today, last7Days, last30Days, lastYear
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .any: "Any time"
        case .today: "Today"
        case .last7Days: "Last 7 days"
        case .last30Days: "Last 30 days"
        case .lastYear: "Last year"
        }
    }

    /// Deterministic within a day (anchored to the start of today) so it is stable as a task identity.
    func range(now: Date, calendar: Calendar) -> ClosedRange<Date>? {
        let startOfToday = calendar.startOfDay(for: now)
        let days: Int
        switch self {
        case .any: return nil
        case .today: days = 0
        case .last7Days: days = 6
        case .last30Days: days = 29
        case .lastYear: days = 364
        }
        guard let lower = calendar.date(byAdding: .day, value: -days, to: startOfToday) else { return nil }
        return lower...Date.distantFuture
    }
}

public enum DurationPreset: String, Sendable, CaseIterable, Identifiable {
    case any, under5Minutes, fiveToThirty, thirtyToSixty, overHour
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .any: "Any length"
        case .under5Minutes: "Under 5 min"
        case .fiveToThirty: "5 to 30 min"
        case .thirtyToSixty: "30 to 60 min"
        case .overHour: "Over 1 hour"
        }
    }
    var range: ClosedRange<TimeInterval>? {
        switch self {
        case .any: nil
        case .under5Minutes: 0...300
        case .fiveToThirty: 300...1800
        case .thirtyToSixty: 1800...3600
        case .overHour: 3600...TimeInterval.greatestFiniteMagnitude
        }
    }
}

/// The user-selected Library filters (LIB-AC-01). Empty sets and `.any` presets mean "no filter".
public struct LibraryFilters: Equatable, Sendable {
    public var sources: Set<TranscriptSource> = []
    public var languages: Set<LanguageCode> = []
    public var date: DatePreset = .any
    public var duration: DurationPreset = .any
    public var speakerNames: Set<String> = []
    public var tags: Set<String> = []
    public var folderID: FolderID?

    public init() {}

    public var isActive: Bool { self != LibraryFilters() }

    /// Number of active filter groups, for the filter badge.
    public var activeCount: Int {
        [!sources.isEmpty, !languages.isEmpty, date != .any, duration != .any, !speakerNames.isEmpty, !tags.isEmpty, folderID != nil]
            .filter { $0 }.count
    }
}
