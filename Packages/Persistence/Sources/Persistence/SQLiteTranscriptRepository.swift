import AppCore
import Foundation
import GRDB

/// GRDB-backed ``TranscriptRepository``.
///
/// - Search covers non-ignored segments of non-deleted transcripts (FTS5, `unicode61` extended for Sinhala).
/// - List queries never read word blobs or segment rows (LIB-AC-03).
public struct SQLiteTranscriptRepository: TranscriptRepository {
    let writer: any DatabaseWriter

    // MARK: Library

    public func list(_ query: LibraryQuery) async throws -> [Transcript] {
        try await wrapAsync {
            try await writer.read { db in
                let (clauses, filterArgs) = Self.filters(for: query)
                var args = filterArgs
                var sql =
                    "SELECT t.* FROM transcript t WHERE \(clauses.joined(separator: " AND ")) ORDER BY \(Self.orderBy(query.sort))"
                if let limit = query.limit {
                    sql += " LIMIT ?"
                    args += [max(0, limit)]
                }
                let rows = try Row.fetchCursor(db, sql: sql, arguments: args)
                var result: [Transcript] = []
                let decoder = JSONDecoder()
                while let row = try rows.next() { result.append(try Self.transcript(from: row, decoder: decoder)) }
                return result
            }
        }
    }

    public func transcript(_ id: TranscriptID) async throws -> Transcript? {
        try await wrapAsync {
            try await writer.read { db in
                try Row.fetchOne(db, sql: "SELECT * FROM transcript WHERE id = ?", arguments: [id.key])
                    .map { try Self.transcript(from: $0, decoder: JSONDecoder()) }
            }
        }
    }

