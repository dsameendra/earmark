import AppCore
import Foundation

extension AppError {
    /// Maps any error thrown inside an engine into the cross-module `AppError` vocabulary. Never traps.
    ///
    /// `AppError`s pass through unchanged, task cancellation becomes ``AppError/cancelled``, and everything else becomes
    /// ``AppError/engineFailure(_:reason:)`` carrying the engine id and the error's description.
    public static func mapping(_ error: any Error, engine: EngineID) -> AppError {
        if let appError = error as? AppError { return appError }
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError, urlError.code == .cancelled { return .cancelled }
        let description = (error as? any LocalizedError)?.errorDescription ?? String(describing: error)
        let lowered = description.lowercased()
        if lowered.contains("out of memory") || lowered.contains("insufficient memory") { return .outOfMemory }
        return .engineFailure(engine, reason: description)
    }
}

/// A small FIFO async mutex. Actors are re-entrant across `await`, so engines use this to guarantee that a
/// non-thread-safe model is never driven by two requests at once.
actor AsyncGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
    }

    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        do {
            try Task.checkCancellation()
            let value = try await body()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }
}

extension Duration {
    /// The duration in (fractional) seconds.
    var secondsValue: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

/// Text clean-up shared by the engines.
enum TranscriptText {
    /// Removes Whisper special tokens such as `<|startoftranscript|>` or `<|0.00|>` that can leak into text.
    static func clean(_ text: String) -> String {
        var result = text
        while let open = result.range(of: "<|"), let close = result.range(of: "|>", range: open.upperBound..<result.endIndex) {
            result.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Raised by ``withDeadline(_:operation:)`` when the operation did not finish in time.
struct DeadlineExceeded: Error, Equatable { var seconds: Double }

/// One-shot rendezvous between an operation, its timer and the caller's cancellation. The first result wins, whether it
/// arrives before or after the continuation is installed.
private final class DeadlineRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var tasks: [Task<Void, Never>] = []
    private var result: Result<T, any Error>?
    private var delivered = false

    func install(_ continuation: CheckedContinuation<T, any Error>, tasks: [Task<Void, Never>]) {
        lock.lock()
        self.tasks = tasks
        if let result, !delivered {
            delivered = true
            lock.unlock()
            continuation.resume(with: result)
            tasks.forEach { $0.cancel() }
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ outcome: Result<T, any Error>) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = outcome
        guard let continuation, !delivered else {
            lock.unlock()
            return
        }
        delivered = true
        self.continuation = nil
        let current = tasks
        lock.unlock()
        continuation.resume(with: outcome)
        current.forEach { $0.cancel() }
    }
}

/// Runs `operation` and returns its result, or throws ``DeadlineExceeded`` after `timeout`, or `CancellationError` when the
/// caller is cancelled, whichever comes first.
///
/// Unlike a task group, this does **not** wait for `operation` once the deadline passed: Core ML predictions cannot be
/// interrupted, so a wedged call would otherwise hang its caller forever. The abandoned task is cancelled (best effort) and
/// left to finish on its own; callers that share state with it must discard that state (see ``WhisperKitEngine``).
func withDeadline<T: Sendable>(_ timeout: Duration, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let race = DeadlineRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            let worker = Task {
                do { race.finish(.success(try await operation())) } catch { race.finish(.failure(error)) }
            }
            let timer = Task {
                try? await Task.sleep(for: timeout)
                race.finish(.failure(DeadlineExceeded(seconds: timeout.secondsValue)))
            }
            race.install(continuation, tasks: [worker, timer])
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}

extension AsyncThrowingStream where Failure == any Error {
    /// Builds a stream that runs `body` in a task, maps thrown errors through ``AppError/mapping(_:engine:)`` and
    /// cancels the task when the consumer stops listening.
    static func engineTask(
        engine: EngineID,
        _ body: @escaping @Sendable (Continuation) async throws -> Void
    ) -> AsyncThrowingStream<Element, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await body(continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: AppError.mapping(error, engine: engine))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
