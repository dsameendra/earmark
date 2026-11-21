import AppCore
import Foundation
import GRDB

/// The Earmark database (GRDB over SQLite, WAL, FTS5; see ADR-001) and the factory for its repositories.
///
/// Open a file-backed database with ``open(at:)`` (a `DatabasePool` in WAL mode, crash-safe for incremental
/// segment writes) or an ephemeral one with ``inMemory()`` for tests and previews.
public struct AppDatabase: Sendable {
    let writer: any DatabaseWriter

    /// Names of all migrations this build knows about, in order.
    public static var migrationIdentifiers: [String] { Schema.migrator().migrations }

    init(writer: any DatabaseWriter, migrator: DatabaseMigrator = Schema.migrator()) throws {
        self.writer = writer
        try migrator.migrate(writer)
    }

    /// Opens (creating if needed) the database at `url` and applies pending migrations.
    ///
    /// When the file already exists and migrations are pending, a `*.premigration.bak` copy is written first so a
    /// failed migration never loses data silently.
    /// - Throws: `AppError.persistence` on any open or migration failure.
    public static func open(at url: URL) throws -> AppDatabase {
        try open(at: url, migrator: Schema.migrator())
    }

    static func open(at url: URL, migrator: DatabaseMigrator) throws -> AppDatabase {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let existed = FileManager.default.fileExists(atPath: url.path)
            var configuration = Configuration()
            configuration.prepareDatabase { db in try db.execute(sql: "PRAGMA synchronous = NORMAL") }
            let pool = try DatabasePool(path: url.path, configuration: configuration)
            let pending = try pool.read { db in try !migrator.hasCompletedMigrations(db) }
            if existed && pending {
                let backupURL = url.appendingPathExtension("premigration.bak")
                try? FileManager.default.removeItem(at: backupURL)
                let backup = try DatabaseQueue(path: backupURL.path)
                try pool.backup(to: backup)
            }
            return try AppDatabase(writer: pool, migrator: migrator)
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.persistence(reason: String(describing: error))
        }
    }

    /// Creates a private in-memory database (not shared across instances).
    public static func inMemory() throws -> AppDatabase {
        do {
            return try AppDatabase(writer: try DatabaseQueue())
        } catch {
            throw AppError.persistence(reason: String(describing: error))
        }
    }

    /// Library transcripts, segments, search and soft delete.
    public var transcripts: SQLiteTranscriptRepository { SQLiteTranscriptRepository(writer: writer) }
    /// Media assets.
    public var media: SQLiteMediaRepository { SQLiteMediaRepository(writer: writer) }
    /// Persisted job queue records.
    public var jobs: SQLiteJobRepository { SQLiteJobRepository(writer: writer) }
    /// Ignore and replacement rules.
    public var rules: SQLiteRuleRepository { SQLiteRuleRepository(writer: writer) }
    /// Caption and export presets.
    public var presets: SQLitePresetRepository { SQLitePresetRepository(writer: writer) }
    /// Voice profiles.
    public var voiceProfiles: SQLiteVoiceProfileRepository { SQLiteVoiceProfileRepository(writer: writer) }
    /// Meetings.
    public var meetings: SQLiteMeetingRepository { SQLiteMeetingRepository(writer: writer) }
    /// Dictation history.
    public var dictationHistory: SQLiteDictationHistoryRepository { SQLiteDictationHistoryRepository(writer: writer) }
    /// Key-value settings. Hold on to this instance: change streams are tied to it.
    public func makeSettingsStore() -> SQLiteSettingsStore { SQLiteSettingsStore(writer: writer) }
}

// MARK: - Shared helpers

func wrap<T>(_ body: () throws -> T) throws -> T {
    do { return try body() } catch let error as AppError { throw error } catch is CancellationError {
        throw AppError.cancelled
    } catch { throw AppError.persistence(reason: String(describing: error)) }
}

func wrapAsync<T: Sendable>(_ body: () async throws -> T) async throws -> T {
    do { return try await body() } catch let error as AppError { throw error } catch is CancellationError {
        throw AppError.cancelled
    } catch { throw AppError.persistence(reason: String(describing: error)) }
}

extension Date {
    var epoch: Double { timeIntervalSince1970 }
    init(epoch: Double) { self.init(timeIntervalSince1970: epoch) }
}

extension Row {
    func uuid(_ column: String) -> UUID {
        // Stored as canonical strings by this module; a malformed id is treated as a nil UUID rather than crashing.
        UUID(uuidString: self[column] as String) ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000") ?? UUID()
    }
    func optionalUUID(_ column: String) -> UUID? {
        guard let string: String = self[column] else { return nil }
        return UUID(uuidString: string)
    }
    func optionalDate(_ column: String) -> Date? {
        guard let value: Double = self[column] else { return nil }
        return Date(epoch: value)
    }
    func date(_ column: String) -> Date { Date(epoch: self[column] as Double) }
}

extension ID {
    var key: String { rawValue.uuidString }
}

extension Optional {
    /// Maps the wrapped id to its database key.
    func idKey<Tag>() -> String? where Wrapped == ID<Tag> { self?.key }
}

func jsonEncode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
}

func jsonString<T: Encodable>(_ value: T) throws -> String {
    String(bytes: try jsonEncode(value), encoding: .utf8) ?? "null"
}

func jsonDecode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    try JSONDecoder().decode(type, from: data)
}

/// Splits `items` into chunks small enough for SQLite's bound-variable limit.
func chunks<T>(_ items: [T], size: Int = 500) -> [ArraySlice<T>] {
    stride(from: 0, to: items.count, by: size).map { items[$0..<min($0 + size, items.count)] }
}

func placeholders(_ count: Int) -> String { Array(repeating: "?", count: count).joined(separator: ",") }
