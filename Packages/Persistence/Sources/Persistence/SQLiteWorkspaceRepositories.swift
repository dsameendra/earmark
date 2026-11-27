import AppCore
import Foundation
import GRDB

// SCR-018 to SCR-021: GRDB-backed folders, notes, attachments and chat.

// MARK: - Folders

public struct SQLiteFolderRepository: FolderRepository {
    let writer: any DatabaseWriter

    public func folders() async throws -> [Folder] {
        try await wrapAsync {
            try await writer.read { db in
                try Row.fetchAll(db, sql: "SELECT * FROM folder ORDER BY createdAt, id").map(Self.folder)
            }
        }
    }

    public func save(_ folder: Folder) async throws {
        try await wrapAsync {
            try await writer.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO folder (id, name, colorIndex, parentID, pinOrder, createdAt) VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET name = excluded.name, colorIndex = excluded.colorIndex,
                          parentID = excluded.parentID, pinOrder = excluded.pinOrder
                        """,
                    arguments: [folder.id.key, folder.name, folder.colorIndex, folder.parentID.idKey(), folder.pinOrder, folder.createdAt.epoch])
            }
        }
    }

    public func delete(_ id: FolderID) async throws {
        try await wrapAsync {
            try await writer.write { db in
                try db.execute(sql: "UPDATE transcript SET folderID = NULL WHERE folderID = ?", arguments: [id.key])
                try db.execute(sql: "UPDATE folder SET parentID = NULL WHERE parentID = ?", arguments: [id.key])
                try db.execute(sql: "DELETE FROM folder WHERE id = ?", arguments: [id.key])
            }
        }
    }

    public func changes() -> AsyncStream<Void> {
        let writer = writer
        return AsyncStream { continuation in
            let observation = ValueObservation.tracking { db in
                try String.fetchAll(
                    db, sql: "SELECT id || '|' || name || '|' || colorIndex || '|' || IFNULL(parentID, '') || '|' || IFNULL(pinOrder, '') FROM folder")
            }
            let task = Task {
                do { for try await _ in observation.values(in: writer) { continuation.yield() } } catch {}
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func folder(_ row: Row) -> Folder {
        Folder(
            id: FolderID(row.uuid("id")), name: row["name"], colorIndex: row["colorIndex"],
            parentID: row.optionalUUID("parentID").map { FolderID($0) }, pinOrder: row["pinOrder"], createdAt: row.date("createdAt"))
    }
}

// MARK: - Notes

public struct SQLiteNotesRepository: NotesRepository {
    let writer: any DatabaseWriter

    public func notes(for transcript: TranscriptID) async throws -> TranscriptNotes? {
        try await wrapAsync {
            try await writer.read { db in
                try Row.fetchOne(db, sql: "SELECT * FROM transcriptNotes WHERE transcriptID = ?", arguments: [transcript.key]).map { row in
                    TranscriptNotes(
                        transcriptID: transcript, markdown: row["markdown"], updatedAt: row.date("updatedAt"),
                        summarizedAt: row.optionalDate("summarizedAt"),
                        summaryStyle: (row["summaryStyle"] as String?).flatMap(SummaryStyle.init(rawValue:)))
                }
            }
        }
    }

    public func save(_ notes: TranscriptNotes) async throws {
        try await wrapAsync {
            try await writer.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO transcriptNotes (transcriptID, markdown, updatedAt, summarizedAt, summaryStyle) VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(transcriptID) DO UPDATE SET markdown = excluded.markdown, updatedAt = excluded.updatedAt,
                          summarizedAt = excluded.summarizedAt, summaryStyle = excluded.summaryStyle
                        """,
                    arguments: [notes.transcriptID.key, notes.markdown, notes.updatedAt.epoch, notes.summarizedAt?.epoch, notes.summaryStyle?.rawValue])
            }
        }
    }

    public func versions(for transcript: TranscriptID) async throws -> [NotesVersion] {
        try await wrapAsync {
            try await writer.read { db in
                try Row.fetchAll(
                    db, sql: "SELECT * FROM notesVersion WHERE transcriptID = ? ORDER BY createdAt DESC, id", arguments: [transcript.key]
                ).map { row in
                    NotesVersion(
                        id: NotesVersionID(row.uuid("id")), transcriptID: transcript, markdown: row["markdown"],
                        reason: NotesVersion.Reason(rawValue: row["reason"]) ?? .checkpoint, createdAt: row.date("createdAt"))
                }
            }
        }
    }

    public func save(_ version: NotesVersion) async throws {
        try await wrapAsync {
            try await writer.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO notesVersion (id, transcriptID, markdown, reason, createdAt) VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET markdown = excluded.markdown, reason = excluded.reason
                        """,
                    arguments: [version.id.key, version.transcriptID.key, version.markdown, version.reason.rawValue, version.createdAt.epoch])
            }
        }
    }

    public func moveWorkspace(from: TranscriptID, to: TranscriptID) async throws {
        guard from != to else { return }
        try await wrapAsync {
            try await writer.write { db in
                // The destination keeps its own notes page when it already has one; the draft's page becomes a version.
                if let draft = try Row.fetchOne(db, sql: "SELECT * FROM transcriptNotes WHERE transcriptID = ?", arguments: [from.key]) {
                    let hasDestination =
                        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcriptNotes WHERE transcriptID = ?", arguments: [to.key]) ?? 0 > 0
                    if hasDestination {
                        try db.execute(
                            sql: "INSERT INTO notesVersion (id, transcriptID, markdown, reason, createdAt) VALUES (?, ?, ?, 'checkpoint', ?)",
                            arguments: [UUID().uuidString, to.key, draft["markdown"] as String, Date().timeIntervalSince1970])
                        try db.execute(sql: "DELETE FROM transcriptNotes WHERE transcriptID = ?", arguments: [from.key])
                    } else {
                        try db.execute(sql: "UPDATE transcriptNotes SET transcriptID = ? WHERE transcriptID = ?", arguments: [to.key, from.key])
                    }
                }
                for table in ["notesVersion", "attachment", "chatMessage"] {
                    try db.execute(sql: "UPDATE \(table) SET transcriptID = ? WHERE transcriptID = ?", arguments: [to.key, from.key])
                }
            }
        }
    }
}

// MARK: - Attachments

public struct SQLiteAttachmentRepository: AttachmentRepository {
    let writer: any DatabaseWriter

    public func attachments(for transcript: TranscriptID) async throws -> [Attachment] {
        try await wrapAsync {
            try await writer.read { db in
                try Row.fetchAll(
                    db, sql: "SELECT * FROM attachment WHERE transcriptID = ? AND deletedAt IS NULL ORDER BY createdAt, id",
                    arguments: [transcript.key]
                ).map { row in
                    Attachment(
                        id: AttachmentID(row.uuid("id")), transcriptID: transcript, role: Attachment.Role(rawValue: row["role"]) ?? .reference,
                        kind: Attachment.Kind(rawValue: row["kind"]) ?? .pdf, title: row["title"], relativePath: row["relativePath"],
                        pageCount: row["pageCount"], recognizedPageCount: row["recognizedPageCount"], usedInContext: row["usedInContext"],
                        summary: row["summary"], summarizedAt: row.optionalDate("summarizedAt"), createdAt: row.date("createdAt"),
                        deletedAt: row.optionalDate("deletedAt"))
                }
            }
        }
    }

    public func save(_ attachment: Attachment) async throws {
        try await wrapAsync {
            try await writer.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO attachment (id, transcriptID, role, kind, title, relativePath, pageCount, recognizedPageCount,
                          usedInContext, summary, summarizedAt, createdAt, deletedAt)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET transcriptID = excluded.transcriptID, role = excluded.role, kind = excluded.kind,
                          title = excluded.title, relativePath = excluded.relativePath, pageCount = excluded.pageCount,
                          recognizedPageCount = excluded.recognizedPageCount, usedInContext = excluded.usedInContext,
                          summary = excluded.summary, summarizedAt = excluded.summarizedAt, deletedAt = excluded.deletedAt
                        """,
                    arguments: [
                        attachment.id.key, attachment.transcriptID.key, attachment.role.rawValue, attachment.kind.rawValue,
                        attachment.title, attachment.relativePath, attachment.pageCount, attachment.recognizedPageCount,
                        attachment.usedInContext, attachment.summary, attachment.summarizedAt?.epoch, attachment.createdAt.epoch,
                        attachment.deletedAt?.epoch,
                    ])
            }
        }
    }

    public func softDelete(_ id: AttachmentID) async throws {
        try await softDeleteRow(writer, table: "attachment", key: id.key)
    }

    public func pages(for attachment: AttachmentID) async throws -> [AttachmentPage] {
        try await wrapAsync {
            try await writer.read { db in
                try Row.fetchAll(db, sql: "SELECT idx, text FROM attachmentPage WHERE attachmentID = ? ORDER BY idx", arguments: [attachment.key])
                    .map { AttachmentPage(attachmentID: attachment, index: $0["idx"], text: $0["text"]) }
            }
        }
    }

    public func replacePages(_ pages: [AttachmentPage], for attachment: AttachmentID) async throws {
        try await wrapAsync {
            try await writer.write { db in
                try db.execute(sql: "DELETE FROM attachmentPage WHERE attachmentID = ?", arguments: [attachment.key])
                for page in pages {
                    try db.execute(
                        sql: "INSERT INTO attachmentPage (attachmentID, idx, text) VALUES (?, ?, ?)",
                        arguments: [attachment.key, page.index, page.text])
                }
            }
        }
    }

    public func links(for attachment: AttachmentID) async throws -> [SlideLink] {
        try await wrapAsync {
            try await writer.read { db in
                try Row.fetchAll(db, sql: "SELECT page, time FROM slideLink WHERE attachmentID = ? ORDER BY time", arguments: [attachment.key])
                    .map { SlideLink(attachmentID: attachment, page: $0["page"], time: $0["time"]) }
            }
        }
    }

    public func replaceLinks(_ links: [SlideLink], for attachment: AttachmentID) async throws {
        try await wrapAsync {
            try await writer.write { db in
                try db.execute(sql: "DELETE FROM slideLink WHERE attachmentID = ?", arguments: [attachment.key])
                for link in links {
                    try db.execute(
                        sql: "INSERT OR REPLACE INTO slideLink (attachmentID, page, time) VALUES (?, ?, ?)",
                        arguments: [attachment.key, link.page, link.time])
                }
            }
        }
    }
}

