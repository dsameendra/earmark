import AppCore
import FeatureLibrary
import FeatureShell
import FeatureSupport
import Foundation
import Testing

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func transcript(_ title: String, source: TranscriptSource = .file, daysAgo: Double = 0, folder: FolderID? = nil, tags: [String] = [], language: String = "en") -> Transcript {
    let date = now.addingTimeInterval(-daysAgo * 86400)
    return Transcript(
        title: title, source: source, languages: [LanguageCode(language)], tags: tags, folderID: folder, createdAt: date, modifiedAt: date)
}

@Suite("Library grouping")
struct LibraryGroupingTests {
    /// A fixed calendar so the buckets do not depend on the machine: Gregorian, UTC, weeks start on Monday.
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        calendar.firstWeekday = 2
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    private static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        Self.calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min)) ?? Date()
    }

    private static func bucket(_ date: Date, now: Date) -> String {
        let groups = LibraryGrouper.groups(
            [Transcript(title: "t", source: .file, createdAt: date, modifiedAt: date)], by: .date, folders: [], now: now, calendar: calendar)
        return groups.first?.title ?? "?"
    }

    @Test func datesFallInTodayYesterdayThisWeekLastWeekThisMonthLastMonth() {
        // Thursday 19 November 2026, mid-afternoon.
        let now = Self.date(2026, 11, 19, 15)
        #expect(Self.bucket(Self.date(2026, 11, 19, 0, 0), now: now) == "Today")  // midnight belongs to the new day
        #expect(Self.bucket(Self.date(2026, 11, 18, 23, 59), now: now) == "Yesterday")
        #expect(Self.bucket(Self.date(2026, 11, 17, 9), now: now) == "This week")  // Tuesday
        #expect(Self.bucket(Self.date(2026, 11, 16, 0, 0), now: now) == "This week")  // Monday 00:00 starts the week
        #expect(Self.bucket(Self.date(2026, 11, 15, 23, 59), now: now) == "Last week")  // Sunday
        #expect(Self.bucket(Self.date(2026, 11, 9, 0, 0), now: now) == "Last week")
        #expect(Self.bucket(Self.date(2026, 11, 8, 23, 59), now: now) == "This month")
        #expect(Self.bucket(Self.date(2026, 11, 1, 0, 0), now: now) == "This month")
        #expect(Self.bucket(Self.date(2026, 10, 31, 23, 59), now: now) == "Last month")
        #expect(Self.bucket(Self.date(2026, 10, 1, 0, 0), now: now) == "Last month")
        #expect(Self.bucket(Self.date(2026, 9, 30, 23, 59), now: now) == "September")
        #expect(Self.bucket(Self.date(2026, 1, 1, 0, 0), now: now) == "January")
        #expect(Self.bucket(Self.date(2025, 12, 31, 23, 59), now: now) == "2025")
        #expect(Self.bucket(Self.date(2019, 6, 1), now: now) == "2019")
        #expect(Self.bucket(Self.date(2026, 11, 25), now: now) == "Today")  // a future date (clock skew) counts as today
    }

    @Test func aWeekThatStartsInTheLastMonthStillCountsAsThisWeek() {
        // Wednesday 2 December 2026: the week began on Monday 30 November, in the previous month.
        let now = Self.date(2026, 12, 2, 10)
        #expect(Self.bucket(Self.date(2026, 11, 30, 8), now: now) == "This week")
        #expect(Self.bucket(Self.date(2026, 11, 29, 8), now: now) == "Last week")
        #expect(Self.bucket(Self.date(2026, 11, 20, 8), now: now) == "Last month")
        #expect(Self.bucket(Self.date(2026, 10, 20, 8), now: now) == "October")
    }

    @Test func aSundayStartCalendarMovesTheWeekBoundary() {
        var sunday = Self.calendar
        sunday.firstWeekday = 1
        let now = Self.date(2026, 11, 19, 15)  // Thursday; this week began on Sunday the 15th
        let groups = LibraryGrouper.groups(
            [Transcript(title: "t", source: .file, createdAt: Self.date(2026, 11, 15, 10), modifiedAt: Self.date(2026, 11, 15, 10))],
            by: .date, folders: [], now: now, calendar: sunday)
        #expect(groups.first?.title == "This week")
    }

    @Test func dateGroupsComeNewestFirstAndEmptyOnesAreHidden() {
        let now = Self.date(2026, 11, 19, 15)
        let items = [
            Transcript(title: "old", source: .file, createdAt: Self.date(2024, 3, 3), modifiedAt: Self.date(2024, 3, 3)),
            Transcript(title: "today", source: .file, createdAt: Self.date(2026, 11, 19, 9), modifiedAt: Self.date(2026, 11, 19, 9)),
            Transcript(title: "march", source: .file, createdAt: Self.date(2026, 3, 3), modifiedAt: Self.date(2026, 3, 3)),
            Transcript(title: "june", source: .file, createdAt: Self.date(2026, 6, 3), modifiedAt: Self.date(2026, 6, 3)),
            Transcript(title: "older", source: .file, createdAt: Self.date(2022, 1, 1), modifiedAt: Self.date(2022, 1, 1)),
        ]
        let groups = LibraryGrouper.groups(items, by: .date, folders: [], now: now, calendar: Self.calendar)
        #expect(groups.map(\.title) == ["Today", "June", "March", "2024", "2022"])
    }

    @Test func folderGroupsPutUnfiledLast() {
        let physics = Folder(name: "Physics")
        let work = Folder(name: "Work")
        let items = [transcript("x"), transcript("p1", folder: physics.id), transcript("w1", folder: work.id), transcript("p2", folder: physics.id)]
        let groups = LibraryGrouper.groups(items, by: .folder, folders: [work, physics], now: now, calendar: .current)
        #expect(groups.map(\.title) == ["Physics", "Work", "No folder"])
        #expect(groups[0].items.map(\.title) == ["p1", "p2"])
    }

    @Test func typeAndTagGroups() {
        let items = [transcript("f", source: .file, tags: ["x", "y"]), transcript("m", source: .meeting), transcript("l", source: .liveCaptions, tags: ["x"])]
        let byType = LibraryGrouper.groups(items, by: .type, folders: [], now: now, calendar: .current)
        #expect(byType.map(\.title) == ["Meetings", "Files", "Live captions"])
        let byTag = LibraryGrouper.groups(items, by: .tag, folders: [], now: now, calendar: .current)
        #expect(byTag.map(\.title) == ["x", "y", "Untagged"])
        #expect(byTag[0].items.map(\.title) == ["f", "l"])  // a transcript is listed under every one of its tags
    }

    @Test func noneIsOneHeaderlessGroupAndEmptyIsNoGroups() {
        #expect(LibraryGrouper.groups([transcript("a")], by: .none, folders: [], now: now, calendar: .current).count == 1)
        #expect(LibraryGrouper.groups([], by: .tag, folders: [], now: now, calendar: .current).isEmpty)
    }
}

