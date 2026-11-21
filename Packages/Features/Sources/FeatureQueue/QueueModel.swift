import AppCore
import FeatureSupport
import Foundation
import Observation

/// Drives the Queue screen from `JobQueue` (pending / running / paused / failed jobs).
@MainActor @Observable
public final class QueueModel {
    public private(set) var jobs: [Job] = []
    public private(set) var isLoading = true
    public var maxConcurrency = 1

    @ObservationIgnored private let queue: any JobQueue

    public init(services: AppServices) { queue = services.jobQueue }

    /// Loads jobs then follows events until cancelled.
    public func run() async {
        jobs = await queue.jobs().filter { $0.deletedAt == nil }
        isLoading = false
        for await event in queue.events() {
            switch event {
            case .updated(let job):
                if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job } else { jobs.append(job) }
            case .removed(let id):
                jobs.removeAll { $0.id == id }
            }
        }
    }

    /// Reorders by drag (`List.onMove`).
    public func move(from source: IndexSet, to destination: Int) {
        guard let from = source.first else { return }
        let id = jobs[from].id
        jobs.move(fromOffsets: source, toOffset: destination)
        let target = jobs.firstIndex { $0.id == id } ?? destination
        Task { await queue.prioritize(id, to: target) }
    }

    public func pause(_ id: JobID) { Task { await queue.pause(id) } }
    public func resume(_ id: JobID) { Task { await queue.resume(id) } }
    public func cancel(_ id: JobID) { Task { await queue.cancel(id) } }
    public func retry(_ id: JobID) { Task { await queue.retry(id) } }

    /// Applies the concurrency setting.
    public func applyConcurrency() {
        let value = maxConcurrency
        Task { await queue.setMaxConcurrency(value) }
    }
}
