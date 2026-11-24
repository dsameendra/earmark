import Foundation

/// FIFO leases with cancellable admission. A cancelled queued Live request must
/// not wait for a background file batch to finish before stop can return.
actor TranslationOperationGate {
    private enum Waiter {
        case operation(UUID, CheckedContinuation<Void, any Error>)
        case cleanup(CheckedContinuation<Void, Never>)
        func resume() {
            switch self {
            case .operation(_, let continuation): continuation.resume()
            case .cleanup(let continuation): continuation.resume()
            }
        }
    }
    private var busy = false
    private var waiters: [Waiter] = []

    func withLease<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        return try await operation()
    }

    /// Cleanup waits for an in-flight owner's lease even when its caller was cancelled.
    func cleanup(_ operation: @Sendable () async -> Void) async {
        if busy {
            await withCheckedContinuation { waiters.append(.cleanup($0)) }
        } else { busy = true }
        defer { release() }
        await operation()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if !busy { busy = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append(.operation(id, continuation)) }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        // Cancellation may race with the handoff after removal from the queue.
        if Task.isCancelled { release(); throw CancellationError() }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: {
            if case .operation(let candidate, _) = $0 { return candidate == id }
            return false
        }) else { return }
        if case .operation(_, let continuation) = waiters.remove(at: index) {
            continuation.resume(throwing: CancellationError())
        }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}