// MARK: - Chat

public struct SQLiteChatRepository: ChatRepository {
    let writer: any DatabaseWriter

    public func messages(for transcript: TranscriptID) async throws -> [ChatMessage] {
        try await wrapAsync {
            try await writer.read { db in
                try Row.fetchAll(
                    db, sql: "SELECT * FROM chatMessage WHERE transcriptID = ? ORDER BY createdAt, id", arguments: [transcript.key]
                ).map { row in
                    ChatMessage(
                        id: ChatMessageID(row.uuid("id")), transcriptID: transcript,
                        role: ChatMessage.Role(rawValue: row["role"]) ?? .assistant, text: row["text"],
                        sources: (try? jsonDecode([ChatSource].self, from: Data((row["sources"] as String).utf8))) ?? [],
                        scope: ChatScope(rawValue: row["scope"]) ?? .everything, createdAt: row.date("createdAt"))
                }
            }
        }
    }

    public func save(_ message: ChatMessage) async throws {
        try await wrapAsync {
            let sources = try jsonString(message.sources)
            try await writer.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO chatMessage (id, transcriptID, role, text, sources, scope, createdAt) VALUES (?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET text = excluded.text, sources = excluded.sources
                        """,
                    arguments: [
                        message.id.key, message.transcriptID.key, message.role.rawValue, message.text, sources, message.scope.rawValue,
                        message.createdAt.epoch,
                    ])
            }
        }
    }

    public func clear(for transcript: TranscriptID) async throws {
        try await wrapAsync {
            try await writer.write { db in try db.execute(sql: "DELETE FROM chatMessage WHERE transcriptID = ?", arguments: [transcript.key]) }
        }
    }

    public func clearAll() async throws {
        try await wrapAsync { try await writer.write { db in try db.execute(sql: "DELETE FROM chatMessage") } }
    }
}