    public func save(_ transcript: Transcript) async throws {
        try await wrapAsync {
            let languages = try jsonString(transcript.languages.map(\.rawValue).sorted())
            let speakers = try jsonString(transcript.speakers)
            let tags = try jsonString(transcript.tags)
            try await writer.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO transcript (id, title, source, duration, languages, speakers, tags, folderID, mediaAssetID,
                          meetingID, revisionOf, createdAt, modifiedAt, deletedAt)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET title = excluded.title, source = excluded.source,
                          duration = excluded.duration, languages = excluded.languages, speakers = excluded.speakers,
                          tags = excluded.tags, folderID = excluded.folderID, mediaAssetID = excluded.mediaAssetID,
                          meetingID = excluded.meetingID, revisionOf = excluded.revisionOf, createdAt = excluded.createdAt,
                          modifiedAt = excluded.modifiedAt, deletedAt = excluded.deletedAt
                        """,
                    arguments: [
                        transcript.id.key, transcript.title, transcript.source.rawValue, transcript.duration,
                        languages, speakers, tags, transcript.folderID.idKey(), transcript.mediaAssetID.idKey(),
                        transcript.meetingID.idKey(), transcript.revisionOf.idKey(), transcript.createdAt.epoch,
                        transcript.modifiedAt.epoch, transcript.deletedAt?.epoch,
                    ])
            }
        }
    }

    // MARK: Segments

    public func segments(for id: TranscriptID) async throws -> [Segment] {
        try await wrapAsync {
            try await writer.read { db in
                let rows = try Row.fetchCursor(
                    db, sql: "SELECT * FROM segment WHERE transcriptID = ? ORDER BY start, \"end\", rowid", arguments: [id.key])
                var result: [Segment] = []
                let decoder = JSONDecoder()
                while let row = try rows.next() { result.append(try Self.segment(from: row, decoder: decoder)) }
                return result
            }
        }
    }

    public func upsertSegments(_ segments: [Segment], for id: TranscriptID) async throws {
        guard !segments.isEmpty else { return }
        try await wrapAsync {
            let encoded = try segments.map(Self.encode)
            try await writer.write { db in
                for row in encoded { try Self.upsert(row, transcriptKey: id.key, in: db) }
            }
        }
    }

    public func replaceSegments(_ segments: [Segment], for id: TranscriptID) async throws {
        try await wrapAsync {
            let encoded = try segments.map(Self.encode)
            try await writer.write { db in
                try db.execute(sql: "DELETE FROM segment WHERE transcriptID = ?", arguments: [id.key])
                for row in encoded { try Self.upsert(row, transcriptKey: id.key, in: db) }
            }
        }
    }

    // MARK: Search

    public func search(_ text: String, limit: Int) async throws -> [SearchHit] {
        guard let match = Self.ftsQuery(text), limit > 0 else { return [] }
        return try await wrapAsync {
            try await writer.read { db in
                let sql = """
                    SELECT s.id AS segmentID, s.transcriptID, s.start,
                           snippet(segmentFTS, 0, '', '', '…', 16) AS snip
                    FROM segmentFTS
                    JOIN segment s ON s.rowid = segmentFTS.rowid
                    JOIN transcript t ON t.id = s.transcriptID
                    WHERE segmentFTS MATCH ? AND t.deletedAt IS NULL AND s.isIgnored = 0
                    ORDER BY bm25(segmentFTS), t.createdAt DESC, s.start
                    LIMIT ?
                    """
                return try Row.fetchAll(db, sql: sql, arguments: [match, limit]).map { row in
                    SearchHit(
                        transcriptID: TranscriptID(row.uuid("transcriptID")), segmentID: SegmentID(row.uuid("segmentID")),
                        snippet: row["snip"], time: row["start"])
                }
            }
        }
    }

    // MARK: Soft delete lifecycle

    public func softDelete(_ ids: [TranscriptID], at date: Date) async throws {
        try await updateDeletedAt(ids, to: date.epoch, onlyIfLive: true)
    }

    public func restore(_ ids: [TranscriptID]) async throws {
        try await updateDeletedAt(ids, to: nil, onlyIfLive: false)
    }

    public func purge(_ ids: [TranscriptID]) async throws {
        try await wrapAsync {
            try await writer.write { db in
                for chunk in chunks(ids.map(\.key)) {
                    try db.execute(
                        sql: "DELETE FROM transcript WHERE id IN (\(placeholders(chunk.count)))",
                        arguments: StatementArguments(Array(chunk)))
                }
            }
        }
    }

    public func purgeDeleted(before date: Date) async throws -> Int {
        try await wrapAsync {
            try await writer.write { db in
                try db.execute(
                    sql: "DELETE FROM transcript WHERE deletedAt IS NOT NULL AND deletedAt < ?", arguments: [date.epoch])
                return db.changesCount
            }
        }
    }

    // MARK: Bookmarks

    public func bookmarks(for id: TranscriptID) async throws -> [TranscriptBookmark] {
        try await wrapAsync {
            try await writer.read { db in
                try Row.fetchAll(
                    db, sql: "SELECT * FROM bookmark WHERE transcriptID = ? AND deletedAt IS NULL ORDER BY time, createdAt",
                    arguments: [id.key]
                ).map { row in
                    TranscriptBookmark(
                        id: BookmarkID(row.uuid("id")), transcriptID: TranscriptID(row.uuid("transcriptID")), time: row["time"],
                        note: row["note"], createdAt: row.date("createdAt"), deletedAt: row.optionalDate("deletedAt"))
                }
            }
        }
    }

    public func save(_ bookmark: TranscriptBookmark) async throws {
        try await wrapAsync {
            try await writer.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO bookmark (id, transcriptID, time, note, createdAt, deletedAt) VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET transcriptID = excluded.transcriptID, time = excluded.time,
                          note = excluded.note, createdAt = excluded.createdAt, deletedAt = excluded.deletedAt
                        """,
                    arguments: [
                        bookmark.id.key, bookmark.transcriptID.key, bookmark.time, bookmark.note, bookmark.createdAt.epoch,
                        bookmark.deletedAt?.epoch,
                    ])
            }
        }
    }

    // MARK: Internals

    private func updateDeletedAt(_ ids: [TranscriptID], to value: Double?, onlyIfLive: Bool) async throws {
        try await wrapAsync {
            try await writer.write { db in
                for chunk in chunks(ids.map(\.key)) {
                    var args: StatementArguments = [value]
                    args += StatementArguments(Array(chunk))
                    let guardClause = onlyIfLive ? " AND deletedAt IS NULL" : ""
                    try db.execute(
                        sql: "UPDATE transcript SET deletedAt = ? WHERE id IN (\(placeholders(chunk.count)))\(guardClause)",
                        arguments: args)
                }
            }
        }
    }

    /// WHERE-clause fragments (AND-ed) and their arguments for a library query.
    static func filters(for query: LibraryQuery) -> ([String], StatementArguments) {
        var clauses: [String] = [query.deletedOnly ? "t.deletedAt IS NOT NULL" : "t.deletedAt IS NULL"]
        var args = StatementArguments()
        if !query.sources.isEmpty {
            clauses.append("t.source IN (\(placeholders(query.sources.count)))")
            args += StatementArguments(query.sources.map(\.rawValue).sorted())
        }
        if !query.languages.isEmpty {
            clauses.append(
                "EXISTS (SELECT 1 FROM json_each(t.languages) WHERE value IN (\(placeholders(query.languages.count))))")
            args += StatementArguments(query.languages.map(\.rawValue).sorted())
        }
        if let folder = query.folderID {
            clauses.append("t.folderID = ?")
            args += [folder.key]
        }
        if !query.tags.isEmpty {
            clauses.append(
                """
                (SELECT COUNT(DISTINCT value) FROM json_each(t.tags) WHERE value IN (\(placeholders(query.tags.count)))) = ?
                """)
            args += StatementArguments(query.tags.sorted())
            args += [query.tags.count]
        }
        if !query.speakerNames.isEmpty {
            let marks = placeholders(query.speakerNames.count)
            clauses.append("EXISTS (SELECT 1 FROM json_each(t.speakers) WHERE json_extract(value, '$.name') IN (\(marks)))")
            args += StatementArguments(query.speakerNames.sorted())
        }
        if let range = query.dateRange {
            clauses.append("t.createdAt BETWEEN ? AND ?")
            args += [range.lowerBound.epoch, range.upperBound.epoch]
        }
        if let range = query.durationRange {
            clauses.append("t.duration BETWEEN ? AND ?")
            args += [range.lowerBound, range.upperBound]
        }
        if let text = query.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            var sub = "t.title LIKE ? ESCAPE '\\'"
            args += ["%" + Self.escapeLike(text) + "%"]
            if let match = Self.ftsQuery(text) {
                sub += " OR t.id IN (SELECT s.transcriptID FROM segment s WHERE s.rowid IN "
                sub += "(SELECT rowid FROM segmentFTS WHERE segmentFTS MATCH ?) AND s.isIgnored = 0)"
                args += [match]
            }
            clauses.append("(\(sub))")
        }
        return (clauses, args)
    }

    /// Builds an FTS5 MATCH expression: every whitespace-separated token quoted, the last one as a prefix.
    static func ftsQuery(_ text: String) -> String? {
        let tokens = text.split(whereSeparator: \.isWhitespace).map { $0.replacingOccurrences(of: "\"", with: "\"\"") }
        guard !tokens.isEmpty else { return nil }
        var parts = tokens.map { "\"\($0)\"" }
        parts[parts.count - 1] += "*"
        return parts.joined(separator: " ")
    }

    static func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    static func orderBy(_ sort: LibrarySort) -> String {
        switch sort {
        case .createdDesc: "t.createdAt DESC, t.id"
        case .createdAsc: "t.createdAt ASC, t.id"
        case .titleAsc: "t.title COLLATE NOCASE ASC, t.id"
        case .durationDesc: "t.duration DESC, t.id"
        case .modifiedDesc: "t.modifiedAt DESC, t.id"
        }
    }

    static func transcript(from row: Row, decoder: JSONDecoder) throws -> Transcript {
        let languageStrings = try decoder.decode([String].self, from: Data((row["languages"] as String).utf8))
        let speakers = try decoder.decode([Speaker].self, from: Data((row["speakers"] as String).utf8))
        let tags = try decoder.decode([String].self, from: Data((row["tags"] as String).utf8))
        guard let source = TranscriptSource(rawValue: row["source"]) else {
            throw AppError.persistence(reason: "Unknown transcript source")
        }
        return Transcript(
            id: TranscriptID(row.uuid("id")), title: row["title"], source: source, duration: row["duration"],
            languages: Set(languageStrings.map { LanguageCode($0) }), speakers: speakers, tags: tags,
            folderID: row.optionalUUID("folderID").map { FolderID($0) },
            mediaAssetID: row.optionalUUID("mediaAssetID").map { MediaAssetID($0) },
            meetingID: row.optionalUUID("meetingID").map { MeetingID($0) },
            revisionOf: row.optionalUUID("revisionOf").map { TranscriptID($0) }, createdAt: row.date("createdAt"),
            modifiedAt: row.date("modifiedAt"), deletedAt: row.optionalDate("deletedAt"))
    }

    struct EncodedSegment: Sendable {
        var segment: Segment
        var words: Data?
        var translations: String?
    }

    static func encode(_ segment: Segment) throws -> EncodedSegment {
        let translations = segment.translations.isEmpty ? nil : try jsonString(segment.translations)
        return EncodedSegment(
            segment: segment, words: segment.words.isEmpty ? nil : WordBlob.encode(segment.words), translations: translations)
    }

    static func upsert(_ encoded: EncodedSegment, transcriptKey: String, in db: GRDB.Database) throws {
        let s = encoded.segment
        try db.execute(
            sql: """
                INSERT INTO segment (id, transcriptID, start, "end", text, speakerID, languageCode, languageConfidence,
                  confidence, noSpeechProbability, isIgnored, ignoreFlagIsManual, isUserEdited, words, translations)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET transcriptID = excluded.transcriptID, start = excluded.start,
                  "end" = excluded."end", text = excluded.text, speakerID = excluded.speakerID,
                  languageCode = excluded.languageCode, languageConfidence = excluded.languageConfidence,
                  confidence = excluded.confidence, noSpeechProbability = excluded.noSpeechProbability,
                  isIgnored = excluded.isIgnored, ignoreFlagIsManual = excluded.ignoreFlagIsManual, isUserEdited = excluded.isUserEdited,
                  words = excluded.words, translations = excluded.translations
                """,
            arguments: [
                s.id.key, transcriptKey, s.start, s.end, s.text, s.speakerID.idKey(), s.languageCode?.rawValue,
                s.languageConfidence, s.confidence, s.noSpeechProbability, s.isIgnored, s.ignoreFlagIsManual, s.isUserEdited, encoded.words, encoded.translations,
            ])
    }

    static func segment(from row: Row, decoder: JSONDecoder) throws -> Segment {
        let words: [Word]
        if let blob: Data = row["words"] { words = try WordBlob.decode(blob) } else { words = [] }
        let translations: [SegmentTranslation]
        if let json: String = row["translations"] {
            translations = try decoder.decode([SegmentTranslation].self, from: Data(json.utf8))
        } else {
            translations = []
        }
        let language: String? = row["languageCode"]
        return Segment(
            id: SegmentID(row.uuid("id")), start: row["start"], end: row["end"], text: row["text"],
            speakerID: row.optionalUUID("speakerID").map { SpeakerID($0) }, languageCode: language.map { LanguageCode($0) },
            languageConfidence: row["languageConfidence"], confidence: row["confidence"],
            noSpeechProbability: row["noSpeechProbability"], isIgnored: row["isIgnored"],
            ignoreFlagIsManual: row["ignoreFlagIsManual"], isUserEdited: row["isUserEdited"], words: words,
            translations: translations)
    }
}
