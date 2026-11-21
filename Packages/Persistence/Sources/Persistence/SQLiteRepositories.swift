import AppCore
import Foundation
import GRDB

// MARK: - Media

/// GRDB-backed ``MediaRepository``. Soft delete only; files are never touched here.
public struct SQLiteMediaRepository: MediaRepository {
    let writer: any DatabaseWriter

    public func asset(_ id: MediaAssetID) async throws -> MediaAsset? {
        try await wrapAsync {
            try await writer.read { db in
                try Row.fetchOne(db, sql: "SELECT * FROM mediaAsset WHERE id = ?", arguments: [id.key]).map { row in
                    MediaAsset(
                        id: MediaAssetID(row.uuid("id")), kind: MediaAsset.Kind(rawValue: row["kind"]) ?? .audio,
                        bookmark: row["bookmark"], libraryRelativePath: row["libraryRelativePath"], duration: row["duration"],
                        isOwnedByLibrary: row["isOwnedByLibrary"], deletedAt: row.optionalDate("deletedAt"))
                }
            }
        }
    }

    public func save(_ asset: MediaAsset) async throws {
        try await wrapAsync {
            try await writer.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO mediaAsset (id, kind, bookmark, libraryRelativePath, duration, isOwnedByLibrary, deletedAt)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET kind = excluded.kind, bookmark = excluded.bookmark,
                          libraryRelativePath = excluded.libraryRelativePath, duration = excluded.duration,
                          isOwnedByLibrary = excluded.isOwnedByLibrary, deletedAt = excluded.deletedAt
                        """,
                    arguments: [
                        asset.id.key, asset.kind.rawValue, asset.bookmark, asset.libraryRelativePath, asset.duration,
                        asset.isOwnedByLibrary, asset.deletedAt?.epoch,
                    ])
            }
        }
    }

    public func softDelete(_ id: MediaAssetID) async throws {
        try await softDeleteRow(writer, table: "mediaAsset", key: id.key)
    }
}

/// Sets `deletedAt` to now on one row (keeps the original timestamp when already deleted).
func softDeleteRow(_ writer: any DatabaseWriter, table: String, key: String) async throws {
    try await wrapAsync {
        let now = Date().epoch
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE \(table) SET deletedAt = ? WHERE id = ? AND deletedAt IS NULL", arguments: [now, key])
        }
    }
}

// MARK: - Jobs

/// GRDB-backed ``JobRepository``. Removing a job soft-deletes it (`deletedAt`); `allJobs` hides removed jobs.
public struct SQLiteJobRepository: JobRepository {
    let writer: any DatabaseWriter

    public func allJobs() async throws -> [Job] {
        try await wrapAsync {
            try await writer.read { db in
                try Row.fetchAll(db, sql: "SELECT payload FROM job WHERE deletedAt IS NULL ORDER BY priority DESC, createdAt, id")
                    .map { try jsonDecode(Job.self, from: $0["payload"]) }
            }
        }
    }

    public func save(_ job: Job) async throws {
        try await wrapAsync {
            let payload = try jsonEncode(job)
            try await writer.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO job (id, priority, createdAt, deletedAt, payload) VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET priority = excluded.priority, createdAt = excluded.createdAt,
                          deletedAt = excluded.deletedAt, payload = excluded.payload
                        """,
                    arguments: [job.id.key, job.priority, job.createdAt.epoch, job.deletedAt?.epoch, payload])
            }
        }
    }

    public func remove(_ id: JobID) async throws {
        try await softDeleteRow(writer, table: "job", key: id.key)
    }
}

// MARK: - Rules

/// GRDB-backed ``RuleRepository``. Removal is a soft delete (IGN-AC-13); lists exclude deleted rules.
public struct SQLiteRuleRepository: RuleRepository {
    let writer: any DatabaseWriter

    public func ignoreRules() async throws -> [IgnoreRule] {
        try await wrapAsync {
            try await writer.read { db in
                try Row.fetchAll(db, sql: "SELECT * FROM ignoreRule WHERE deletedAt IS NULL ORDER BY rowid").map(Self.ignoreRule)
            }
        }
    }

    public func saveIgnoreRule(_ rule: IgnoreRule) async throws {
        try await wrapAsync { try await writer.write { db in try Self.upsert(rule, in: db) } }
    }

    public func removeIgnoreRule(_ id: RuleID) async throws {
        try await softDeleteRow(writer, table: "ignoreRule", key: id.key)
    }

