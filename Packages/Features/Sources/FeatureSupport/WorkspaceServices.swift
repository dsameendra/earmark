import AppCore
import Foundation

/// Something in the workspace changed that other screens show (sidebar pins, Library lists, the open transcript's tabs).
public enum WorkspaceEvent: Sendable, Equatable {
    case libraryChanged
    case foldersChanged
    case notesChanged(TranscriptID)
    case attachmentsChanged(TranscriptID)
}

/// In-process change signal for the workspace. Repositories do not notify (except folders), so the models that change
/// things send here and the sidebar and open pages listen.
public final class WorkspaceEvents: Sendable {
    private let bus = Broadcaster<WorkspaceEvent>()
    public init() {}
    public func stream() -> AsyncStream<WorkspaceEvent> { bus.stream() }
    public func send(_ event: WorkspaceEvent) { bus.send(event) }
}

/// Everything the notes, slides, chat and folder features need (SCR-018 to SCR-021).
public struct WorkspaceServices: Sendable {
    public var folders: any FolderRepository
    public var notes: any NotesRepository
    public var attachments: any AttachmentRepository
    public var chat: any ChatRepository
    /// On-device summaries and chat; `nil` hides them (previews, builds without the model).
    public var intelligence: (any IntelligenceServicing)?
    /// Copies and reads attached files; `nil` hides "Add files".
    public var files: (any AttachmentFileManaging)?
    public let events: WorkspaceEvents

    public init(
        folders: any FolderRepository, notes: any NotesRepository, attachments: any AttachmentRepository, chat: any ChatRepository,
        intelligence: (any IntelligenceServicing)? = nil, files: (any AttachmentFileManaging)? = nil,
        events: WorkspaceEvents = WorkspaceEvents()
    ) {
        self.folders = folders
        self.notes = notes
        self.attachments = attachments
        self.chat = chat
        self.intelligence = intelligence
        self.files = files
        self.events = events
    }

    /// In-memory services for previews and tests.
    public static func inMemory(intelligence: (any IntelligenceServicing)? = nil, files: (any AttachmentFileManaging)? = nil) -> WorkspaceServices {
        WorkspaceServices(
            folders: InMemoryFolders(), notes: InMemoryNotes(), attachments: InMemoryAttachments(), chat: InMemoryChat(),
            intelligence: intelligence, files: files)
    }
}

// MARK: - In-memory repositories

public actor InMemoryFolders: FolderRepository {
    private var items: [Folder]
    private let bus = Broadcaster<Void>()
    public init(items: [Folder] = []) { self.items = items }
    public func folders() async throws -> [Folder] { items.sorted { $0.createdAt < $1.createdAt } }
    public func save(_ folder: Folder) async throws {
        if let index = items.firstIndex(where: { $0.id == folder.id }) { items[index] = folder } else { items.append(folder) }
        bus.send(())
    }
    public func delete(_ id: FolderID) async throws {
        items.removeAll { $0.id == id }
        bus.send(())
    }
    public nonisolated func changes() -> AsyncStream<Void> { bus.stream() }
}

public actor InMemoryNotes: NotesRepository {
    private var pages: [TranscriptID: TranscriptNotes] = [:]
    private var history: [TranscriptID: [NotesVersion]] = [:]
    public init() {}
    public func notes(for transcript: TranscriptID) async throws -> TranscriptNotes? { pages[transcript] }
    public func save(_ notes: TranscriptNotes) async throws { pages[notes.transcriptID] = notes }
    public func versions(for transcript: TranscriptID) async throws -> [NotesVersion] {
        (history[transcript] ?? []).sorted { $0.createdAt > $1.createdAt }
    }
    public func save(_ version: NotesVersion) async throws { history[version.transcriptID, default: []].append(version) }
    public func moveWorkspace(from: TranscriptID, to: TranscriptID) async throws {
        if let page = pages.removeValue(forKey: from) {
            if pages[to] == nil {
                var moved = page
                moved.transcriptID = to
                pages[to] = moved
            } else {
                history[to, default: []].append(NotesVersion(transcriptID: to, markdown: page.markdown, reason: .checkpoint))
            }
        }
        if let versions = history.removeValue(forKey: from) {
            history[to, default: []] += versions.map { var v = $0; v.transcriptID = to; return v }
        }
    }
}

