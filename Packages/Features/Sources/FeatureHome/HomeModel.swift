import AppCore
import FeatureSupport
import Foundation
import Observation

/// Aggregate view of the job queue shown on Home (NAV-AC-06).
public struct ActiveJobsSummary: Sendable, Equatable {
    public var running: Int
    public var pending: Int
    public var failed: Int
    /// Mean progress (0...1) over running and pending jobs; 0 when nothing is active.
    public var aggregateProgress: Double

    public init(jobs: [Job]) {
        let active = jobs.filter { $0.deletedAt == nil && ($0.state == .running || $0.state == .pending) }
        running = active.filter { $0.state == .running }.count
        pending = active.count - running
        failed = jobs.filter { $0.deletedAt == nil && $0.state == .failed }.count
        aggregateProgress = active.isEmpty ? 0 : active.map(\.progress).reduce(0, +) / Double(active.count)
    }

    /// `true` while at least one job is running or waiting.
    public var isActive: Bool { running + pending > 0 }
}

/// Inline model-download status for quick actions (NAV-AC-07).
public struct ModelDownloadStatus: Sendable, Equatable {
    public var modelName: String
    public var fraction: Double?
    public var isVerifying: Bool
    public init(modelName: String, fraction: Double?, isVerifying: Bool = false) {
        self.modelName = modelName
        self.fraction = fraction
        self.isVerifying = isVerifying
    }
}

/// Drives the Home screen. Event-driven: no timers; updates arrive from `JobQueue.events()`.
@MainActor @Observable
public final class HomeModel {
    public private(set) var summary = ActiveJobsSummary(jobs: [])
    public private(set) var recent: [Transcript] = []
    public private(set) var isLoadingRecent = true
    public private(set) var download: ModelDownloadStatus?
    public private(set) var errorMessage: String?
    public let hardwareDescription: String

    @ObservationIgnored private var jobsByID: [JobID: Job] = [:]
    @ObservationIgnored private let services: AppServices

    public init(services: AppServices) {
        self.services = services
        let memoryGB = Int((Double(services.hardware.profile.memoryBytes) / 1_073_741_824).rounded())
        hardwareDescription = "\(services.hardware.profile.chip), \(memoryGB) GB"
    }

    /// Loads initial state, then follows job events until the task is cancelled.
    public func run() async {
        for job in await services.jobQueue.jobs() { jobsByID[job.id] = job }
        summary = ActiveJobsSummary(jobs: Array(jobsByID.values))
        await reloadRecent()
        for await event in services.jobQueue.events() {
            switch event {
            case .updated(let job): jobsByID[job.id] = job
            case .removed(let id): jobsByID[id] = nil
            }
            summary = ActiveJobsSummary(jobs: Array(jobsByID.values))
        }
    }

    /// Reloads the recent-transcripts list.
    public func reloadRecent() async {
        do {
            recent = try await services.transcripts.list(LibraryQuery(sort: .createdDesc, limit: 8))
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
        isLoadingRecent = false
    }

    /// Ensures the default ASR model is installed (showing inline progress) and returns `true` when it is ready (NAV-AC-07).
    public func ensureDefaultModel() async -> Bool {
        let catalog = await services.models.catalog()
        let installed = await services.models.installedModels()
        guard let model = catalog.first(where: { $0.kind == .asr && !$0.isExperimental }) ?? catalog.first(where: { $0.kind == .asr })
        else { return true }
        if installed.contains(model.id) { return true }
        download = ModelDownloadStatus(modelName: model.displayName, fraction: 0)
        defer { download = nil }
        do {
            for try await event in services.models.ensureAvailable(model.id) {
                switch event {
                case .progress(let fraction, _, _): download = ModelDownloadStatus(modelName: model.displayName, fraction: fraction)
                case .verifying: download = ModelDownloadStatus(modelName: model.displayName, fraction: 1, isVerifying: true)
                case .completed: break
                }
            }
            return true
        } catch {
            errorMessage = "Could not download \(model.displayName): \(error)"
            return false
        }
    }

    /// Clears the inline error banner.
    public func dismissError() { errorMessage = nil }
}
