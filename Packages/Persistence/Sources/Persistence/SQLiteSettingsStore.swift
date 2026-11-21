import AppCore
import Foundation
import GRDB
import Synchronization

/// GRDB-backed ``SettingsStore``: JSON values keyed by string, with per-key change streams.
///
/// Change streams are delivered in-process by the instance that performed the write, so share one instance
/// (see ``AppDatabase/makeSettingsStore()``) across the app. Failures are logged and swallowed because the
/// protocol is non-throwing.
public final class SQLiteSettingsStore: SettingsStore {
    private let writer: any DatabaseWriter
    private let listeners = Mutex<[String: [UUID: AsyncStream<Void>.Continuation]]>([:])
    private let log = AppLog.logger("settings")

    init(writer: any DatabaseWriter) { self.writer = writer }

    public func value<T: Codable & Sendable>(for key: String, as type: T.Type) async -> T? {
        do {
            let data: Data? = try await writer.read { db in
                try Data.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [key])
            }
            guard let data else { return nil }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            log.error("read failed for \(key, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    public func set<T: Codable & Sendable>(_ value: T, for key: String) async {
        do {
            let data = try JSONEncoder().encode(value)
            try await writer.write { db in
                try db.execute(
                    sql: "INSERT INTO setting (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    arguments: [key, data])
            }
            let continuations = listeners.withLock { Array($0[key]?.values ?? [:].values) }
            for continuation in continuations { continuation.yield() }
        } catch {
            log.error("write failed for \(key, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    public func changes(for key: String) -> AsyncStream<Void> {
        let token = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        listeners.withLock { $0[key, default: [:]][token] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.listeners.withLock { $0[key]?[token] = nil }
        }
        return stream
    }
}
