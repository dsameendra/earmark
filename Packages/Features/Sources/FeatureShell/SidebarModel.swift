import AppCore
import FeatureHome
import FeatureLibrary
import FeatureSupport
import Foundation
import Observation

/// The default speech model as the sidebar footer chip shows it.
public struct SidebarModelChip: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case ready
        case notInstalled
        case downloading(fraction: Double)
        case paused(fraction: Double)
        case failed
    }

    public var name: String
    public var status: Status
    /// "On this Mac · 1.6 GB".
    public var detail: String

    public init(name: String, status: Status, detail: String) {
        self.name = name
        self.status = status
        self.detail = detail
    }

    /// Short status word shown at the chip's trailing edge.
    public var statusText: String {
        switch status {
        case .ready: "Ready"
        case .notInstalled: "Not downloaded"
        case .downloading(let f): "\(Int((f * 100).rounded()))%"
        case .paused: "Paused"
        case .failed: "Failed"
        }
    }

    /// Fraction for the chip's rule: full when ready, the download fraction while downloading, empty otherwise.
    public var fraction: Double {
        switch status {
        case .ready: 1
        case .downloading(let f), .paused(let f): f
        case .notInstalled, .failed: 0
        }
    }

    static func make(model: ModelDescriptor, state: ModelState) -> SidebarModelChip {
        let size = ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .file)
        let status: Status
        switch state {
        case .installed: status = .ready
        case .notInstalled: status = .notInstalled
        case .downloading(let f): status = .downloading(fraction: f)
        case .paused(let f): status = .paused(fraction: f)
        case .failed: status = .failed
        }
        return SidebarModelChip(
            name: model.displayName, status: status, detail: status == .ready ? "On this Mac · \(size)" : "Download · \(size)")
    }
}

/// Live data behind the sidebar: Queue badge, folders and the model chip. Subscribes on its own so the sidebar is
/// correct before Home, Queue or Library have appeared; no polling (jobs and model state are event streams).
@MainActor @Observable
public final class SidebarModel {
    /// Running plus waiting jobs (the Queue badge).
    public private(set) var activeJobs = 0
    public private(set) var folders: [LibraryFolder] = []
    public private(set) var modelChip: SidebarModelChip?

    @ObservationIgnored private let services: AppServices

    public init(services: AppServices) { self.services = services }

    /// Badge text for the Queue row (`nil` hides it).
    public var queueBadge: String? { activeJobs > 0 ? String(activeJobs) : nil }

    /// Loads folders and the model chip, then follows job events and model state changes until cancelled.
    public func run() async {
        let events = services.jobQueue.events()  // subscribe before loading so no update is lost
        let stateChanges = services.models.stateChanges()
        let preferredChanges = services.settings.changes(for: SettingsKey.preferredModel)
        let languageChanges = services.settings.changes(for: SettingsKey.languageMode)
        let folderChanges = services.settings.changes(for: SettingsKey.libraryFolders)
        var jobs: [JobID: Job] = [:]
        for job in await services.jobQueue.jobs() { jobs[job.id] = job }
        activeJobs = Self.activeCount(jobs)
        await reloadFolders()
        await reloadModel()
        let watcher = Task { [weak self] in
            for await (id, _) in stateChanges {
                guard !Task.isCancelled else { return }
                await self?.reloadModel(changed: id)
            }
        }
        let preferredWatcher = Task { [weak self] in
            for await _ in preferredChanges { await self?.reloadModel() }
        }
        let languageWatcher = Task { [weak self] in
            for await _ in languageChanges { await self?.reloadModel() }
        }
        let folderWatcher = Task { [weak self] in
            for await _ in folderChanges { await self?.reloadFolders() }
        }
        defer {
            watcher.cancel()
            preferredWatcher.cancel()
            languageWatcher.cancel()
            folderWatcher.cancel()
        }
        for await event in events {
            switch event {
            case .updated(let job): jobs[job.id] = job
            case .removed(let id): jobs[id] = nil
            }
            activeJobs = Self.activeCount(jobs)
        }
    }

    /// Re-reads the folder list from settings (call after the shell selects Library or the folders change).
    public func reloadFolders() async {
        folders = await services.settings.value(for: SettingsKey.libraryFolders, as: [LibraryFolder].self) ?? []
    }

    func reloadModel(changed: ModelID? = nil) async {
        let catalog = await services.models.catalog()
        guard let model = await PreferredModel.resolve(in: catalog, settings: services.settings) else {
            modelChip = nil
            return
        }
        if let changed, changed != model.id { return }
        modelChip = SidebarModelChip.make(model: model, state: await services.models.state(of: model.id))
    }

    static func activeCount(_ jobs: [JobID: Job]) -> Int {
        jobs.values.filter { $0.deletedAt == nil && ($0.state == .running || $0.state == .pending) }.count
    }
}