@MainActor
@Suite("Folders and pins")
struct FoldersAndPinsTests {
    private func make(_ items: [Transcript] = [], folders: [Folder] = []) -> (LibraryModel, AppServices) {
        var services = AppServices.preview(transcripts: items)
        services.workspace.folders = InMemoryFolders(items: folders)
        return (LibraryModel(services: services, mode: .library, now: { now }), services)
    }

    @Test func foldersAreCreatedRenamedColouredAndCounted() async {
        let t = transcript("a")
        let (library, _) = make([t])
        await library.start()
        let folder = await library.createFolder(named: "  Physics 201 ")
        #expect(folder?.name == "Physics 201")
        #expect(await library.createFolder(named: "   ") == nil)
        let id = try! #require(folder).id
        await library.renameFolder(id, to: "Physics")
        await library.setFolderColor(id, index: 3)
        #expect(library.folders.first?.name == "Physics" && library.folders.first?.colorIndex == 3)
        await library.move([t.id], to: id)
        await library.reloadFolders()
        #expect(library.folderCounts[id] == 1)
    }

    @Test func pinningFoldersAndTranscriptsSharesOneOrder() async throws {
        let t = transcript("a")
        let folder = Folder(name: "F")
        let (library, services) = make([t], folders: [folder])
        await library.start()
        await library.togglePin(folder: folder.id)
        await library.togglePin(transcript: t.id)
        let pinnedFolder = try #require(await services.workspace.folders.folders().first)
        let pinnedTranscript = try #require(await services.transcripts.transcript(t.id))
        #expect(pinnedFolder.pinOrder == 0 && pinnedTranscript.pinOrder == 1)
        #expect(pinnedTranscript.modifiedAt == t.modifiedAt)  // pinning is not an edit
        await library.togglePin(folder: folder.id)
        #expect(try await services.workspace.folders.folders().first?.pinOrder == nil)
    }

