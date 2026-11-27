import AppCore
import Foundation
import GRDB
import Testing

@testable import Persistence

@Suite("Workspace repositories")
struct WorkspaceRepositoryTests {
    @Test func foldersRoundTripPinAndDelete() async throws {
        let db = try makeDB()
        let repo = db.folders
        var physics = Folder(name: "Physics 201", colorIndex: 2, createdAt: Date(timeIntervalSince1970: 10))
        let work = Folder(name: "Work", createdAt: Date(timeIntervalSince1970: 20))
        try await repo.save(physics)
        try await repo.save(work)
        physics.pinOrder = 0
        try await repo.save(physics)
        let all = try await repo.folders()
        #expect(all.map(\.name) == ["Physics 201", "Work"])
        #expect(all[0].isPinned && !all[1].isPinned)
        #expect(all[0].colorIndex == 2)

        var t = makeTranscript("Lecture", folder: physics.id)
        try await db.transcripts.save(t)
        try await repo.delete(physics.id)
        #expect(try await repo.folders().map(\.name) == ["Work"])
        t = try #require(await db.transcripts.transcript(t.id))
        #expect(t.folderID == nil)
    }

    @Test func pinnedTranscriptsListInPinOrder() async throws {
        let db = try makeDB()
        var a = makeTranscript("A")
        var b = makeTranscript("B")
        let c = makeTranscript("C")
        a.pinOrder = 1
        b.pinOrder = 0
        for t in [a, b, c] { try await db.transcripts.save(t) }
        var query = LibraryQuery()
        query.pinnedOnly = true
        let pinned = try await db.transcripts.list(query)
        #expect(pinned.map(\.title) == ["B", "A"])
        #expect(try await db.transcripts.list(LibraryQuery()).count == 3)
    }

    @Test func notesVersionsAndSearch() async throws {
        let db = try makeDB()
        let t = makeTranscript("Weekly sync")
        try await db.transcripts.save(t)
        #expect(try await db.notes.notes(for: t.id) == nil)
        try await db.notes.save(TranscriptNotes(transcriptID: t.id, markdown: "Remember the quarterly zeppelin budget"))
        try await db.notes.save(NotesVersion(transcriptID: t.id, markdown: "older", reason: .beforeSummary, createdAt: Date(timeIntervalSince1970: 5)))
        try await db.notes.save(NotesVersion(transcriptID: t.id, markdown: "newer", reason: .checkpoint, createdAt: Date(timeIntervalSince1970: 9)))
        #expect(try await db.notes.versions(for: t.id).map(\.markdown) == ["newer", "older"])
        let hits = try await db.transcripts.list(LibraryQuery(text: "zeppelin"))
        #expect(hits.map(\.id) == [t.id])
        try await db.notes.save(TranscriptNotes(transcriptID: t.id, markdown: "nothing relevant", summaryStyle: .lecture))
        #expect(try await db.transcripts.list(LibraryQuery(text: "zeppelin")).isEmpty)
        #expect(try await db.notes.notes(for: t.id)?.summaryStyle == .lecture)
    }

    @Test func attachmentsPagesLinksAndSearch() async throws {
        let db = try makeDB()
        let t = makeTranscript("Lecture 9")
        try await db.transcripts.save(t)
        let deck = Attachment(transcriptID: t.id, role: .slides, kind: .pdf, title: "Slides.pdf", relativePath: "a/b.pdf", pageCount: 2)
        try await db.attachments.save(deck)
        try await db.attachments.replacePages(
            [AttachmentPage(attachmentID: deck.id, index: 0, text: "Entropy and the second law"),
             AttachmentPage(attachmentID: deck.id, index: 1, text: "Carnot engines")], for: deck.id)
        #expect(try await db.attachments.pages(for: deck.id).map(\.text) == ["Entropy and the second law", "Carnot engines"])
        try await db.attachments.replaceLinks(
            [SlideLink(attachmentID: deck.id, page: 1, time: 90), SlideLink(attachmentID: deck.id, page: 0, time: 10)], for: deck.id)
        #expect(try await db.attachments.links(for: deck.id).map(\.page) == [0, 1])
        #expect(try await db.transcripts.list(LibraryQuery(text: "carnot")).map(\.id) == [t.id])
        // A file switched off for context no longer makes the transcript match.
        var off = deck
        off.usedInContext = false
        try await db.attachments.save(off)
        #expect(try await db.transcripts.list(LibraryQuery(text: "carnot")).isEmpty)
        try await db.attachments.softDelete(deck.id)
        #expect(try await db.attachments.attachments(for: t.id).isEmpty)
    }

