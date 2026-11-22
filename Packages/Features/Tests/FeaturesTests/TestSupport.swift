import AppCore
import FeatureSupport
import Foundation
import os

/// Polls `condition` every `interval` until it holds or `timeout` elapses.
///
/// Replaces fixed `Task.sleep` then `#expect` patterns. The suite runs on machines whose load average can reach 15-40
/// (iCloud sync daemons), where a fixed 100 ms is not enough for a main-actor hop; polling returns as soon as the state
/// is reached (typically within a few ms) and only waits the full timeout when the condition is genuinely never met.
@MainActor
func eventually(
    timeout: Duration = .seconds(10), interval: Duration = .milliseconds(10), _ condition: @MainActor () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: interval)
    }
    return await condition()
}

/// Counts how many times a stream was subscribed to. Broadcasters do not replay, so a test that emits an event must
/// first know the model under test is actually listening; "sleep 100 ms and hope" is not a subscription barrier.
final class SubscriptionCount: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: 0)
    func hit() { lock.withLock { $0 += 1 } }
    var value: Int { lock.withLock { $0 } }
}

/// Wraps a live session and counts `state()` / `lines()` subscriptions.
struct CountingLive: LiveSessionControlling {
    let base: any LiveSessionControlling
    let states = SubscriptionCount()
    let linesCount = SubscriptionCount()
    init(_ base: any LiveSessionControlling = PlaceholderLiveSession()) { self.base = base }

    func start(_ config: LiveSessionConfig) async throws { try await base.start(config) }
    func stop() async -> TranscriptID? { await base.stop() }
    func state() -> AsyncStream<LiveSessionState> {
        states.hit()
        return base.state()
    }
    func lines() -> AsyncStream<[CaptionLine]> {
        linesCount.hit()
        return base.lines()
    }
}
