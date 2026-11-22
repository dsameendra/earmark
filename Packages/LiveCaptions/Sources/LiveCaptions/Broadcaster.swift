import Foundation
import Synchronization

/// Multi-subscriber fan-out over bounded `AsyncStream`s. Subscribers optionally receive the latest value on subscribe.
/// Streams use `bufferingNewest`, so a slow consumer never blocks the producer.
final class Broadcaster<Element: Sendable>: Sendable {
    private struct State {
        var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
        var latest: Element?
    }
    private let state: Mutex<State>
    private let buffering: Int
    private let replayLatest: Bool

    init(initial: Element? = nil, buffering: Int = 16, replayLatest: Bool = true) {
        state = Mutex(State(latest: initial))
        self.buffering = buffering
        self.replayLatest = replayLatest
    }

    func subscribe() -> AsyncStream<Element> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self, bufferingPolicy: .bufferingNewest(buffering))
        state.withLock { s in
            s.continuations[id] = continuation
            if replayLatest, let latest = s.latest { continuation.yield(latest) }
        }
        continuation.onTermination = { [weak self] _ in self?.remove(id) }
        return stream
    }

    func send(_ element: Element) {
        let targets = state.withLock { s -> [AsyncStream<Element>.Continuation] in
            if replayLatest { s.latest = element }
            return Array(s.continuations.values)
        }
        for continuation in targets { continuation.yield(element) }
    }

    private func remove(_ id: UUID) {
        _ = state.withLock { $0.continuations.removeValue(forKey: id) }
    }
}

/// Thread-safe boolean gate shared with non-isolated capture pumps (pause/resume).
final class PauseGate: Sendable {
    private let flag = Mutex(false)
    var isPaused: Bool { flag.withLock { $0 } }
    func set(_ paused: Bool) { flag.withLock { $0 = paused } }
}
