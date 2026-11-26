import AppCore
import FeatureSupport
import Foundation
import Observation

/// Which Library list a model/view shows.
public enum LibraryMode: Sendable {
    case library
    case recentlyDeleted
}

/// Drives the Library and Recently Deleted lists: full-text search, filters, sort, folders, tags, item actions, retention and
/// missing-media relink.
@MainActor @Observable
public final class LibraryModel {
    public let mode: LibraryMode
    public private(set) var items: [Transcript] = []
    public private(set) var newlyAddedIDs: Set<TranscriptID> = []
    public private(set) var isFollowingJobs = false
    /// Transcripts whose file job is still running (or paused/failed half-way): they open read-only in the live view (SCR-015).
    public private(set) var inProgressIDs: Set<TranscriptID> = []
    @ObservationIgnored private var inProgressByJob: [JobID: TranscriptID] = [:]
    public private(set) var isLoading = true
    public private(set) var errorMessage: String?
    public var searchText = ""
    public var selection: Set<TranscriptID> = []
    public var filters = LibraryFilters()
    public var sort: LibrarySort = .createdDesc {
        didSet {
            guard sort != oldValue, mode == .library, !isRestoringSort else { return }
            let value = sort.rawValue
            let settings = services.settings
            Task { await settings.set(value, for: SettingsKey.librarySort) }
        }
    }
    public private(set) var layout: LibraryLayout = .list
    public private(set) var folders: [Folder] = []
    /// Items per folder (for the folder cards), not narrowed by search or filters.
    public private(set) var folderCounts: [FolderID: Int] = [:]
    public private(set) var grouping: LibraryGrouping = .none
    public private(set) var collapsedGroups: Set<String> = []
    public private(set) var showsFolders = true
    public private(set) var retentionDays = LibraryModel.defaultRetentionDays
    /// Best full-text hit per transcript for the current search (snippet + time).
    public private(set) var snippets: [TranscriptID: SearchHit] = [:]
    public private(set) var mediaStates: [TranscriptID: MediaState] = [:]
    public private(set) var availableTags: [String] = []
    public private(set) var availableSpeakers: [String] = []
    public private(set) var availableLanguages: [LanguageCode] = []

    public static let defaultRetentionDays = 30
    public static let retentionOptions = [7, 14, 30, 60, 90, 0]

    /// Called before transcripts are deleted or purged, so dependents (the shared player) can let go of them.
    @ObservationIgnored public var onTranscriptsRemoved: (@MainActor ([TranscriptID]) -> Void)?
    @ObservationIgnored private var isRestoringSort = false
    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private let transcripts: any TranscriptRepository
    @ObservationIgnored private let access: any MediaAccessing
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private var hasStarted = false

    public init(
        services: AppServices, mode: LibraryMode, mediaAccess: any MediaAccessing = SecurityScopedMediaAccess(),
        now: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .current
    ) {
        self.mode = mode
        self.services = services
        transcripts = services.transcripts
        access = mediaAccess
        self.now = now
        self.calendar = calendar
    }

    private var purger: MediaPurger {
        MediaPurger(
            transcripts: services.transcripts, media: services.media, meetings: services.meetings, roots: services.mediaRoots)
    }

    // MARK: Query

    /// The repository query for the current search, filters and sort. Stable between calls (usable as a task identity).
    public var currentQuery: LibraryQuery {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return LibraryQuery(
            text: trimmed.isEmpty ? nil : trimmed, sources: filters.sources, languages: filters.languages, folderID: filters.folderID,
            tags: filters.tags, dateRange: filters.date.range(now: now(), calendar: calendar),
            durationRange: filters.duration.range, sort: sort, deletedOnly: mode == .recentlyDeleted,
            speakerNames: filters.speakerNames)
    }

    /// Items matching the current search and filters (the repository applies them).
    public var visibleItems: [Transcript] { items }