    @Test func chatMessagesKeepSourcesAndClear() async throws {
        let db = try makeDB()
        let id = TranscriptID()
        let source = ChatSource(kind: .transcript, label: "12:52", time: 772)
        try await db.chat.save(ChatMessage(transcriptID: id, role: .user, text: "Q", createdAt: Date(timeIntervalSince1970: 1)))
        try await db.chat.save(ChatMessage(transcriptID: id, role: .assistant, text: "A", sources: [source], scope: .summaryAndNotes, createdAt: Date(timeIntervalSince1970: 2)))
        let messages = try await db.chat.messages(for: id)
        #expect(messages.map(\.text) == ["Q", "A"])
        #expect(messages[1].sources == [source] && messages[1].scope == .summaryAndNotes)
        try await db.chat.clear(for: id)
        #expect(try await db.chat.messages(for: id).isEmpty)
    }

    @Test func moveWorkspaceCarriesEverythingToTheFinalTranscript() async throws {
        let db = try makeDB()
        let draft = TranscriptID()
        let final = TranscriptID()
        try await db.notes.save(TranscriptNotes(transcriptID: draft, markdown: "my notes"))
        let deck = Attachment(transcriptID: draft, role: .slides, kind: .pdf, title: "d.pdf", relativePath: "d.pdf", pageCount: 1)
        try await db.attachments.save(deck)
        try await db.chat.save(ChatMessage(transcriptID: draft, role: .user, text: "hi"))
        try await db.notes.moveWorkspace(from: draft, to: final)
        #expect(try await db.notes.notes(for: final)?.markdown == "my notes")
        #expect(try await db.notes.notes(for: draft) == nil)
        #expect(try await db.attachments.attachments(for: final).map(\.id) == [deck.id])
        #expect(try await db.chat.messages(for: final).count == 1)
    }

    @Test func moveKeepsExistingNotesAndStoresTheDraftAsAVersion() async throws {
        let db = try makeDB()
        let draft = TranscriptID()
        let final = TranscriptID()
        try await db.notes.save(TranscriptNotes(transcriptID: draft, markdown: "draft notes"))
        try await db.notes.save(TranscriptNotes(transcriptID: final, markdown: "final notes"))
        try await db.notes.moveWorkspace(from: draft, to: final)
        #expect(try await db.notes.notes(for: final)?.markdown == "final notes")
        #expect(try await db.notes.versions(for: final).map(\.markdown) == ["draft notes"])
    }

    @Test func foldersMoveOutOfSettingsInTheMigration() async throws {
        let queue = try DatabaseQueue()
        let migrator = Schema.migrator()
        try migrator.migrate(queue, upTo: "v3-segment-user-edited")
        let id = UUID()
        let json = "[{\"id\":\"\(id.uuidString)\",\"name\":\"Interviews\"}]"
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO setting (key, value) VALUES ('library.folders', ?)", arguments: [Data(json.utf8)])
        }
        try migrator.migrate(queue)
        let db = try AppDatabase(writer: queue)
        let folders = try await db.folders.folders()
        #expect(folders.map(\.name) == ["Interviews"])
        #expect(folders.first?.id.rawValue == id)
    }
}
