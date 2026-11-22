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

/// State of the default speech model, shown in the Home model-status card.
public struct ModelStatusSummary: Sendable, Equatable {
    public var name: String
    public var isInstalled: Bool
    public var installedCount: Int
    public init(name: String, isInstalled: Bool, installedCount: Int) {
        self.name = name
        self.isInstalled = isInstalled
        self.installedCount = installedCount
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
    public private(set) var modelStatus: ModelStatusSummary?
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
        let events = services.jobQueue.events()  // subscribe before loading so no update is lost
        let modelChanges = services.models.stateChanges()
        let preferredChanges = services.settings.changes(for: SettingsKey.preferredModel)
        let languageChanges = services.settings.changes(for: SettingsKey.languageMode)
        let watchers = [
            Task { [weak self] in for await _ in modelChanges { await self?.reloadModelStatus() } },
            Task { [weak self] in for await _ in preferredChanges { await self?.reloadModelStatus() } },
            Task { [weak self] in for await _ in languageChanges { await self?.reloadModelStatus() } },
        ]
        defer { for watcher in watchers { watcher.cancel() } }
        jobsByID = Dictionary(uniqueKeysWithValues: await services.jobQueue.jobs().map { ($0.id, $0) })
        summary = ActiveJobsSummary(jobs: Array(jobsByID.values))
        await reloadRecent()
        await reloadModelStatus()
        for await event in events {
            switch event {
            case .updated(let job):
                jobsByID[job.id] = job
                if job.state == .completed { await reloadRecent() }
            case .removed(let id): jobsByID[id] = nil
            }
            summary = ActiveJobsSummary(jobs: Array(jobsByID.values))
        }
    }

    /// Running and waiting jobs, running first, for the active-jobs card.
    public var activeJobs: [Job] {
        jobsByID.values.filter { $0.deletedAt == nil && ($0.state == .running || $0.state == .pending) }
            .sorted { ($0.state == .running ? 0 : 1, $0.createdAt) < ($1.state == .running ? 0 : 1, $1.createdAt) }
    }

    /// Enqueues dropped files/folders through the job queue; returns `true` when the caller should navigate to Queue (NAV-AC-05).
    public func enqueue(_ urls: [URL]) async -> Bool {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return false }
        do {
            let defaults = await FileJobSettings.load(from: services.settings, catalog: services.models.catalog())
            _ = try await services.jobQueue.enqueue(files: files, settings: defaults, recursive: true)
            errorMessage = nil
            return true
        } catch {
            errorMessage = String(describing: error)
            return false
        }
    }

    /// Refreshes the model-status card.
    public func reloadModelStatus() async {
        let catalog = await services.models.catalog()
        let installed = await services.models.installedModels()
        let required = await PreferredModel.fileModels(in: catalog, settings: services.settings, tier: services.hardware.profile.tier)
        guard let model = required.first else {
            modelStatus = nil
            return
        }
        modelStatus = ModelStatusSummary(
            name: required.count == 1 ? model.displayName : "Automatic · \(required.count) models",
            isInstalled: required.allSatisfy { installed.contains($0.id) },
            installedCount: catalog.filter { $0.kind == .asr && installed.contains($0.id) }.count)
    }

    public static func defaultModel(in catalog: [ModelDescriptor]) -> ModelDescriptor? {
        catalog.first(where: { $0.kind == .asr && !$0.isExperimental }) ?? catalog.first(where: { $0.kind == .asr })
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
        let required = await PreferredModel.fileModels(in: catalog, settings: services.settings, tier: services.hardware.profile.tier)
        defer { download = nil }
        for model in required where !installed.contains(model.id) {
            download = ModelDownloadStatus(modelName: model.displayName, fraction: 0)
            do {
                for try await event in services.models.ensureAvailable(model.id) {
                    switch event {
                    case .progress(let fraction, _, _): download = ModelDownloadStatus(modelName: model.displayName, fraction: fraction)
                    case .verifying: download = ModelDownloadStatus(modelName: model.displayName, fraction: 1, isVerifying: true)
                    case .completed: break
                    }
                }
            } catch {
                errorMessage = "Could not download \(model.displayName): \(error)"
                return false
            }
        }
        await reloadModelStatus()
        return true
    }

    /// Clears the inline error banner.
    public func dismissError() { errorMessage = nil }
}
