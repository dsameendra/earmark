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
    public var statusLabel: String?

    public init(name: String, status: Status, detail: String, statusLabel: String? = nil) {
        self.name = name
        self.status = status
        self.detail = detail
        self.statusLabel = statusLabel
    }

    /// Short status word shown at the chip's trailing edge.
    public var statusText: String {
        if let statusLabel { return statusLabel }
        return switch status {
        case .ready: "Ready"
        case .notInstalled: "Not downloaded"
        case .downloading: "\(Int((fraction * 100).rounded()))%"
        case .paused: "Paused"
        case .failed: "Failed"
        }
    }

    /// Fraction for the chip's rule: full when ready, the download fraction while downloading, empty otherwise.
    public var fraction: Double {
        switch status {
        case .ready: 1
        case .downloading(let f), .paused(let f): f.isFinite ? min(1, max(0, f)) : 0
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
        let detail: String
        switch state {
        case .installed: detail = model.runtime == .appleAsset ? "Managed by macOS" : "On this Mac · \(size)"
        case .notInstalled: detail = model.runtime == .appleAsset ? "Language assets managed by macOS" : "Download required · \(size)"
        case .downloading: detail = "Downloading · \(size)"
        case .paused: detail = "Download paused · \(size)"
        case .failed(let reason): detail = reason
        }
        return SidebarModelChip(
            name: model.displayName, status: status, detail: detail,
            statusLabel: model.runtime == .appleAsset && status == .notInstalled ? "Needs assets" : nil)
    }

    static func make(models: [ModelDescriptor], states: [ModelID: ModelState]) -> SidebarModelChip {
        if models.count == 1, let model = models.first { return make(model: model, state: states[model.id] ?? .notInstalled) }
        guard !models.isEmpty else {
            return SidebarModelChip(name: "Choose a speech model", status: .notInstalled, detail: "No compatible file model is available")
        }
        let chips = models.map { make(model: $0, state: states[$0.id] ?? .notInstalled) }
        let ready = chips.filter { $0.status == .ready }.count
        let status: Status
        if chips.contains(where: { $0.status == .failed }) {
            status = .failed
        } else if chips.contains(where: {
            if case .downloading = $0.status { return true }
            return false
        }) {
            status = .downloading(fraction: chips.map(\.fraction).reduce(0, +) / Double(chips.count))
        } else if chips.contains(where: {
            if case .paused = $0.status { return true }
            return false
        }) {
            status = .paused(fraction: chips.map(\.fraction).reduce(0, +) / Double(chips.count))
        } else {
            status = ready == chips.count ? .ready : .notInstalled
        }
        return SidebarModelChip(
            name: "Automatic · \(models.count) models", status: status,
            detail: "\(ready) of \(models.count) ready · " + models.map(\.displayName).joined(separator: ", "))
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
        let models = await PreferredModel.fileModels(in: catalog, settings: services.settings, tier: services.hardware.profile.tier)
        if let changed, !models.contains(where: { $0.id == changed }) { return }
        var states: [ModelID: ModelState] = [:]
        for model in models { states[model.id] = await services.models.state(of: model.id) }
        modelChip = SidebarModelChip.make(models: models, states: states)
    }

    static func activeCount(_ jobs: [JobID: Job]) -> Int {
        jobs.values.filter { $0.deletedAt == nil && ($0.state == .running || $0.state == .pending) }.count
    }
}
