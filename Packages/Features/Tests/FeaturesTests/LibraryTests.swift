import AppCore
import FeatureLibrary
import FeatureSupport
import Foundation
import Testing

private struct FakeMediaAccess: MediaAccessing {
    var resolvable: Set<Data> = []
    func resolve(bookmark: Data) -> URL? { resolvable.contains(bookmark) ? URL(fileURLWithPath: "/tmp/found.m4a") : nil }
    func makeBookmark(for url: URL) -> Data? { Data(url.lastPathComponent.utf8) }
}

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

private func item(
    _ title: String, source: TranscriptSource = .file, duration: TimeInterval = 60, languages: Set<LanguageCode> = ["en"],
    speakers: [String] = [], tags: [String] = [], folder: FolderID? = nil, created: Date = epoch, deleted: Date? = nil
) -> Transcript {
    Transcript(
        title: title, source: source, duration: duration, languages: languages,
        speakers: speakers.map { Speaker(name: $0, colorHex: "#000000") }, tags: tags, folderID: folder, createdAt: created,
        modifiedAt: created, deletedAt: deleted)
}

@MainActor private func makeModel(
    _ items: [Transcript], mode: LibraryMode = .library, segments: [TranscriptID: [Segment]] = [:],
    store: InMemorySettingsStore = InMemorySettingsStore(), media: InMemoryMedia? = nil, access: FakeMediaAccess = FakeMediaAccess(),
    folders: [Folder] = []
) -> (LibraryModel, InMemoryTranscripts) {
    let repo = InMemoryTranscripts(items: items, segments: segments)
    var services = AppServices.preview()
    services.workspace.folders = InMemoryFolders(items: folders)
    services.transcripts = repo
    services.settings = store
    services.media = media
    return (LibraryModel(services: services, mode: mode, mediaAccess: access, now: { epoch }, calendar: .current), repo)
}

@Suite @MainActor struct LibraryModelTests {
    @Test func filtersByEveryDimension() async {  // LIB-AC-01
        let folder = FolderID()
        let a = item("a", source: .file, duration: 120, languages: ["en"], speakers: ["Ann"], tags: ["x"], folder: folder)
        let b = item("b", source: .meeting, duration: 2400, languages: ["si"], speakers: ["Bob"], tags: ["y"])
        let c = item("c", source: .dictation, duration: 4000, languages: ["en"], created: epoch.addingTimeInterval(-86400 * 40))
        let (library, _) = makeModel([a, b, c])
        await library.start()
        #expect(library.items.count == 3)
        library.filters.sources = [.meeting]
        await library.reload()
        #expect(library.items.map(\.title) == ["b"])
        library.filters = LibraryFilters()
        library.filters.languages = ["en"]
        await library.reload()
        #expect(Set(library.items.map(\.title)) == ["a", "c"])
        library.filters = LibraryFilters()
        library.filters.speakerNames = ["Bob"]  // SCR-001
        await library.reload()
        #expect(library.items.map(\.title) == ["b"])
        library.filters = LibraryFilters()
        library.filters.tags = ["x"]
        await library.reload()
        #expect(library.items.map(\.title) == ["a"])
        library.filters = LibraryFilters()
        library.filters.folderID = folder
        await library.reload()
        #expect(library.items.map(\.title) == ["a"])
        library.filters = LibraryFilters()
        library.filters.duration = .overHour
        await library.reload()
        #expect(library.items.map(\.title) == ["c"])
        library.filters = LibraryFilters()
        library.filters.date = .last30Days
        await library.reload()
        #expect(Set(library.items.map(\.title)) == ["a", "b"])
        #expect(library.isNarrowed)
        library.clearFilters()
        await library.reload()
        #expect(library.items.count == 3 && !library.isNarrowed)
    }

    @Test func sortChangesOrder() async {  // LIB-AC-01
        let a = item("beta", duration: 99, created: epoch)
        let b = item("alpha", duration: 10, created: epoch.addingTimeInterval(-100))
        let (library, _) = makeModel([a, b])
        library.sort = .titleAsc
        await library.reload()
        #expect(library.items.map(\.title) == ["alpha", "beta"])
        library.sort = .durationDesc
        await library.reload()
        #expect(library.items.map(\.title) == ["beta", "alpha"])
        library.sort = .createdDesc
        await library.reload()
        #expect(library.items.map(\.title) == ["beta", "alpha"])
        library.sort = .createdAsc
        await library.reload()
        #expect(library.items.map(\.title) == ["alpha", "beta"])
    }