public actor InMemoryAttachments: AttachmentRepository {
    private var items: [Attachment] = []
    private var pageStore: [AttachmentID: [AttachmentPage]] = [:]
    private var linkStore: [AttachmentID: [SlideLink]] = [:]
    public init() {}
    public func attachments(for transcript: TranscriptID) async throws -> [Attachment] {
        items.filter { $0.transcriptID == transcript && $0.deletedAt == nil }.sorted { $0.createdAt < $1.createdAt }
    }
    public func save(_ attachment: Attachment) async throws {
        if let index = items.firstIndex(where: { $0.id == attachment.id }) { items[index] = attachment } else { items.append(attachment) }
    }
    public func softDelete(_ id: AttachmentID) async throws {
        if let index = items.firstIndex(where: { $0.id == id }) { items[index].deletedAt = Date() }
    }
    public func pages(for attachment: AttachmentID) async throws -> [AttachmentPage] { pageStore[attachment] ?? [] }
    public func replacePages(_ pages: [AttachmentPage], for attachment: AttachmentID) async throws { pageStore[attachment] = pages }
    public func links(for attachment: AttachmentID) async throws -> [SlideLink] { (linkStore[attachment] ?? []).sorted { $0.time < $1.time } }
    public func replaceLinks(_ links: [SlideLink], for attachment: AttachmentID) async throws { linkStore[attachment] = links }
}

public actor InMemoryChat: ChatRepository {
    private var items: [ChatMessage] = []
    public init() {}
    public func messages(for transcript: TranscriptID) async throws -> [ChatMessage] {
        items.filter { $0.transcriptID == transcript }.sorted { $0.createdAt < $1.createdAt }
    }
    public func save(_ message: ChatMessage) async throws {
        if let index = items.firstIndex(where: { $0.id == message.id }) { items[index] = message } else { items.append(message) }
    }
    public func clear(for transcript: TranscriptID) async throws { items.removeAll { $0.transcriptID == transcript } }
    public func clearAll() async throws { items.removeAll() }
}

// MARK: - Scripted intelligence (tests, previews, UI tests)

/// A deterministic stand-in for the on-device model: previews, unit tests and UI tests (`-EarmarkTestIntelligence`).
public struct ScriptedIntelligence: IntelligenceServicing {
    public var state: IntelligenceAvailability
    public var summaryMarkdown: String
    public var answer: String
    public var answerSources: [ChatSource]
    public var unsupportedLanguages: Set<String>

    public init(
        state: IntelligenceAvailability = .available,
        summaryMarkdown: String = "## Summary\nThe team agreed the plan.\n\n## Action items\n- [ ] Ana: send the notes",
        answer: String = "The release moved to September 26.", answerSources: [ChatSource] = [ChatSource(kind: .transcript, label: "00:20", time: 20)],
        unsupportedLanguages: Set<String> = ["si"]
    ) {
        self.state = state
        self.summaryMarkdown = summaryMarkdown
        self.answer = answer
        self.answerSources = answerSources
        self.unsupportedLanguages = unsupportedLanguages
    }

    public func availability() async -> IntelligenceAvailability { state }
    public func supports(language: LanguageCode?) async -> Bool { language.map { !unsupportedLanguages.contains($0.rawValue) } ?? true }

    public func summarize(_ request: SummaryRequest) -> AsyncThrowingStream<SummaryEvent, any Error> {
        let markdown = summaryMarkdown + (request.includeNotes && !request.notesMarkdown.isEmpty ? "\n\n## My notes\n" + request.notesMarkdown : "")
        return AsyncThrowingStream { continuation in
            continuation.yield(.progress(fraction: 0.5, detail: "Reading part 1 of 1"))
            continuation.yield(.finished(markdown: markdown))
            continuation.finish()
        }
    }

    public func summarize(attachment: Attachment) -> AsyncThrowingStream<SummaryEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.finished(markdown: "- Key point one\n- Key point two"))
            continuation.finish()
        }
    }

    public func answer(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, any Error> {
        let (text, sources) = (answer, answerSources)
        return AsyncThrowingStream { continuation in
            continuation.yield(.partial(String(text.prefix(12))))
            continuation.yield(.finished(text: text, sources: sources, upTo: nil))
            continuation.finish()
        }
    }
}

// MARK: - Drag and drop

import CoreTransferable
import UniformTypeIdentifiers

/// Transcripts dragged from the Library onto a folder (Library cards, sidebar).
public struct DraggedTranscripts: Codable, Sendable, Transferable {
    public var ids: [TranscriptID]
    public init(ids: [TranscriptID]) { self.ids = ids }
    public static var transferRepresentation: some TransferRepresentation { CodableRepresentation(contentType: .json) }
}


/// The next free pin position, after every pinned folder and transcript (SCR-018).
public enum PinOrder {
    public static func next(services: AppServices) async -> Int {
        var query = LibraryQuery()
        query.pinnedOnly = true
        let transcripts = ((try? await services.transcripts.list(query)) ?? []).compactMap(\.pinOrder)
        let folders = ((try? await services.workspace.folders.folders()) ?? []).compactMap(\.pinOrder)
        return (transcripts + folders).max().map { $0 + 1 } ?? 0
    }
}
