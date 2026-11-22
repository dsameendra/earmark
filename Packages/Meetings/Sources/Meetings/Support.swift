import AppCore
import Foundation
import os

/// Fan-out for `AsyncStream`s: every call to ``stream(bufferingPolicy:)`` gets its own stream and receives every later
/// element. `AsyncStream` is single-consumer, so anything several parts of the app observe goes through one of these.
public final class Broadcaster<Element: Sendable>: Sendable {
    private let continuations = OSAllocatedUnfairLock(initialState: [UUID: AsyncStream<Element>.Continuation]())
    public init() {}

    public func stream(bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy = .unbounded) -> AsyncStream<Element> {
        AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
            let id = UUID()
            continuations.withLock { $0[id] = continuation }
            continuation.onTermination = { [continuations] _ in
                continuations.withLock { _ = $0.removeValue(forKey: id) }
            }
        }
    }

    public func send(_ element: Element) {
        let targets = continuations.withLock { Array($0.values) }
        for target in targets { target.yield(element) }
    }

    public func finish() {
        let targets = continuations.withLock { state in
            let all = Array(state.values)
            state.removeAll()
            return all
        }
        for target in targets { target.finish() }
    }
}

/// Time source for debouncing and grace periods. Tests inject a manual clock; production uses ``SystemMeetingClock``.
public protocol MeetingClock: Sendable {
    func now() -> Date
    /// Suspends for `seconds`; throws `CancellationError` when the task is cancelled.
    func sleep(for seconds: TimeInterval) async throws
}

public struct SystemMeetingClock: MeetingClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(for seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(max(0, seconds)))
    }
}

/// Settings keys owned by this package. The strings are identical to `FeatureSupport.SettingsKey` (a test pins the
/// literals) so the Settings UI and the runtime read and write the same values.
public enum MeetingsSettingsKeys {
    /// `MeetingPolicy` JSON for one app: `meetings.policy.<app.rawValue>`.
    public static func policy(_ app: MeetingApp) -> String { "meetings.policy.\(app.rawValue)" }
    /// Legacy `Bool`; only used as a migration default when no policy has been stored.
    public static let legacyAutoRecord = "meetings.autoRecord"
    /// `Bool`; `true` (default) means the one-time consent notice must be shown.
    public static let consentNotice = "meetings.consentNotice"
    /// `Double` (seconds since 1970): when the user acknowledged the consent notice. Package-owned key.
    public static let consentAcknowledgedAt = "meetings.consentAcknowledgedAt"
    /// `String`: recordings folder (empty means library default).
    public static let storageLocation = "meetings.storageLocation"
}
