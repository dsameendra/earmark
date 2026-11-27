import AppCore
import FeatureEditor
import FeatureHome
import FeatureLibrary
import FeatureLive
import FeatureMeetings
import FeatureQueue
import FeatureSupport
import Foundation
import Observation
import SwiftUI

/// Shell state: sidebar selection (persisted), quick open, file import and drop handling.
@MainActor @Observable
public final class ShellModel {
    public private(set) var selection: AppSection = .home
    public var isQuickOpenPresented = false
    /// Changes when a search command should focus the single Library search field.
    public private(set) var librarySearchFocusToken = 0
    /// The transcript currently open in the editor (replaces the section detail until closed).
    public var openedTranscript: TranscriptID?
    public var isImporterPresented = false
    public private(set) var errorMessage: String?

    public let home: HomeModel
    public let queue: QueueModel
    public let meetings: MeetingsModel
    public let live: LiveModel
    public let library: LibraryModel
    public let recentlyDeleted: LibraryModel
    public let quickOpen: QuickOpenModel
    public let sidebar: SidebarModel
    /// The one app-wide playback session (editor player and mini-player).
    public let playback = PlaybackCenter()

    /// Window width as last measured; drives ``layout``.
    public private(set) var windowWidth: CGFloat = 1440

    @ObservationIgnored public let services: AppServices
    @ObservationIgnored private let persistence: SectionPersistence

    public init(services: AppServices) {
        self.services = services
        persistence = SectionPersistence(store: services.settings)
        home = HomeModel(services: services)
        queue = QueueModel(services: services)
        meetings = MeetingsModel(services: services)
        live = LiveModel(services: services)
        library = LibraryModel(services: services, mode: .library)
        recentlyDeleted = LibraryModel(services: services, mode: .recentlyDeleted)
        quickOpen = QuickOpenModel(transcripts: services.transcripts)
        sidebar = SidebarModel(services: services)
        meetings.navigate = { [weak self] in self?.select(.meetings) }
        home.requestAdd = { [weak self] urls in await self?.requestAdd(urls) }
        let playback = playback
        library.onTranscriptsRemoved = { ids in for id in ids { playback.stop(transcriptID: id) } }
        recentlyDeleted.onTranscriptsRemoved = { ids in for id in ids { playback.stop(transcriptID: id) } }
    }

    /// Responsive layout for the current window width.
    public var layout: ShellLayout { ShellLayout(width: windowWidth) }

    /// Library routes search in place; every other route uses global Quick Open.
    public var usesLibrarySearch: Bool { openedTranscript == nil && (selection == .library || selection == .recentlyDeleted) }
    public var searchableLibrary: LibraryModel { selection == .recentlyDeleted ? recentlyDeleted : library }

    /// Records the window width and applies the responsive rules. The navigation pane is persistent and never collapses.
    public func updateWindowWidth(_ width: CGFloat) {
        windowWidth = width
    }

    /// Recording is always visible (handoff 5): a live session or a meeting recording is running.
    public var isRecordingActive: Bool { live.isRunning || meetings.isRecording }

    /// The section the recording indicator row opens.
    public var recordingSection: AppSection { meetings.isRecording ? .meetings : .live }

    /// Opens a pinned sidebar entry: the folder in the Library, or the transcript.
    public func openPinned(_ item: PinnedItem) {
        switch item {
        case .folder(let folder, _): openFolder(folder.id)
        case .transcript(let transcript): openTranscript(transcript.id)
        }
    }

    /// Opens Library narrowed to `folder` (sidebar folders).
    public func openFolder(_ folder: FolderID) {
        library.filters.folderID = folder
        select(.library)
    }

    /// Starts app-lifetime followers (meeting detection, prompts and auto-capture). Call once at launch; idempotent.
    public func startBackgroundWork() { meetings.start() }

    /// Restores the last-used section (Home on first launch).
    public func restore() async { selection = await persistence.load() }

    /// Selects `section` and remembers it.
    public func select(_ section: AppSection) {
        isQuickOpenPresented = false
        selection = section
        openedTranscript = nil
        if section == .library { Task { await sidebar.reloadPinned() } }
        let persistence = persistence
        Task { await persistence.save(section) }
    }

