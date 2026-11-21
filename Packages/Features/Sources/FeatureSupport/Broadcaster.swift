import Foundation
import os

/// Fan-out helper for placeholder services: every `stream()` call gets its own `AsyncStream` of future values.
public final class Broadcaster<Element: Sendable>: Sendable {
    private let continuations = OSAllocatedUnfairLock<[UUID: AsyncStream<Element>.Continuation]>(initialState: [:])

    public init() {}

    /// A new stream; `initial` (when given) is delivered first.
    public func stream(initial: Element? = nil) -> AsyncStream<Element> {
        AsyncStream { continuation in
            if let initial { continuation.yield(initial) }
            let id = UUID()
            continuations.withLock { $0[id] = continuation }
            continuation.onTermination = { [continuations] _ in
                continuations.withLock { _ = $0.removeValue(forKey: id) }
            }
        }
    }

    /// Delivers `element` to every live subscriber.
    public func send(_ element: Element) {
        let targets = continuations.withLock { Array($0.values) }
        for target in targets { target.yield(element) }
    }
}
