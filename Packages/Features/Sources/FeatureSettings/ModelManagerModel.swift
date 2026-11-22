import AppCore
import FeatureSupport
import Foundation
import Observation

/// Something to confirm with the user before a download starts (ENG-AC-18, SET edge cases).
public enum DownloadWarning: Hashable, Sendable {
    /// CC-BY-NC or similar: shown before download.
    case nonCommercial(spdx: String)
    /// The model's `minTier` exceeds this Mac's tier.
    case hardwareTier(required: HardwareTier)
    /// Free disk space is below the model size (plus headroom).
    case lowDiskSpace(needed: Int64, available: Int64)
}

public enum DownloadOutcome: Sendable, Equatable {
    case completed
    case needsConfirmation([DownloadWarning])
    case cancelled
    case failed(String)
}

/// Settings → Models: catalog, download lifecycle, deletion, custom import (SET-AC-03/04/05, ENG-AC-03..08).
@MainActor @Observable
public final class ModelManagerModel {
    public struct Progress: Equatable, Sendable {
        public var fraction: Double
        public var bytesReceived: Int64
        public var bytesTotal: Int64?
        public var isVerifying: Bool
        public var startedAt: Date

        public init(fraction: Double, bytesReceived: Int64, bytesTotal: Int64?, isVerifying: Bool, startedAt: Date) {
            self.fraction = fraction
            self.bytesReceived = bytesReceived
            self.bytesTotal = bytesTotal
            self.isVerifying = isVerifying
            self.startedAt = startedAt
        }

        /// Estimated seconds remaining, when enough progress has been made to extrapolate.
        public func eta(now: Date = Date()) -> TimeInterval? {
            guard fraction > 0.02, fraction < 1, !isVerifying else { return nil }
            let elapsed = now.timeIntervalSince(startedAt)
            return elapsed * (1 - fraction) / fraction
        }
    }

    public struct Row: Identifiable, Equatable, Sendable {
        public var descriptor: ModelDescriptor
        public var state: ModelState
        public var progress: Progress?
        public var id: ModelID { descriptor.id }
        public var isInstalled: Bool {
            if case .installed = state { return true }
            return false
        }
    }

    /// This Mac's hardware tier (language availability checks).
    public var tier: HardwareTier { hardware.profile.tier }

    public private(set) var rows: [Row] = []
    public private(set) var usage = DiskUsage(totalBytes: 0, perModel: [:])
    public private(set) var activeModelID: ModelID?
    /// "Recommended for this Mac" per use case (SCR-011): one `ModelRecommender` rule, with a one-line why.
    public private(set) var recommendations: [ModelRecommendation] = []
    public var errorMessage: String?
    /// Set when deleting the active default needs confirmation (ENG-AC-06).
    public var pendingDeletion: ModelDescriptor?

    @ObservationIgnored private let manager: any ModelManaging
    @ObservationIgnored private let hardware: any HardwareTierProviding
    @ObservationIgnored private let store: any SettingsStore
    @ObservationIgnored private let freeDiskBytes: @Sendable () -> Int64?

    public init(
        manager: any ModelManaging, hardware: any HardwareTierProviding, store: any SettingsStore,
        freeDiskBytes: @escaping @Sendable () -> Int64? = ModelManagerModel.systemFreeDiskBytes
    ) {
        self.manager = manager
        self.hardware = hardware
        self.store = store
        self.freeDiskBytes = freeDiskBytes
    }

    public nonisolated static func systemFreeDiskBytes() -> Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: Loading

    public func load() async {
        let catalog = await manager.catalog()
        var built: [Row] = []
        for descriptor in catalog {
            built.append(Row(descriptor: descriptor, state: await manager.state(of: descriptor.id), progress: nil))
        }
        rows = built
        recommendations = ModelRecommendations.compute(catalog: catalog, tier: hardware.profile.tier)
        usage = await manager.diskUsage()
        activeModelID = await PreferredModel.explicitID(for: .file, settings: store)
    }

    /// Follows `stateChanges()` until cancelled.
    public func observe() async {
        for await (id, state) in manager.stateChanges() {
            apply(state: state, to: id)
            usage = await manager.diskUsage()
        }
    }

    public var catalog: [ModelDescriptor] { rows.map(\.descriptor) }

    public func row(_ id: ModelID) -> Row? { rows.first { $0.id == id } }

    /// Where `id` is the recommended default on this Mac (empty for most models).
    public func recommendations(for id: ModelID) -> [ModelRecommendation] { recommendations.filter { $0.model == id } }

    /// Rows for one kind, ASR ordered Recommended, then installed, then the rest (catalog order inside each band).
    public func rows(of kind: ModelKind) -> [Row] {
        let ofKind = rows.filter { $0.descriptor.kind == kind }
        guard kind == .asr else { return ofKind }
        func band(_ row: Row) -> Int { !recommendations(for: row.id).isEmpty ? 0 : row.isInstalled ? 1 : 2 }
        return ofKind.enumerated().sorted { (band($0.element), $0.offset) < (band($1.element), $1.offset) }.map(\.element)
    }

