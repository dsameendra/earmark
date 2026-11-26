import Foundation

// SCR-018 to SCR-021: folders and pins, notes and summaries, attachments, chat. Contracts only; the SQLite implementations
// live in `Persistence`, the on-device model in `Intelligence`.

// MARK: - Folders and pins (SCR-018)

/// A Library folder. One level in 1.2.0; `parentID` is stored so nesting can arrive without another migration.
public struct Folder: Codable, Sendable, Hashable, Identifiable {
    public var id: FolderID
    public var name: String
    /// Index into the speaker palette; the folder's dot colour.
    public var colorIndex: Int
    public var parentID: FolderID?
    /// Non-nil means pinned to the sidebar; the value is the position among pinned items.
    public var pinOrder: Int?
    public var createdAt: Date
    public init(
        id: FolderID = FolderID(), name: String, colorIndex: Int = 0, parentID: FolderID? = nil, pinOrder: Int? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
        self.parentID = parentID
        self.pinOrder = pinOrder
        self.createdAt = createdAt
    }
    public var isPinned: Bool { pinOrder != nil }
}

public protocol FolderRepository: Sendable {
    /// All folders, oldest first.
    func folders() async throws -> [Folder]
    func save(_ folder: Folder) async throws
    /// Removes the folder; its transcripts move to the Library root.
    func delete(_ id: FolderID) async throws
    /// Emits whenever folders change (create, rename, pin, delete).
    func changes() -> AsyncStream<Void>
}

// MARK: - Notes and summaries (SCR-019)

/// How a summary is shaped.
public enum SummaryStyle: String, Codable, Sendable, CaseIterable, Hashable {
    case meeting, lecture, general
}

/// The hand-written page next to a transcript. Rich text is stored as Markdown.
public struct TranscriptNotes: Codable, Sendable, Hashable {
    public var transcriptID: TranscriptID
    public var markdown: String
    public var updatedAt: Date
    /// When Summarise last wrote this page, and in which style.
    public var summarizedAt: Date?
    public var summaryStyle: SummaryStyle?
    public init(
        transcriptID: TranscriptID, markdown: String = "", updatedAt: Date = Date(), summarizedAt: Date? = nil,
        summaryStyle: SummaryStyle? = nil
    ) {
        self.transcriptID = transcriptID
        self.markdown = markdown
        self.updatedAt = updatedAt
        self.summarizedAt = summarizedAt
        self.summaryStyle = summaryStyle
    }
}

/// An earlier state of the page, kept so Summarise never loses the user's writing.
public struct NotesVersion: Codable, Sendable, Hashable, Identifiable {
    public enum Reason: String, Codable, Sendable { case beforeSummary, beforeRestore, checkpoint }
    public var id: NotesVersionID
    public var transcriptID: TranscriptID
    public var markdown: String
    public var reason: Reason
    public var createdAt: Date
    public init(
        id: NotesVersionID = NotesVersionID(), transcriptID: TranscriptID, markdown: String, reason: Reason, createdAt: Date = Date()
    ) {
        self.id = id
        self.transcriptID = transcriptID
        self.markdown = markdown
        self.reason = reason
        self.createdAt = createdAt
    }
}

public protocol NotesRepository: Sendable {
    func notes(for transcript: TranscriptID) async throws -> TranscriptNotes?
    func save(_ notes: TranscriptNotes) async throws
    /// Newest first.
    func versions(for transcript: TranscriptID) async throws -> [NotesVersion]
    func save(_ version: NotesVersion) async throws
    /// Moves notes, versions, attachments and chat from a live draft to the final transcript of a meeting.
    func moveWorkspace(from: TranscriptID, to: TranscriptID) async throws
}

// MARK: - Attachments (SCR-020)

public struct Attachment: Codable, Sendable, Hashable, Identifiable {
    public enum Role: String, Codable, Sendable { case slides, reference }
    public enum Kind: String, Codable, Sendable { case pdf, images }
    public var id: AttachmentID
    public var transcriptID: TranscriptID
    public var role: Role
    public var kind: Kind
    public var title: String
    /// Path inside the library's `Attachments` folder. A PDF is one file; images are a folder of numbered files.
    public var relativePath: String
    public var pageCount: Int
    /// Pages whose text came from text recognition rather than the file.
    public var recognizedPageCount: Int
    /// Whether Summarise and Chat may use this file.
    public var usedInContext: Bool
    public var summary: String?
    public var summarizedAt: Date?
    public var createdAt: Date
    public var deletedAt: Date?
    public init(
        id: AttachmentID = AttachmentID(), transcriptID: TranscriptID, role: Role, kind: Kind, title: String, relativePath: String,
        pageCount: Int, recognizedPageCount: Int = 0, usedInContext: Bool = true, summary: String? = nil, summarizedAt: Date? = nil,
        createdAt: Date = Date(), deletedAt: Date? = nil
    ) {
        self.id = id
        self.transcriptID = transcriptID
        self.role = role
        self.kind = kind
        self.title = title
        self.relativePath = relativePath
        self.pageCount = pageCount
        self.recognizedPageCount = recognizedPageCount
        self.usedInContext = usedInContext
        self.summary = summary
        self.summarizedAt = summarizedAt
        self.createdAt = createdAt
        self.deletedAt = deletedAt
    }
}