    /// Soft-deletes every active rule not in `rules`, then upserts `rules` (undeleting matching ids), atomically.
    public func replaceAllIgnoreRules(_ rules: [IgnoreRule]) async throws {
        try await wrapAsync {
            try await writer.write { db in
                let keep = Set(rules.map(\.id.key))
                let existing = try String.fetchAll(db, sql: "SELECT id FROM ignoreRule WHERE deletedAt IS NULL")
                let now = Date().epoch
                for key in existing where !keep.contains(key) {
                    try db.execute(sql: "UPDATE ignoreRule SET deletedAt = ? WHERE id = ?", arguments: [now, key])
                }
                for rule in rules { try Self.upsert(rule, in: db) }
            }
        }
    }

    public func replacementRules() async throws -> [ReplacementRule] {
        try await wrapAsync {
            try await writer.read { db in
                try Row.fetchAll(db, sql: "SELECT * FROM replacementRule WHERE deletedAt IS NULL ORDER BY rowid").map { row in
                    ReplacementRule(
                        id: RuleID(row.uuid("id")), find: row["find"], replacement: row["replacement"],
                        matchCase: row["matchCase"], wholeWord: row["wholeWord"], isRegex: row["isRegex"],
                        isEnabled: row["isEnabled"], deletedAt: row.optionalDate("deletedAt"))
                }
            }
        }
    }

    public func saveReplacementRule(_ rule: ReplacementRule) async throws {
        try await wrapAsync {
            try await writer.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO replacementRule (id, find, replacement, matchCase, wholeWord, isRegex, isEnabled, deletedAt)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET find = excluded.find, replacement = excluded.replacement,
                          matchCase = excluded.matchCase, wholeWord = excluded.wholeWord, isRegex = excluded.isRegex,
                          isEnabled = excluded.isEnabled, deletedAt = excluded.deletedAt
                        """,
                    arguments: [
                        rule.id.key, rule.find, rule.replacement, rule.matchCase, rule.wholeWord, rule.isRegex, rule.isEnabled,
                        rule.deletedAt?.epoch,
                    ])
            }
        }
    }

    public func removeReplacementRule(_ id: RuleID) async throws {
        try await softDeleteRow(writer, table: "replacementRule", key: id.key)
    }

    static func upsert(_ rule: IgnoreRule, in db: GRDB.Database) throws {
        try db.execute(
            sql: """
                INSERT INTO ignoreRule (id, pattern, match, scope, isEnabled, isHallucinationRule, deletedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET pattern = excluded.pattern, match = excluded.match, scope = excluded.scope,
                  isEnabled = excluded.isEnabled, isHallucinationRule = excluded.isHallucinationRule,
                  deletedAt = excluded.deletedAt
                """,
            arguments: [
                rule.id.key, rule.pattern, rule.match.rawValue, rule.scope.rawValue, rule.isEnabled, rule.isHallucinationRule,
                rule.deletedAt?.epoch,
            ])
    }

    static func ignoreRule(_ row: Row) -> IgnoreRule {
        IgnoreRule(
            id: RuleID(row.uuid("id")), pattern: row["pattern"], match: RuleMatch(rawValue: row["match"]) ?? .exact,
            scope: RuleScope(rawValue: row["scope"]) ?? .wholeSegment, isEnabled: row["isEnabled"],
            isHallucinationRule: row["isHallucinationRule"], deletedAt: row.optionalDate("deletedAt"))
    }
}

// MARK: - Presets

/// GRDB-backed ``PresetRepository`` for caption and export presets (JSON payloads, soft delete).
public struct SQLitePresetRepository: PresetRepository {
    let writer: any DatabaseWriter

    public func captionPresets() async throws -> [CaptionPreset] {
        try await payloads(table: "captionPreset", as: CaptionPreset.self)
    }

    public func save(_ preset: CaptionPreset) async throws {
        try await store(table: "captionPreset", key: preset.id.key, name: preset.name, value: preset, deletedAt: preset.deletedAt)
    }

    public func exportPresets() async throws -> [ExportPreset] {
        try await payloads(table: "exportPreset", as: ExportPreset.self)
    }

    public func save(_ preset: ExportPreset) async throws {
        try await store(table: "exportPreset", key: preset.id.key, name: preset.name, value: preset, deletedAt: preset.deletedAt)
    }

    /// Soft-deletes a caption or export preset with this id.
    public func softDeletePreset(_ id: PresetID) async throws {
        try await softDeleteRow(writer, table: "captionPreset", key: id.key)
        try await softDeleteRow(writer, table: "exportPreset", key: id.key)
    }

    private func payloads<T: Decodable & Sendable>(table: String, as: T.Type) async throws -> [T] {
        try await wrapAsync {
            try await writer.read { db in
                try Row.fetchAll(db, sql: "SELECT payload FROM \(table) WHERE deletedAt IS NULL ORDER BY rowid")
                    .map { try jsonDecode(T.self, from: $0["payload"]) }
            }
        }
    }

    private func store<T: Encodable & Sendable>(
        table: String, key: String, name: String, value: T, deletedAt: Date?
    ) async throws {
        try await wrapAsync {
            let payload = try jsonEncode(value)
            try await writer.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO \(table) (id, name, payload, deletedAt) VALUES (?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET name = excluded.name, payload = excluded.payload,
                          deletedAt = excluded.deletedAt
                        """,
                    arguments: [key, name, payload, deletedAt?.epoch])
            }
        }
    }
}