    @Test func searchProvidesSnippetsAndTime() async {  // LIB-AC-02
        let a = item("Untitled")
        let segment = Segment(start: 12, end: 14, text: "the budget review is next week")
        let (library, _) = makeModel([a, item("Other")], segments: [a.id: [segment]])
        library.searchText = "budget"
        await library.reload()
        #expect(library.items.map(\.id) == [a.id])
        #expect(library.snippets[a.id]?.time == 12)
        #expect(library.snippets[a.id]?.snippet.contains("budget") == true)
        library.searchText = "zzz"
        await library.reload()
        #expect(library.items.isEmpty && library.isNarrowed)  // no-results state with reset
    }

    @Test func layoutChoiceIsPersisted() async {  // LIB-AC-04
        let store = InMemorySettingsStore()
        let (first, _) = makeModel([], store: store)
        await first.setLayout(.grid)
        let (second, _) = makeModel([], store: store)
        await second.start()
        #expect(second.layout == .grid)
    }

    @Test func renameDuplicateMoveTag() async throws {  // LIB-AC-05
        let original = item("Interview")
        let segment = Segment(start: 0, end: 1, text: "hello")
        let (library, repo) = makeModel([original], segments: [original.id: [segment]])
        await library.start()
        await library.rename(original.id, to: "  Interview 2  ")
        #expect(try await repo.transcript(original.id)?.title == "Interview 2")
        await library.duplicate(original.id)
        #expect(library.items.count == 2)
        let copy = library.items.first { $0.id != original.id }
        #expect(copy?.title == "Interview 2 copy")
        let copied = try await repo.segments(for: copy?.id ?? original.id)
        #expect(copied.count == 1 && copied[0].id != segment.id)
        #expect(try await repo.segments(for: original.id).first?.id == segment.id)  // original untouched
        let folder = await library.createFolder(named: "Work")
        await library.move([original.id], to: folder?.id)
        #expect(try await repo.transcript(original.id)?.folderID == folder?.id)
        await library.addTag("project", to: [original.id])
        await library.addTag("project", to: [original.id])
        #expect(try await repo.transcript(original.id)?.tags == ["project"])
        #expect(library.availableTags == ["project"])
        await library.removeTag("project", from: [original.id])
        #expect(try await repo.transcript(original.id)?.tags.isEmpty == true)
    }

    @Test func softDeleteRestoreAndPermanentDelete() async throws {  // LIB-AC-07, LIB-AC-09
        let doomed = item("Doomed")
        let store = InMemorySettingsStore()
        var services = AppServices.preview()
        let repo = InMemoryTranscripts(items: [doomed])
        services.transcripts = repo
        services.settings = store
        let library = LibraryModel(services: services, mode: .library, now: { epoch })
        let trash = LibraryModel(services: services, mode: .recentlyDeleted, now: { epoch })
        await library.start()
        await library.delete([doomed.id])
        #expect(library.items.isEmpty)
        await trash.start()
        #expect(trash.items.map(\.id) == [doomed.id])
        await trash.restore([doomed.id])
        await library.reload()
        #expect(library.items.map(\.id) == [doomed.id])
        await library.delete([doomed.id])
        trash.selection = [doomed.id]
        await trash.reload()
        await trash.purgeSelected()
        #expect(trash.items.isEmpty)
        #expect(try await repo.transcript(doomed.id) == nil)
    }

    @Test func autoPurgeUsesRetentionSetting() async throws {  // LIB-AC-08
        let old = item("old", deleted: epoch.addingTimeInterval(-86400 * 40))
        let recent = item("recent", deleted: epoch.addingTimeInterval(-86400 * 5))
        let (trash, repo) = makeModel([old, recent], mode: .recentlyDeleted)
        await trash.start()  // default retention 30 days
        #expect(trash.items.map(\.title) == ["recent"])
        #expect(trash.daysRemaining(for: recent) == 25)
        #expect(try await repo.transcript(old.id) == nil)
        await trash.setRetention(days: 3)
        #expect(trash.items.isEmpty)
        let (keep, _) = makeModel([old], mode: .recentlyDeleted)
        await keep.setRetention(days: 0)  // forever
        await keep.start()
        #expect(keep.items.count == 1 && keep.daysRemaining(for: old) == nil)
    }

    @Test func deletingFolderMovesItemsToRoot() async throws {  // folder deleted -> Library root
        let folder = Folder(name: "Temp")
        let member = item("member", folder: folder.id)
        let (library, repo) = makeModel([member], folders: [folder])
        await library.start()
        #expect(library.folders == [folder])
        await library.deleteFolder(folder.id)
        #expect(try await repo.transcript(member.id)?.folderID == nil)
        #expect(library.folders.isEmpty)
    }