    /// `true` when a search or filter is narrowing the list (drives "no results" vs "empty library").
    public var isNarrowed: Bool { filters.isActive || !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    public func clearFilters() {
        filters = LibraryFilters()
        searchText = ""
    }

    // MARK: Loading

    /// A completed background job updates the open Library immediately, without polling or reopening the screen.
    public func watchJobCompletions() async {
        let events = services.jobQueue.events()
        isFollowingJobs = true
        defer { isFollowingJobs = false }
        for job in await services.jobQueue.jobs() { trackProgress(of: job) }
        for await event in events {
            guard !Task.isCancelled else { return }
            if case .removed(let id) = event {
                inProgressByJob[id] = nil
                inProgressIDs = Set(inProgressByJob.values)
                continue
            }
            guard case .updated(let job) = event else { continue }
            trackProgress(of: job)
            // A transcript row exists from the moment its job starts: show it in the Library while it fills in.
            if job.state == .running, let id = job.transcriptID, !items.contains(where: { $0.id == id }) { await refresh() }
            guard job.state == .completed else { continue }
            let previous = Set(items.map(\.id))
            await refresh()
            let arrivals = Set(items.map(\.id)).subtracting(previous)
            newlyAddedIDs.formUnion(arrivals)
            if !arrivals.isEmpty {
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(700))
                    self?.newlyAddedIDs.subtract(arrivals)
                }
            }
        }
    }

    private func trackProgress(of job: Job) {
        guard job.kind == .transcribeFile, let id = job.transcriptID else { return }
        let stopped = job.state == .failed || job.state == .cancelled
        let ongoing = job.state == .pending || job.state == .running || job.state == .paused
        // A failed or cancelled re-run of a finished transcript leaves it complete; only first runs stay in progress.
        let partial = stopped && !(job.settings.rerun.map { !$0.replaceEverything } ?? false)
        inProgressByJob[job.id] = (ongoing || partial) ? id : nil
        inProgressIDs = Set(inProgressByJob.values)
    }

    /// First load: restores persisted preferences, applies auto-purge, then loads the list.
    public func start() async {
        let storedLayout = await services.settings.value(for: SettingsKey.libraryLayout, as: String.self)
        if let storedLayout, let value = LibraryLayout(rawValue: storedLayout) { layout = value }
        if mode == .library, let storedSort = await services.settings.value(for: SettingsKey.librarySort, as: String.self),
            let value = LibrarySort(rawValue: storedSort)
        {
            isRestoringSort = true
            sort = value
            isRestoringSort = false
        }
        if let days = await services.settings.value(for: SettingsKey.libraryRetentionDays, as: Int.self) { retentionDays = max(0, days) }
        if let raw = await services.settings.value(for: SettingsKey.libraryGrouping, as: String.self), let value = LibraryGrouping(rawValue: raw) {
            grouping = value
        }
        collapsedGroups = Set(await services.settings.value(for: SettingsKey.libraryCollapsedGroups, as: [String].self) ?? [])
        showsFolders = await services.settings.value(for: SettingsKey.libraryShowFolders, as: Bool.self) ?? true
        await reloadFolders()
        await purgeExpired()
        await reload()
    }

    /// Runs `start()` the first time and `reload()` afterwards (used by the view's query-change task).
    public func refresh() async {
        if hasStarted {
            await reload()
        } else {
            hasStarted = true
            await start()
        }
    }

    /// Reloads the list. A non-empty search uses full-text hits for snippets (LIB-AC-02).
    public func reload() async {
        let query = currentQuery
        do {
            let result = try await transcripts.list(query)
            if let text = query.text {
                let hits = try await transcripts.search(text, limit: 500)
                var best: [TranscriptID: SearchHit] = [:]
                for hit in hits where best[hit.transcriptID] == nil { best[hit.transcriptID] = hit }
                snippets = best
            } else {
                snippets = [:]
            }
            items = result
            selection.formIntersection(Set(result.map(\.id)))
            errorMessage = nil
            await loadFacets(from: result)
        } catch {
            errorMessage = String(describing: error)
        }
        isLoading = false
    }

    private func loadFacets(from current: [Transcript]) async {
        var source = current
        if isNarrowed, let all = try? await transcripts.list(LibraryQuery(deletedOnly: mode == .recentlyDeleted)) { source = all }
        availableTags = Array(Set(source.flatMap(\.tags))).sorted()
        availableSpeakers = Array(Set(source.flatMap { $0.speakers.map(\.name) })).sorted()
        availableLanguages = Array(Set(source.flatMap(\.languages))).sorted()
    }

    // MARK: Layout & retention (LIB-AC-04, LIB-AC-08)

    public func setLayout(_ newValue: LibraryLayout) async {
        layout = newValue
        await services.settings.set(newValue.rawValue, for: SettingsKey.libraryLayout)
    }

    /// Changes the retention period (0 = keep forever) and purges anything now expired.
    public func setRetention(days: Int) async {
        retentionDays = max(0, days)
        await services.settings.set(retentionDays, for: SettingsKey.libraryRetentionDays)
        await purgeExpired()
        if mode == .recentlyDeleted { await reload() }
    }

    /// Permanently removes items deleted longer ago than the retention period (runs at launch / on load).
    @discardableResult
    public func purgeExpired() async -> Int {
        guard retentionDays > 0, let cutoff = calendar.date(byAdding: .day, value: -retentionDays, to: now()) else { return 0 }
        return (try? await purger.purgeDeleted(before: cutoff)) ?? 0
    }

    /// Whole days left before `item` is purged; `nil` when retention is "forever" or the item is not deleted.
    public func daysRemaining(for item: Transcript) -> Int? {
        guard retentionDays > 0, let deletedAt = item.deletedAt else { return nil }
        let elapsed = calendar.dateComponents([.day], from: deletedAt, to: now()).day ?? 0
        return max(0, retentionDays - elapsed)
    }

    // MARK: Item actions (LIB-AC-05, LIB-AC-07, LIB-AC-09)

    public func rename(_ id: TranscriptID, to title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await update(id) { $0.title = trimmed }
    }

    /// Creates a copy (new transcript and segment IDs) titled "<title> copy".
    public func duplicate(_ id: TranscriptID) async {
        do {
            guard var copy = try await transcripts.transcript(id) else { return }
            let segments = try await transcripts.segments(for: id)
            let stamp = now()
            copy.id = TranscriptID()
            copy.title += " copy"
            copy.createdAt = stamp
            copy.modifiedAt = stamp
            copy.deletedAt = nil
            copy.revisionOf = nil
            var fresh = segments
            for index in fresh.indices { fresh[index].id = SegmentID() }
            try await transcripts.save(copy)
            try await transcripts.replaceSegments(fresh, for: copy.id)
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
        await reload()
    }

    public func move(_ ids: [TranscriptID], to folder: FolderID?) async {
        for id in ids { await update(id, reload: false) { $0.folderID = folder } }
        await reload()
    }

    public func addTag(_ tag: String, to ids: [TranscriptID]) async {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        for id in ids {
            await update(id, reload: false) { if !$0.tags.contains(trimmed) { $0.tags.append(trimmed) } }
        }
        await reload()
    }

    public func removeTag(_ tag: String, from ids: [TranscriptID]) async {
        for id in ids { await update(id, reload: false) { $0.tags.removeAll { $0 == tag } } }
        await reload()
    }

    /// Soft-deletes (sets `deletedAt`); items then appear only in Recently Deleted.
    public func delete(_ ids: [TranscriptID]) async {
        onTranscriptsRemoved?(ids)
        await apply { try await $0.softDelete(ids, at: self.now()) }
    }

    public func restore(_ ids: [TranscriptID]) async { await apply { try await $0.restore(ids) } }

    /// Permanently removes transcripts and their library-owned media files and rows. Callers confirm first (LIB-AC-09).
    public func purge(_ ids: [TranscriptID]) async {
        onTranscriptsRemoved?(ids)
        let purger = purger
        await apply { _ in try await purger.purge(ids) }
    }

    /// Permanently removes everything in Recently Deleted.
    public func purgeAll() async { await purge(items.map(\.id)) }

    /// Soft-deletes the selection (Library).
    public func deleteSelected() async { await delete(Array(selection)) }

    /// Restores the selection (Recently Deleted).
    public func restoreSelected() async { await restore(Array(selection)) }

    /// Permanently removes the selection (Recently Deleted).
    public func purgeSelected() async { await purge(Array(selection)) }

    /// Re-transcribes with the transcript's own language(s), queueing a new job against its media (LIB-AC-05).
    public func retranscribe(_ id: TranscriptID) async {
        do {
            guard let item = try await transcripts.transcript(id), let assetID = item.mediaAssetID,
                let asset = try await services.media?.asset(assetID), let bookmark = asset.bookmark,
                let url = access.resolve(bookmark: bookmark)
            else {
                errorMessage = "The media for this transcript can't be found. Relink it first."
                return
            }
            let mode: LanguageMode? =
                item.languages.isEmpty
                ? nil
                : item.languages.count == 1 ? .single(item.languages.first ?? .english) : .multilingual(item.languages)
            var defaults = await FileJobSettings.load(from: services.settings, catalog: services.models.catalog(), languageOverride: mode)
            // SCR-013: merge by time range. Edits, manual ignore flags, speaker names and segment ids survive; the saved
            // "identify speakers" choice is not applied to an existing transcript.
            defaults.diarize = false
            defaults.diarization = [:]
            defaults.rerun = RerunOptions()
            _ = try await services.jobQueue.enqueue(
                Job(kind: .transcribeFile, input: url, transcriptID: id, settings: defaults))
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    // MARK: Folders (SCR-018)

    /// Folders and how many items each holds.
    public func reloadFolders() async {
        folders = (try? await services.workspace.folders.folders()) ?? []
        var counts: [FolderID: Int] = [:]
        for folder in folders { counts[folder.id] = (try? await transcripts.list(LibraryQuery(folderID: folder.id)))?.count ?? 0 }
        folderCounts = counts
    }

    /// Follows folder changes made elsewhere (the sidebar, another window) until cancelled.
    public func watchWorkspace() async {
        let folderChanges = services.workspace.folders.changes()
        let events = services.workspace.events.stream()
        let folderTask = Task { [weak self] in for await _ in folderChanges { await self?.reloadFolders() } }
        defer { folderTask.cancel() }
        for await event in events {
            switch event {
            case .libraryChanged: await refresh()
            case .foldersChanged: await reloadFolders()
            default: break
            }
        }
    }

    @discardableResult
    public func createFolder(named name: String) async -> Folder? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let folder = Folder(name: trimmed, colorIndex: folders.count)
        await saveFolder(folder)
        return folder
    }

    public func renameFolder(_ id: FolderID, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var folder = folders.first(where: { $0.id == id }) else { return }
        folder.name = trimmed
        await saveFolder(folder)
    }

    public func setFolderColor(_ id: FolderID, index: Int) async {
        guard var folder = folders.first(where: { $0.id == id }) else { return }
        folder.colorIndex = index
        await saveFolder(folder)
    }

    /// Deletes a folder; its items move to the Library root.
    public func deleteFolder(_ id: FolderID) async {
        do {
            for member in try await transcripts.list(LibraryQuery(folderID: id)) {
                var moved = member
                moved.folderID = nil
                try await transcripts.save(moved)
            }
            try await services.workspace.folders.delete(id)
        } catch {
            errorMessage = String(describing: error)
        }
        if filters.folderID == id { filters.folderID = nil }
        await reloadFolders()
        services.workspace.events.send(.foldersChanged)
        await reload()
    }

    public func folderName(for id: FolderID?) -> String? { folders.first { $0.id == id }?.name }

    private func saveFolder(_ folder: Folder) async {
        do { try await services.workspace.folders.save(folder) } catch { errorMessage = String(describing: error) }
        await reloadFolders()
        services.workspace.events.send(.foldersChanged)
    }

    // MARK: Pins (SCR-018)

    /// The next pin position: after every pinned folder and transcript.
    private func nextPinOrder() async -> Int {
        var query = LibraryQuery()
        query.pinnedOnly = true
        let pinnedTranscripts = ((try? await transcripts.list(query)) ?? []).compactMap(\.pinOrder)
        let pinnedFolders = ((try? await services.workspace.folders.folders()) ?? []).compactMap(\.pinOrder)
        return (pinnedTranscripts + pinnedFolders).max().map { $0 + 1 } ?? 0
    }

    public func togglePin(folder id: FolderID) async {
        guard var folder = folders.first(where: { $0.id == id }) else { return }
        folder.pinOrder = folder.isPinned ? nil : await nextPinOrder()
        await saveFolder(folder)
    }

    public func togglePin(transcript id: TranscriptID) async {
        let order = await nextPinOrder()
        do {
            guard var item = try await transcripts.transcript(id) else { return }
            item.pinOrder = item.pinOrder == nil ? order : nil  // pinning is not an edit: modifiedAt stays
            try await transcripts.save(item)
        } catch {
            errorMessage = String(describing: error)
        }
        services.workspace.events.send(.libraryChanged)
        await reload()
    }

    // MARK: Grouping

    /// The visible items in groups. `.none` is a single headerless group.
    public var groups: [LibraryGroup] {
        LibraryGrouper.groups(visibleItems, by: grouping, folders: folders, now: now(), calendar: calendar)
    }

    public func setGrouping(_ value: LibraryGrouping) async {
        grouping = value
        await services.settings.set(value.rawValue, for: SettingsKey.libraryGrouping)
    }

    public func isCollapsed(_ group: String) -> Bool { collapsedGroups.contains(group) }

    public func toggleCollapsed(_ group: String) async {
        if collapsedGroups.contains(group) { collapsedGroups.remove(group) } else { collapsedGroups.insert(group) }
        await services.settings.set(collapsedGroups.sorted(), for: SettingsKey.libraryCollapsedGroups)
    }

    /// The folder cards show only at the Library root, with no search or filter narrowing the list.
    public var showsFolderCards: Bool { mode == .library && showsFolders && filters.folderID == nil && !isNarrowed }

    public func openFolder(_ id: FolderID?) { filters.folderID = id }

    // MARK: Missing media (LIB-AC-10)

    /// Checks (once per row, lazily) whether referenced media can still be resolved.
    public func checkMedia(for item: Transcript) async {
        guard let assetID = item.mediaAssetID, mediaStates[item.id] == nil, let media = services.media else { return }
        guard let asset = try? await media.asset(assetID), asset.deletedAt == nil else {
            mediaStates[item.id] = .missing
            return
        }
        if asset.isOwnedByLibrary {
            mediaStates[item.id] = .available
        } else if let bookmark = asset.bookmark, access.resolve(bookmark: bookmark) != nil {
            mediaStates[item.id] = .available
        } else {
            mediaStates[item.id] = .missing
        }
    }

    /// Points the transcript's media asset at a newly chosen file by storing a fresh security-scoped bookmark.
    public func relink(_ item: Transcript, to url: URL) async {
        guard let assetID = item.mediaAssetID, let media = services.media else { return }
        guard let bookmark = access.makeBookmark(for: url) else {
            errorMessage = "Couldn't get access to \(url.lastPathComponent)."
            return
        }
        do {
            var asset = (try await media.asset(assetID)) ?? MediaAsset(id: assetID, kind: .audio, duration: item.duration)
            asset.bookmark = bookmark
            asset.deletedAt = nil
            try await media.save(asset)
            mediaStates[item.id] = .available
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    // MARK: Helpers

    public func dismissError() { errorMessage = nil }

    private func update(_ id: TranscriptID, reload shouldReload: Bool = true, _ change: (inout Transcript) -> Void) async {
        do {
            guard var item = try await transcripts.transcript(id) else { return }
            change(&item)
            item.modifiedAt = now()
            try await transcripts.save(item)
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
        services.workspace.events.send(.libraryChanged)
        if shouldReload { await reload() }
    }

    private func apply(_ change: (any TranscriptRepository) async throws -> Void) async {
        do {
            try await change(transcripts)
            selection = []
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
        services.workspace.events.send(.libraryChanged)
        await reload()
    }
}