// MARK: - Voice profiles

/// GRDB-backed ``VoiceProfileRepository`` (local only; soft delete).
public struct SQLiteVoiceProfileRepository: VoiceProfileRepository {
    let writer: any DatabaseWriter

    public func profiles() async throws -> [VoiceProfile] {
        try await wrapAsync {
            try await writer.read { db in
                try Row.fetchAll(db, sql: "SELECT payload FROM voiceProfile WHERE deletedAt IS NULL ORDER BY createdAt, id")
                    .map { try jsonDecode(VoiceProfile.self, from: $0["payload"]) }
            }
        }
    }

    public func save(_ profile: VoiceProfile) async throws {
        try await wrapAsync {
            let payload = try jsonEncode(profile)
            try await writer.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO voiceProfile (id, name, createdAt, payload, deletedAt) VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET name = excluded.name, createdAt = excluded.createdAt,
                          payload = excluded.payload, deletedAt = excluded.deletedAt
                        """,
                    arguments: [profile.id.key, profile.name, profile.createdAt.epoch, payload, profile.deletedAt?.epoch])
            }
        }
    }

    public func softDelete(_ id: VoiceProfileID) async throws {
        try await softDeleteRow(writer, table: "voiceProfile", key: id.key)
    }
}

// MARK: - Meetings

/// GRDB-backed ``MeetingRepository`` (newest first; soft delete).
public struct SQLiteMeetingRepository: MeetingRepository {
    let writer: any DatabaseWriter

    public func meetings() async throws -> [Meeting] {
        try await wrapAsync {
            try await writer.read { db in
                try Row.fetchAll(db, sql: "SELECT payload FROM meeting WHERE deletedAt IS NULL ORDER BY startedAt DESC, id")
                    .map { try jsonDecode(Meeting.self, from: $0["payload"]) }
            }
        }
    }

    public func save(_ meeting: Meeting) async throws {
        try await wrapAsync {
            let payload = try jsonEncode(meeting)
            try await writer.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO meeting (id, startedAt, transcriptID, payload, deletedAt) VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET startedAt = excluded.startedAt, transcriptID = excluded.transcriptID,
                          payload = excluded.payload, deletedAt = excluded.deletedAt
                        """,
                    arguments: [
                        meeting.id.key, meeting.startedAt.epoch, meeting.transcriptID.idKey(), payload, meeting.deletedAt?.epoch,
                    ])
            }
        }
    }

    public func softDelete(_ id: MeetingID) async throws {
        try await softDeleteRow(writer, table: "meeting", key: id.key)
    }
}

// MARK: - Dictation history

/// GRDB-backed ``DictationHistoryRepository``. `clear()` hard-deletes: dictation history is privacy-sensitive.
public struct SQLiteDictationHistoryRepository: DictationHistoryRepository {
    let writer: any DatabaseWriter

    public func recent(limit: Int, matching: String?) async throws -> [DictationEntry] {
        guard limit > 0 else { return [] }
        return try await wrapAsync {
            try await writer.read { db in
                var sql = "SELECT * FROM dictationEntry WHERE deletedAt IS NULL"
                var args = StatementArguments()
                if let text = matching?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    sql += " AND text LIKE ? ESCAPE '\\'"
                    args += ["%" + SQLiteTranscriptRepository.escapeLike(text) + "%"]
                }
                sql += " ORDER BY createdAt DESC, id LIMIT ?"
                args += [limit]
                return try Row.fetchAll(db, sql: sql, arguments: args).map { row in
                    let language: String? = row["language"]
                    return DictationEntry(
                        id: row.uuid("id"), text: row["text"], language: language.map { LanguageCode($0) },
                        createdAt: row.date("createdAt"), deletedAt: row.optionalDate("deletedAt"))
                }
            }
        }
    }

    public func save(_ entry: DictationEntry) async throws {
        try await wrapAsync {
            try await writer.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO dictationEntry (id, text, language, createdAt, deletedAt) VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET text = excluded.text, language = excluded.language,
                          createdAt = excluded.createdAt, deletedAt = excluded.deletedAt
                        """,
                    arguments: [entry.id.uuidString, entry.text, entry.language?.rawValue, entry.createdAt.epoch, entry.deletedAt?.epoch])
            }
        }
    }

    public func clear() async throws {
        try await wrapAsync { try await writer.write { db in try db.execute(sql: "DELETE FROM dictationEntry") } }
    }
}