    private func apply(state: ModelState, to id: ModelID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].state = state
        if case .downloading = state {
        } else if rows[index].progress?.isVerifying != true {
            if case .installed = state { rows[index].progress = nil }
        }
    }

    private func refresh(_ id: ModelID) async {
        let state = await manager.state(of: id)
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].state = state
        usage = await manager.diskUsage()
    }

    // MARK: Pre-flight

    /// Warnings to confirm before downloading `id`; empty when the download can start immediately.
    public func preflight(_ id: ModelID) -> [DownloadWarning] {
        guard let descriptor = row(id)?.descriptor else { return [] }
        var warnings: [DownloadWarning] = []
        if descriptor.license.isNonCommercial { warnings.append(.nonCommercial(spdx: descriptor.license.spdx)) }
        if descriptor.minTier > hardware.profile.tier { warnings.append(.hardwareTier(required: descriptor.minTier)) }
        if let free = freeDiskBytes(), free < descriptor.sizeBytes + descriptor.sizeBytes / 5 {
            warnings.append(.lowDiskSpace(needed: descriptor.sizeBytes, available: free))
        }
        return warnings
    }

    // MARK: Download

    /// Downloads `id` (inline progress on its row) and returns once installed. Unconfirmed warnings are returned, not ignored.
    @discardableResult
    public func download(_ id: ModelID, confirmed: Bool = false) async -> DownloadOutcome {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return .failed("Unknown model") }
        if rows[index].isInstalled { return .completed }
        let warnings = preflight(id)
        // Too little disk space is refused outright: confirming cannot help, and the manager would refuse it anyway.
        for case .lowDiskSpace(let needed, let available) in warnings {
            let refusal = ModelPreflightResult(
                model: id, displayName: rows[index].descriptor.displayName, downloadBytes: needed, freeDiskBytes: available,
                issues: [.insufficientDisk(needed: needed + needed / 5, available: available)])
            let reason = ModelConsentText.insufficientDisk(refusal) ?? "Not enough free disk space."
            errorMessage = reason
            return .failed(reason)
        }
        if !confirmed, !warnings.isEmpty { return .needsConfirmation(warnings) }
        if confirmed { await manager.recordConsent(for: id) }  // the consent hook must not ask a second time
        let isRetry: Bool
        if case .failed = rows[index].state { isRetry = true } else { isRetry = false }
        errorMessage = nil
        rows[index].progress = Progress(fraction: 0, bytesReceived: 0, bytesTotal: nil, isVerifying: false, startedAt: Date())
        rows[index].state = .downloading(fraction: 0)
        do {
            for try await event in (isRetry ? manager.retryDownload(id) : manager.ensureAvailable(id)) {
                guard let current = rows.firstIndex(where: { $0.id == id }) else { continue }
                switch event {
                case .progress(let fraction, let received, let total):
                    rows[current].progress?.fraction = fraction
                    rows[current].progress?.bytesReceived = received
                    rows[current].progress?.bytesTotal = total
                    rows[current].progress?.isVerifying = false
                    rows[current].state = .downloading(fraction: fraction)
                case .verifying:
                    rows[current].progress?.isVerifying = true
                case .completed:
                    break
                }
            }
        } catch {
            clearProgress(id)
            await refresh(id)
            if case AppError.cancelled = error { return .cancelled }
            let reason = Self.describe(error)
            errorMessage = reason
            return .failed(reason)
        }
        clearProgress(id)
        await refresh(id)
        if row(id)?.isInstalled == true { return .completed }
        // The stream finished without installing: the user cancelled or paused.
        return .cancelled
    }

    private func clearProgress(_ id: ModelID) {
        if let index = rows.firstIndex(where: { $0.id == id }) { rows[index].progress = nil }
    }

    public func pause(_ id: ModelID) async {
        await manager.pauseDownload(id)
        await refresh(id)
    }

    public func resume(_ id: ModelID) async {
        await manager.resumeDownload(id)
        await refresh(id)
    }

    public func cancel(_ id: ModelID) async {
        await manager.cancelDownload(id)
        clearProgress(id)
        await refresh(id)
    }

    // MARK: Delete & import

    /// Deletes immediately, or asks for confirmation first when `id` is the active default (ENG-AC-06).
    public func requestDelete(_ id: ModelID) async {
        guard let descriptor = row(id)?.descriptor else { return }
        if id == activeModelID {
            pendingDeletion = descriptor
        } else {
            await delete(id)
        }
    }

    public func confirmPendingDeletion() async {
        guard let descriptor = pendingDeletion else { return }
        pendingDeletion = nil
        await delete(descriptor.id)
    }

    private func delete(_ id: ModelID) async {
        do {
            try await manager.delete(id)
            await refresh(id)
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    /// Registers a custom WhisperKit CoreML folder with the chosen languages (ENG-AC-07).
    public func importModel(folder: URL, displayName: String, languages: Set<LanguageCode>) async -> ModelDescriptor? {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !languages.isEmpty else {
            errorMessage = "Enter a name and choose at least one language."
            return nil
        }
        do {
            let descriptor = try await manager.importModel(folder: folder, displayName: name, languages: languages)
            await load()
            return descriptor
        } catch {
            errorMessage = Self.describe(error)
            return nil
        }
    }

    public var totalDiskUsage: Int64 { usage.totalBytes }

    static func describe(_ error: any Error) -> String { ModelDownloadErrorText.message(for: error) }
}