    @Test func groupingAndCollapsedGroupsAreRemembered() async {
        let (library, services) = make([transcript("a")])
        await library.start()
        await library.setGrouping(.type)
        await library.toggleCollapsed("type.file")
        #expect(library.grouping == .type && library.isCollapsed("type.file"))
        let again = LibraryModel(services: services, mode: .library, now: { now })
        await again.start()
        #expect(again.grouping == .type && again.isCollapsed("type.file"))
    }

    @Test func folderCardsShowOnlyAtTheRootWithoutSearch() async {
        let (library, _) = make([transcript("a")], folders: [Folder(name: "F")])
        await library.start()
        #expect(library.showsFolderCards)
        library.searchText = "x"
        #expect(!library.showsFolderCards)
        library.searchText = ""
        library.openFolder(library.folders[0].id)
        #expect(!library.showsFolderCards)
    }

    @Test func sidebarListsPinnedItemsInOrderAndCanReorderAndUnpin() async throws {
        var a = transcript("A")
        a.pinOrder = 0
        let folder = Folder(name: "Folder", pinOrder: 1)
        var services = AppServices.preview(transcripts: [a])
        services.workspace.folders = InMemoryFolders(items: [folder])
        let sidebar = SidebarModel(services: services)
        await sidebar.reloadPinned()
        #expect(sidebar.pinned.map(\.title) == ["A", "Folder"])
        await sidebar.movePinned("folder-\(folder.id)", before: "transcript-\(a.id)")
        #expect(sidebar.pinned.map(\.title) == ["Folder", "A"])
        await sidebar.movePinned("folder-\(folder.id)", by: 1)
        #expect(sidebar.pinned.map(\.title) == ["A", "Folder"])
        await sidebar.unpin(try #require(sidebar.pinned.first))
        #expect(sidebar.pinned.map(\.title) == ["Folder"])
        #expect(try await services.transcripts.transcript(a.id)?.pinOrder == nil)
    }

    @Test func droppingOnTheSidebarPinsAtTheEndOrBeforeARow() async throws {
        var a = transcript("A")
        a.pinOrder = 0
        let b = transcript("B"), c = transcript("C")
        let folder = Folder(name: "Folder")
        var services = AppServices.preview(transcripts: [a, b, c])
        services.workspace.folders = InMemoryFolders(items: [folder])
        let sidebar = SidebarModel(services: services)
        await sidebar.reloadPinned()
        await sidebar.pin(transcripts: [b.id])  // dropped on the empty sidebar: pinned at the end
        #expect(sidebar.pinned.map(\.title) == ["A", "B"])
        await sidebar.pin(folder: folder.id, before: "transcript-\(a.id)")  // dropped on a row: placed before it
        #expect(sidebar.pinned.map(\.title) == ["Folder", "A", "B"])
        await sidebar.pin(transcripts: [c.id, b.id])  // already pinned items are left where they are
        #expect(sidebar.pinned.map(\.title) == ["Folder", "A", "B", "C"])
        #expect(try await services.transcripts.transcript(c.id)?.modifiedAt == c.modifiedAt)  // pinning is not an edit
    }

    @Test func sidebarHidesPinnedItemsWhenTheSettingIsOff() async {
        var a = transcript("A")
        a.pinOrder = 0
        let services = AppServices.preview(transcripts: [a])
        await services.settings.set(false, for: SettingsKey.sidebarShowPinned)
        let sidebar = SidebarModel(services: services)
        await sidebar.reloadPinned()
        #expect(sidebar.pinned.isEmpty && !sidebar.showsPinned)
    }
}
