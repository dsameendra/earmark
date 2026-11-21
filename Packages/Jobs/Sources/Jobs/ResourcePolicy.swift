import AppCore
import Foundation
import os

/// `SettingsStore` keys owned by the queue.
public enum JobsSettingsKey {
    /// `Int`; maximum simultaneous jobs. Absent means the hardware-tier default.
    public static let maxConcurrency = "jobs.maxConcurrency"
    /// `Bool`; lower priority and concurrency while on battery (default `true`, FILE-AC-13).
    public static let lowPriorityOnBattery = "jobs.lowPriorityOnBattery"
    /// `String`; auto-export watch folder path (absent means `~/Documents/Earmark Exports`).
    public static let autoExportFolder = "jobs.autoExportFolder"
}

/// Battery and thermal throttling (FILE-AC-13, ADR-007). Applies to new job starts only; running jobs are never cancelled
/// when the limit drops (FILE-AC-07).
public enum JobResourcePolicy {
    /// Result of applying the policy.
    public struct Decision: Sendable, Equatable {
        public var concurrency: Int
        public var priority: TaskPriority
    }

    /// Concurrency when the user has not chosen one: one job on 8 GB Macs (a single heavy model stays resident),
    /// two otherwise (the engine serialises decoding, so the second job overlaps decoding, post-processing and I/O).
    public static func defaultConcurrency(for tier: HardwareTier) -> Int { tier == .tier8 ? 1 : 2 }

    public static func decide(
        userMax: Int, onBattery: Bool, lowPriorityOnBattery: Bool, thermal: ThermalPressure
    ) -> Decision {
        var concurrency = max(1, userMax)
        var priority = TaskPriority.medium
        if lowPriorityOnBattery, onBattery {
            concurrency = max(1, concurrency / 2)
            priority = .utility
        }
        switch thermal {
        case .nominal: break
        case .fair: priority = .utility
        case .serious:
            concurrency = max(1, concurrency / 2)
            priority = .background
        case .critical:
            concurrency = 1
            priority = .background
        }
        return Decision(concurrency: concurrency, priority: priority)
    }
}

/// Estimates remaining time from the progress made since the run (re)started.
struct ETAEstimator: Sendable {
    let startedAt: Date
    let startFraction: Double

    func eta(fraction: Double, now: Date) -> TimeInterval? {
        let done = fraction - startFraction
        let elapsed = now.timeIntervalSince(startedAt)
        guard done > 0.005, fraction < 1, elapsed > 0 else { return nil }
        return elapsed / done * (1 - fraction)
    }
}

/// Fan-out of values to any number of `AsyncStream` subscribers; safe to subscribe from non-isolated code.
final class JobBroadcaster<Element: Sendable>: Sendable {
    private let subscribers = OSAllocatedUnfairLock<[UUID: AsyncStream<Element>.Continuation]>(initialState: [:])

    func stream() -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream<Element>.makeStream(bufferingPolicy: .bufferingNewest(512))
        let id = UUID()
        subscribers.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.subscribers.withLock { _ = $0.removeValue(forKey: id) }
        }
        return stream
    }

    func send(_ element: Element) {
        let all = subscribers.withLock { Array($0.values) }
        for continuation in all { continuation.yield(element) }
    }
}
