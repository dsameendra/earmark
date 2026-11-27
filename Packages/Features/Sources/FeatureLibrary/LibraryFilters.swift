import AppCore
import Foundation

/// A Library folder (SCR-018). Kept as an alias so existing call sites read the same.
public typealias LibraryFolder = Folder

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


// MARK: - Grouping

/// How the Library list is grouped (a header per group, collapsible).
public enum LibraryGrouping: String, Codable, Sendable, CaseIterable, Identifiable {
    case none, date, folder, type, language, tag
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .none: "None"
        case .date: "Date"
        case .folder: "Folder"
        case .type: "Type"
        case .language: "Language"
        case .tag: "Tag"
        }
    }
}

public struct LibraryGroup: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var items: [Transcript]
}

/// Pure grouping of an already filtered and sorted list (kept out of the model so tests pin it).
public enum LibraryGrouper {
    public static func groups(
        _ items: [Transcript], by grouping: LibraryGrouping, folders: [Folder], now: Date, calendar: Calendar
    ) -> [LibraryGroup] {
        switch grouping {
        case .none:
            return items.isEmpty ? [] : [LibraryGroup(id: "all", title: "", items: items)]
        case .date:
            let buckets = DateBuckets(now: now, calendar: calendar)
            return ordered(items, key: { buckets.bucket($0.createdAt) })
        case .folder:
            let names = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.name) })
            return ordered(items, key: { item in
                guard let id = item.folderID, let name = names[id] else { return (Int.max, "folder.none", "No folder") }
                return (0, "folder.\(id)", name)
            }, tieBreak: true)
        case .type:
            let rank: [TranscriptSource: Int] = [.meeting: 0, .file: 1, .liveCaptions: 2, .dictation: 3]
            let names: [TranscriptSource: String] = [.meeting: "Meetings", .file: "Files", .liveCaptions: "Live captions", .dictation: "Dictation"]
            return ordered(items, key: { ((rank[$0.source] ?? 9), "type.\($0.source.rawValue)", names[$0.source] ?? $0.source.rawValue) })
        case .language:
            return ordered(items, key: { item in
                guard let code = item.languages.map(\.rawValue).sorted().first else { return (Int.max, "language.none", "Unknown language") }
                return (0, "language.\(code)", Locale.current.localizedString(forLanguageCode: code) ?? code)
            }, tieBreak: true)
        case .tag:
            var buckets: [String: LibraryGroup] = [:]
            var untagged: [Transcript] = []
            for item in items {
                if item.tags.isEmpty { untagged.append(item) }
                for tag in item.tags { buckets["tag.\(tag)", default: LibraryGroup(id: "tag.\(tag)", title: tag, items: [])].items.append(item) }
            }
            var result = buckets.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            if !untagged.isEmpty { result.append(LibraryGroup(id: "tag.none", title: "Untagged", items: untagged)) }
            return result
        }
    }

    /// Today, Yesterday, This week, Last week, This month, Last month; then a group per earlier month of this year, then a group
    /// per earlier year. Boundaries follow the calendar (its first weekday and time zone). The first match wins, so every date
    /// falls in exactly one bucket, and a future date counts as today.
    static func dateBucket(_ date: Date, now: Date, calendar: Calendar) -> (Int, String, String) {
        DateBuckets(now: now, calendar: calendar).bucket(date)
    }

    /// The bucket boundaries for one `now`, computed once and reused for every item (the calendar maths and the month formatter
    /// used to run again for each of thousands of transcripts on every redraw).
    struct DateBuckets {
        let now: Date
        let calendar: Calendar
        let today, yesterday, thisWeek, lastWeek, thisMonth, lastMonth: Date
        let currentYear: Int
        let monthFormatter: DateFormatter

        init(now: Date, calendar: Calendar) {
            self.now = now
            self.calendar = calendar
            today = calendar.startOfDay(for: now)
            yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
            thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
            lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek) ?? thisWeek
            thisMonth = calendar.dateInterval(of: .month, for: now)?.start ?? today
            lastMonth = calendar.date(byAdding: .month, value: -1, to: thisMonth) ?? thisMonth
            currentYear = calendar.component(.year, from: now)
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate("LLLL")
            monthFormatter = formatter
        }

        func bucket(_ date: Date) -> (Int, String, String) {
            if date >= today { return (0, "date.today", "Today") }
            if date >= yesterday { return (1, "date.yesterday", "Yesterday") }
            if date >= thisWeek { return (2, "date.thisWeek", "This week") }
            if date >= lastWeek { return (3, "date.lastWeek", "Last week") }
            if date >= thisMonth { return (4, "date.thisMonth", "This month") }
            if date >= lastMonth { return (5, "date.lastMonth", "Last month") }
            let parts = calendar.dateComponents([.year, .month], from: date)
            let year = parts.year ?? currentYear
            let month = parts.month ?? 1
            if year == currentYear {
                return (100 + (12 - month), "date.month.\(year)-\(month)", monthFormatter.string(from: date))
            }
            return (1000 + (9999 - year), "date.year.\(year)", String(year))
        }
    }

    /// Groups in the order of the rank (then title when `tieBreak`), keeping each group's items in list order.
    private static func ordered(
        _ items: [Transcript], key: (Transcript) -> (Int, String, String), tieBreak: Bool = false
    ) -> [LibraryGroup] {
        var buckets: [String: (rank: Int, group: LibraryGroup)] = [:]
        for item in items {
            let (rank, id, title) = key(item)
            buckets[id, default: (rank, LibraryGroup(id: id, title: title, items: []))].group.items.append(item)
        }
        return buckets.values.sorted {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            return tieBreak ? $0.group.title.localizedCaseInsensitiveCompare($1.group.title) == .orderedAscending : $0.group.id < $1.group.id
        }.map(\.group)
    }
}
