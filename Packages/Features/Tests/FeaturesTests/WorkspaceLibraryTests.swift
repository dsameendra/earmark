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
    @Test func dateGroupsComeInTimeOrderAndKeepListOrder() {
        let items = [transcript("a", daysAgo: 0.1), transcript("b", daysAgo: 3), transcript("c", daysAgo: 12), transcript("d", daysAgo: 90), transcript("e", daysAgo: 0.2)]
        let groups = LibraryGrouper.groups(items, by: .date, folders: [], now: now, calendar: .current)
        #expect(groups.map(\.title).count == groups.count)
        let titles = groups.map(\.title)
        #expect(titles.first == "Today" || titles.first == "This week")  // start-of-day dependent, but never reordered
        #expect(groups.flatMap(\.items).count == 5)
        #expect(titles.last == "Older")
        #expect(groups.last?.items.map(\.title) == ["d"])
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