    /// Moves sidebar selection with Up/Down while sidebar navigation has keyboard focus; stops at either end.
    public func moveSidebarSelection(by offset: Int) {
        guard let current = AppSection.allCases.firstIndex(of: selection) else { return }
        let next = min(AppSection.allCases.count - 1, max(0, current + offset))
        guard next != current else { return }
        select(AppSection.allCases[next])
    }

    /// Opens the ⌘K palette.
    public func presentQuickOpen() {
        if usesLibrarySearch {
            librarySearchFocusToken += 1
            return
        }
        quickOpen.reset()
        isQuickOpenPresented = true
    }

    /// Opens a transcript in the editor (from quick open, Library, Queue or Home).
    public func openTranscript(_ id: TranscriptID) {
        isQuickOpenPresented = false
        playback.replace(keeping: id)  // a different transcript replaces the session; the same one resumes
        openedTranscript = id
    }

    /// The mini-player is on screen: a session exists and the editor for that transcript is not showing.
    public var showsMiniPlayer: Bool {
        guard let session = playback.session else { return false }
        return openedTranscript != session.transcriptID
    }

    /// Live captions, a meeting recording or dictation began: pause playback so it cannot feed the microphone.
    public func captureStateChanged(recording: Bool, dictating: Bool) {
        if recording || dictating { playback.captureDidStart() }
    }

    /// Follows capture state for the app's lifetime (start from a `.task`).
    public func watchCaptureForPlayback() async {
        let dictation = services.dictation
        let dictationTask = Task { [weak self] in
            guard let dictation else { return }
            for await listening in dictation.isListening() where listening {
                self?.captureStateChanged(recording: false, dictating: true)
            }
        }
        defer { dictationTask.cancel() }
        for await active in Observations({ [self] in isRecordingActive }) where active {
            captureStateChanged(recording: true, dictating: false)
        }
    }

    /// Closes the editor and returns to the selected section.
    public func closeTranscript() { openedTranscript = nil }

    /// Shows the file chooser (Transcribe File…).
    public func presentImporter() {
        select(.home)
        isImporterPresented = true
    }

    /// Handles files dropped on the window or chosen in the importer; returns immediately (NAV-AC-05).
    @discardableResult
    public func handleDrop(_ urls: [URL]) -> Bool {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return false }
        Task { await requestAdd(files) }
        return true
    }

    /// The one entry point for adding files (SCR-013): shows the Transcribe sheet (hosted by the shell) or, with "Ask before adding
    /// files" off, enqueues with the saved choices and opens the Queue.
    public func requestAdd(_ urls: [URL]) async {
        switch await queue.requestAdd(urls) {
        case .enqueued:
            errorMessage = nil
            select(.queue)
        case .failed(let message): errorMessage = message
        case .presented, .ignored: break
        }
    }

    /// Confirms the Transcribe sheet: enqueues the batch and opens the Queue.
    public func confirmAdd() async {
        await queue.submitBatch()
        if queue.batch == nil { select(.queue) }
    }

    public func cancelAdd() { queue.batch = nil }

    /// Enqueues files/folders and navigates to Queue.
    public func enqueue(_ urls: [URL]) async {
        do {
            let defaults = await FileJobSettings.load(from: services.settings, catalog: services.models.catalog())
            _ = try await services.jobQueue.enqueue(files: urls, settings: defaults, recursive: true)
            errorMessage = nil
            select(.queue)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func dismissError() { errorMessage = nil }

    /// Home callbacks.
    public var homeActions: HomeActions {
        HomeActions(
            transcribeFile: { [weak self] in self?.presentImporter() }, startLive: { [weak self] in self?.select(.live) },
            openQueue: { [weak self] in self?.select(.queue) }, openTranscript: { [weak self] in self?.openTranscript($0) },
            openLibrary: { [weak self] in self?.select(.library) },
            captureMeeting: { [weak self] in self?.select(.meetings) },
            toggleDictation: services.dictation.map { control in { Task { await control.toggle() } } })
    }
}
