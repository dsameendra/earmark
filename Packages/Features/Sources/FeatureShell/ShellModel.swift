import AppCore
import FeatureHome
import FeatureLibrary
import FeatureLive
import FeatureMeetings
import FeatureQueue
import FeatureSupport
import Foundation
import Observation

/// Shell state: sidebar selection (persisted), quick open, file import and drop handling.
@MainActor @Observable
public final class ShellModel {
    public private(set) var selection: AppSection = .home
    public var isQuickOpenPresented = false
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
    }

    /// Restores the last-used section (Home on first launch).
    public func restore() async { selection = await persistence.load() }

    /// Selects `section` and remembers it.
    public func select(_ section: AppSection) {
        selection = section
        openedTranscript = nil
        let persistence = persistence
        Task { await persistence.save(section) }
    }

    /// Opens the ⌘K palette.
    public func presentQuickOpen() {
        quickOpen.query = ""
        isQuickOpenPresented = true
    }

    /// Opens a transcript in the editor (from quick open, Library, Queue or Home).
    public func openTranscript(_ id: TranscriptID) {
        isQuickOpenPresented = false
        openedTranscript = id
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
        Task { await enqueue(files) }
        return true
    }

    /// Enqueues files/folders and navigates to Queue.
    public func enqueue(_ urls: [URL]) async {
        do {
            _ = try await services.jobQueue.enqueue(files: urls, settings: JobSettings(), recursive: true)
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
            openQueue: { [weak self] in self?.select(.queue) }, openTranscript: { [weak self] in self?.openTranscript($0) })
    }
}