    @Test func missingMediaIsDetectedAndRelinked() async throws {  // LIB-AC-10
        let assetID = MediaAssetID()
        let transcript = Transcript(title: "Talk", source: .file, mediaAssetID: assetID)
        let media = InMemoryMedia(items: [MediaAsset(id: assetID, kind: .audio, bookmark: Data("old".utf8))])
        let (library, _) = makeModel([transcript], media: media, access: FakeMediaAccess(resolvable: [Data("new.m4a".utf8)]))
        await library.start()
        await library.checkMedia(for: transcript)
        #expect(library.mediaStates[transcript.id] == .missing)
        #expect(library.items.count == 1)  // transcript stays viewable
        await library.relink(transcript, to: URL(fileURLWithPath: "/Users/me/new.m4a"))
        #expect(library.mediaStates[transcript.id] == .available)
        #expect(try await media.asset(assetID)?.bookmark == Data("new.m4a".utf8))
    }

    @Test func libraryOwnedMediaIsNeverMissing() async {
        let assetID = MediaAssetID()
        let transcript = Transcript(title: "Rec", source: .meeting, mediaAssetID: assetID)
        let media = InMemoryMedia(items: [MediaAsset(id: assetID, kind: .audio, libraryRelativePath: "r.m4a", isOwnedByLibrary: true)])
        let (library, _) = makeModel([transcript], media: media)
        await library.checkMedia(for: transcript)
        #expect(library.mediaStates[transcript.id] == .available)
    }

    @Test func permanentDeleteRemovesLibraryOwnedMediaRow() async throws {  // LIB-AC-09
        let assetID = MediaAssetID()
        let transcript = Transcript(title: "Rec", source: .meeting, mediaAssetID: assetID, deletedAt: epoch)
        let media = InMemoryMedia(items: [MediaAsset(id: assetID, kind: .audio, isOwnedByLibrary: true)])
        let (trash, _) = makeModel([transcript], mode: .recentlyDeleted, media: media)
        await trash.purge([transcript.id])
        #expect(try await media.asset(assetID)?.deletedAt != nil)
    }

    @Test func retranscribeQueuesJobAgainstResolvedMedia() async {  // LIB-AC-05
        let assetID = MediaAssetID()
        let transcript = Transcript(title: "Talk", source: .file, languages: ["si"], mediaAssetID: assetID)
        let media = InMemoryMedia(items: [MediaAsset(id: assetID, kind: .audio, bookmark: Data("ok".utf8))])
        let queue = PlaceholderJobQueue()
        var services = AppServices.preview()
        services.transcripts = InMemoryTranscripts(items: [transcript])
        services.media = media
        services.jobQueue = queue
        let library = LibraryModel(services: services, mode: .library, mediaAccess: FakeMediaAccess(resolvable: [Data("ok".utf8)]))
        await library.retranscribe(transcript.id)
        let jobs = await queue.jobs()
        #expect(jobs.count == 1 && jobs[0].transcriptID == transcript.id && jobs[0].settings.languageMode == .single(.sinhala))
    }

    @Test func libraryRetranscribeMergesInsteadOfWipingAndDoesNotAddSpeakerWork() async {
        let assetID = MediaAssetID()
        let transcript = Transcript(title: "Talk", source: .file, languages: [.english], mediaAssetID: assetID)
        let media = InMemoryMedia(items: [MediaAsset(id: assetID, kind: .audio, bookmark: Data("ok".utf8))])
        let queue = PlaceholderJobQueue()
        let store = InMemorySettingsStore()
        await store.set(true, for: SettingsKey.filesDiarize)
        var services = AppServices.preview()
        services.transcripts = InMemoryTranscripts(items: [transcript])
        services.media = media
        services.jobQueue = queue
        services.settings = store
        let library = LibraryModel(services: services, mode: .library, mediaAccess: FakeMediaAccess(resolvable: [Data("ok".utf8)]))
        await library.retranscribe(transcript.id)
        let job = await queue.jobs().first
        #expect(job?.settings.rerun == RerunOptions())
        #expect(job?.settings.rerun?.replaceEverything == false)
        #expect(job?.settings.diarize == false)
    }

    @Test func emptyAndErrorStatesDriveFromModel() async {
        let (empty, _) = makeModel([])
        #expect(empty.isLoading)
        await empty.start()
        #expect(!empty.isLoading && empty.items.isEmpty && !empty.isNarrowed && empty.errorMessage == nil)
    }
}
