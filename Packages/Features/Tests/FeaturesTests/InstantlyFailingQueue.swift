import AppCore
import FeatureSupport
import Foundation

/// A queue whose job is already failed when `enqueue` returns (and whose event was sent while `enqueue` ran).
actor InstantlyFailingQueue: JobQueue {
    private let bus = FeatureSupport.Broadcaster<JobEvent>()
    private var store: [Job] = []

    func enqueue(_ job: Job) async throws -> JobID {
        var failed = job
        failed.state = .failed
        failed.failureReason = "engine exploded"
        store.append(failed)
        bus.send(.updated(failed))
        return job.id
    }
    func enqueue(files: [URL], settings: JobSettings, recursive: Bool) async throws -> [JobID] { [] }
    func prioritize(_ id: JobID, to index: Int) async {}
    func pause(_ id: JobID) async {}
    func resume(_ id: JobID) async {}
    func cancel(_ id: JobID) async {}
    func retry(_ id: JobID) async {}
    func setMaxConcurrency(_ n: Int) async {}
    func jobs() async -> [Job] { store }
    nonisolated func events() -> AsyncStream<JobEvent> { bus.stream() }
    func resumeInterrupted() async {}
}