public struct AttachmentPage: Codable, Sendable, Hashable {
    public var attachmentID: AttachmentID
    /// Zero-based.
    public var index: Int
    public var text: String
    public init(attachmentID: AttachmentID, index: Int, text: String) {
        self.attachmentID = attachmentID
        self.index = index
        self.text = text
    }
}

/// "Slide `page` is up from `time`." Playback follows the deck when links exist.
public struct SlideLink: Codable, Sendable, Hashable {
    public var attachmentID: AttachmentID
    public var page: Int
    public var time: TimeInterval
    public init(attachmentID: AttachmentID, page: Int, time: TimeInterval) {
        self.attachmentID = attachmentID
        self.page = page
        self.time = time
    }
}

public protocol AttachmentRepository: Sendable {
    func attachments(for transcript: TranscriptID) async throws -> [Attachment]
    func save(_ attachment: Attachment) async throws
    func softDelete(_ id: AttachmentID) async throws
    func pages(for attachment: AttachmentID) async throws -> [AttachmentPage]
    func replacePages(_ pages: [AttachmentPage], for attachment: AttachmentID) async throws
    func links(for attachment: AttachmentID) async throws -> [SlideLink]
    func replaceLinks(_ links: [SlideLink], for attachment: AttachmentID) async throws
}

// MARK: - Chat (SCR-021)

/// Where part of an answer came from. Produced by Earmark from what was retrieved, never by the model.
public struct ChatSource: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable { case transcript, page, notes, summary }
    public var id: String { "\(kind.rawValue):\(attachmentID?.description ?? "-"):\(page ?? -1):\(Int(time ?? -1))" }
    public var kind: Kind
    /// "12:52", "Slide 12", "Syllabus.pdf p.2", "Notes".
    public var label: String
    public var time: TimeInterval?
    public var attachmentID: AttachmentID?
    /// Zero-based page.
    public var page: Int?
    public init(kind: Kind, label: String, time: TimeInterval? = nil, attachmentID: AttachmentID? = nil, page: Int? = nil) {
        self.kind = kind
        self.label = label
        self.time = time
        self.attachmentID = attachmentID
        self.page = page
    }
}

/// What a chat answer may draw on.
public enum ChatScope: String, Codable, Sendable, CaseIterable, Hashable {
    /// Transcript, notes, summary and attached files.
    case everything
    /// Only the written summary and notes.
    case summaryAndNotes
}

public struct ChatMessage: Codable, Sendable, Hashable, Identifiable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public var id: ChatMessageID
    public var transcriptID: TranscriptID
    public var role: Role
    public var text: String
    public var sources: [ChatSource]
    public var scope: ChatScope
    public var createdAt: Date
    public init(
        id: ChatMessageID = ChatMessageID(), transcriptID: TranscriptID, role: Role, text: String, sources: [ChatSource] = [],
        scope: ChatScope = .everything, createdAt: Date = Date()
    ) {
        self.id = id
        self.transcriptID = transcriptID
        self.role = role
        self.text = text
        self.sources = sources
        self.scope = scope
        self.createdAt = createdAt
    }
}

public protocol ChatRepository: Sendable {
    /// Oldest first.
    func messages(for transcript: TranscriptID) async throws -> [ChatMessage]
    func save(_ message: ChatMessage) async throws
    func clear(for transcript: TranscriptID) async throws
    func clearAll() async throws
}

// MARK: - Intelligence seams

/// Whether on-device generation can run, and if not why (shown to the user).
public enum IntelligenceAvailability: Sendable, Equatable {
    case available
    case unavailable(Reason)
    public enum Reason: Sendable, Equatable {
        case deviceNotEligible, notEnabled, modelNotReady, osTooOld, other(String)
    }
    public var isAvailable: Bool { self == .available }
}

public enum IntelligenceError: Error, Sendable, Equatable {
    case unavailable(IntelligenceAvailability.Reason)
    case languageNotSupported(String)
    case cancelled
    /// The system declined to process some text; `part` says which part (one-based).
    case declined(part: Int)
    case failed(String)
}
