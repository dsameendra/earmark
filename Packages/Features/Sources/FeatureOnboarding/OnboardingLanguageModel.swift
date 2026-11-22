import AppCore
import FeatureSettings
import FeatureSupport
import Foundation
import Network
import Observation
import os

/// Reports whether the Mac has a network path, without using the network (ONB non-functional: no network use until a download starts).
public typealias OnlineCheck = @Sendable () async -> Bool

/// Default `OnlineCheck`: the first `NWPathMonitor` update, or "online" if none arrives quickly.
public enum NetworkReachability {
    public static let systemCheck: OnlineCheck = {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let monitor = NWPathMonitor()
            let resumed = OSAllocatedUnfairLock(initialState: false)
            @Sendable func finish(_ online: Bool) {
                let first = resumed.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                guard first else { return }
                monitor.cancel()
                continuation.resume(returning: online)
            }
            monitor.pathUpdateHandler = { path in finish(path.status == .satisfied) }
            let queue = DispatchQueue(label: "earmark.onboarding.reachability")
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 1) { finish(true) }
        }
    }
}

/// Step 2: language selection, the recommended model per language, and the optional download (ONB-AC-02/03/04/10).
///
/// Recommendations come from `EngineRouter` for this Mac's `HardwareTier`, per language and per use case, so the Apple
/// speech asset appears when the router picks it. When no router is available the model falls back to the largest ASR
/// model in the catalog that covers the language and fits the tier.
@MainActor @Observable
public final class OnboardingLanguageModel {
    public struct LanguageOption: Identifiable, Equatable, Sendable {
        public let code: LanguageCode
        /// Name in the current locale.
        public let name: String
        /// Name in the language itself when it differs (for example Sinhala).
        public let nativeName: String?
        public let isDefault: Bool
        public let isExperimental: Bool
        public var id: String { code.rawValue }
        /// "සිංහල · Sinhala" style label.
        public var label: String { nativeName.map { "\($0) · \(name)" } ?? name }
    }

    public struct Recommendation: Identifiable, Equatable, Sendable {
        public let id: ModelID
        public let name: String
        public let sizeBytes: Int64
        public let languages: [LanguageCode]
        public let isInstalled: Bool
        public let isExperimental: Bool
        /// Apple speech assets are managed by macOS; they have no size of their own.
        public let isSystemManaged: Bool

        public var sizeText: String {
            isSystemManaged || sizeBytes <= 0 ? "Managed by macOS" : ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        }
        public var statusText: String { isInstalled ? "Installed" : "Not downloaded" }
    }

    public enum DownloadPhase: Equatable, Sendable {
        case queued, downloading, paused, verifying, completed
        case failed(String)
        case cancelled
    }

    public struct DownloadProgress: Equatable, Sendable {
        public var phase: DownloadPhase
        public var fraction: Double
        public var bytesReceived: Int64
        public var bytesTotal: Int64?
    }

    public struct DiskWarning: Equatable, Sendable {
        public let needed: Int64
        public let available: Int64
        public var message: String {
            let need = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
            let free = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            return "Not enough free space: the download needs \(need) and \(free) is available."
        }
    }

    // MARK: State

    public private(set) var selected: Set<LanguageCode> = [.english]
    public private(set) var options: [LanguageOption] = []
    public private(set) var moreOptions: [LanguageOption] = []
    public var showsMoreLanguages = false
    public private(set) var recommendations: [Recommendation] = []
    public private(set) var warnings: [String] = []
    public private(set) var downloads: [ModelID: DownloadProgress] = [:]
    public private(set) var isOffline = false
    public private(set) var diskWarning: DiskWarning?
    public private(set) var isLoading = true
    public private(set) var activeModel: ModelID?

    @ObservationIgnored private let models: any ModelManaging
    @ObservationIgnored private let hardware: any HardwareTierProviding
    @ObservationIgnored private let store: any SettingsStore
    @ObservationIgnored private let router: (any EngineRouter)?
    @ObservationIgnored private let isOnline: OnlineCheck
    @ObservationIgnored private let freeDiskBytes: @Sendable () -> Int64?
    @ObservationIgnored private var table = LanguageCapabilityTable(models: [])
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var cancelRequested = false

    public init(
        services: AppServices, router: (any EngineRouter)? = nil, isOnline: @escaping OnlineCheck = NetworkReachability.systemCheck,
        freeDiskBytes: @escaping @Sendable () -> Int64? = ModelManagerModel.systemFreeDiskBytes
    ) {
        models = services.models
        hardware = services.hardware
        store = services.settings
        self.router = router
        self.isOnline = isOnline
        self.freeDiskBytes = freeDiskBytes
    }

    /// A balanced starting set after the user's saved and preferred languages, filtered to actual model support.
    static let commonLanguages: [LanguageCode] = [.english, "es", "fr", "de", "zh", "ja", "ar", "hi", "pt", "ko"]

    // MARK: Loading

    public func load() async {
        table = LanguageCapabilityTable(models: await models.catalog())
        let stored = await store.value(for: SettingsKey.languageMode, as: LanguageMode.self) ?? .default
        switch stored {
        case .single(let code): selected = [code]
        case .multilingual(let set): selected = set.isEmpty ? [.english] : set
        case .autoDetect: selected = [.english]
        }
        buildOptions()
        isOffline = !(await isOnline())
        await recompute()
        isLoading = false
    }

    private func buildOptions() {
        let available = table.languages()
        var featured: [LanguageCode] = []
        let preferred = Locale.preferredLanguages.map { LanguageCode($0).primary }
        let candidates =
            selected.sorted() + preferred + Self.commonLanguages
            + available.sorted { Self.name($0).localizedCompare(Self.name($1)) == .orderedAscending }
        let limit = max(6, selected.count)
        for code in candidates where (available.contains(code) || selected.contains(code)) && !featured.contains(code) {
            guard featured.count < limit else { break }
            featured.append(code)
        }
        let rest = available.subtracting(featured).sorted { Self.name($0).localizedCompare(Self.name($1)) == .orderedAscending }
        options = featured.map(option)
        moreOptions = rest.map(option)
    }

    private func option(_ code: LanguageCode) -> LanguageOption {
        let name = Self.name(code)
        let native = Locale(identifier: code.rawValue).localizedString(forLanguageCode: code.rawValue)
        let coveringModels = table.models(coveringAll: [code])
        return LanguageOption(
            code: code, name: name, nativeName: native.flatMap { $0 == name || code == .english ? nil : $0 },
            isDefault: code == .english, isExperimental: !coveringModels.isEmpty && coveringModels.allSatisfy(\.isExperimental))
    }

    static func name(_ code: LanguageCode) -> String { Locale.current.localizedString(forLanguageCode: code.rawValue) ?? code.rawValue }

    // MARK: Selection (ONB-AC-02)

    public func isSelected(_ code: LanguageCode) -> Bool { selected.contains(code) }

    /// Toggles a language, never leaving the set empty, then updates the recommendation and the stored default.
    public func toggle(_ code: LanguageCode) async {
        if selected.contains(code) {
            guard selected.count > 1 else { return }
            selected.remove(code)
        } else {
            selected.insert(code)
        }
        await store.set(languageMode, for: SettingsKey.languageMode)
        await recompute()
    }

    public var languageMode: LanguageMode { selected.count == 1 ? .single(selected.first ?? .english) : .multilingual(selected) }

    // MARK: Recommendation (ONB-AC-03)

    /// Recomputes the recommended models for the chosen languages and this Mac's tier.
    public func recompute() async {
        let installed = await models.installedModels()
        let tier = hardware.profile.tier
        var order: [ModelID] = []
        var languagesByModel: [ModelID: [LanguageCode]] = [:]
        var notes: [String] = []
        for language in selected.sorted() {
            var picked: [ModelID] = []
            if let router {
                for useCase in [UseCase.file, .live] {
                    let request = RoutingRequest(languageMode: .single(language), useCase: useCase, tier: tier, installedModels: installed)
                    do {
                        let plan = try router.plan(for: request)
                        picked += plan.assignments.compactMap(\.model)
                        notes += plan.warnings
                    } catch {
                        notes.append("No model covers \(Self.name(language)).")
                    }
                }
            } else if let fallback = Self.fallbackModel(for: language, in: table, tier: tier) {
                picked = [fallback]
            }
            for id in picked {
                if languagesByModel[id] == nil { order.append(id) }
                if !(languagesByModel[id]?.contains(language) ?? false) { languagesByModel[id, default: []].append(language) }
            }
        }
        recommendations = order.compactMap { id in
            guard let descriptor = table.models.first(where: { $0.id == id }) else { return nil }
            return Recommendation(
                id: id, name: descriptor.displayName, sizeBytes: descriptor.sizeBytes, languages: languagesByModel[id] ?? [],
                isInstalled: installed.contains(id), isExperimental: descriptor.isExperimental,
                isSystemManaged: descriptor.runtime == .appleAsset)
        }
        var seen = Set<String>()
        warnings = notes.filter { seen.insert($0).inserted }
    }

    /// Catalog-only choice used when no router is injected: the shared ``ModelRecommender`` default for file transcription.
    public static func fallbackModel(for language: LanguageCode, in table: LanguageCapabilityTable, tier: HardwareTier) -> ModelID? {
        ModelRecommender.recommendedModel(for: tier, useCase: .file, language: language, in: table.models)?.id
    }

    /// Bytes still to download for the recommended models.
    public var bytesToDownload: Int64 { recommendations.filter { !$0.isInstalled && !$0.isSystemManaged }.reduce(0) { $0 + $1.sizeBytes } }
    public var totalSizeText: String { ByteCountFormatter.string(fromByteCount: bytesToDownload, countStyle: .file) }
    public var hasPendingDownload: Bool { recommendations.contains { !$0.isInstalled } }
    public var allInstalled: Bool { !recommendations.isEmpty && recommendations.allSatisfy(\.isInstalled) }

    // MARK: Offline (ONB-AC-10)

    public static let offlineNotice =
        "You are offline. Downloads need a connection. You can continue without a model and download one later in Settings."
    public var offlineNotice: String? { isOffline ? Self.offlineNotice : nil }

    // MARK: Download (ONB-AC-04)

    public var isDownloading: Bool { downloadTask != nil }

    /// `true` while the current download is paused.
    public var isPaused: Bool { activeModel.flatMap { downloads[$0]?.phase } == .paused }

    public var errorMessage: String? {
        for case .failed(let reason) in downloads.values.map(\.phase) { return reason }
        return nil
    }

    /// Starts downloading every recommended model that is not installed. Skipping simply means never calling this.
    public func startDownload(confirmLowDisk: Bool = false) async {
        guard downloadTask == nil else { return }
        isOffline = !(await isOnline())
        guard !isOffline else { return }
        let missing = recommendations.filter { !$0.isInstalled }.map(\.id)
        guard !missing.isEmpty else { return }
        let needed = bytesToDownload
        if !confirmLowDisk, needed > 0, let free = freeDiskBytes(), free < needed + needed / 10 {
            diskWarning = DiskWarning(needed: needed, available: free)
            return
        }
        diskWarning = nil
        cancelRequested = false
        for id in missing { downloads[id] = DownloadProgress(phase: .queued, fraction: 0, bytesReceived: 0, bytesTotal: nil) }
        downloadTask = Task { [weak self] in await self?.run(missing) }
    }

    public func dismissDiskWarning() { diskWarning = nil }

    /// Waits for the running download to finish (tests and "Continue" while downloading in the background do not need this).
    public func waitForDownload() async { await downloadTask?.value }

    public func pause() async {
        guard let id = activeModel, downloads[id]?.phase == .downloading else { return }
        downloads[id]?.phase = .paused
        await models.pauseDownload(id)
    }

    public func resume() async {
        guard let id = activeModel, downloads[id]?.phase == .paused else { return }
        downloads[id]?.phase = .downloading
        await models.resumeDownload(id)
    }

    public func cancel() async {
        cancelRequested = true
        let queued = downloads.filter { $0.value.phase == .queued || $0.value.phase == .downloading || $0.value.phase == .paused }
        if let id = activeModel { await models.cancelDownload(id) }
        downloadTask?.cancel()
        for id in queued.keys { downloads[id]?.phase = .cancelled }
    }

    private func run(_ ids: [ModelID]) async {
        for id in ids where !cancelRequested {
            activeModel = id
            downloads[id]?.phase = .downloading
            do {
                for try await event in models.ensureAvailable(id) {
                    switch event {
                    case .progress(let fraction, let received, let total):
                        if downloads[id]?.phase != .paused { downloads[id]?.phase = .downloading }
                        downloads[id]?.fraction = fraction
                        downloads[id]?.bytesReceived = received
                        downloads[id]?.bytesTotal = total
                    case .verifying: downloads[id]?.phase = .verifying
                    case .completed:
                        downloads[id]?.phase = .completed
                        downloads[id]?.fraction = 1
                    }
                }
                if cancelRequested { downloads[id]?.phase = .cancelled }
            } catch {
                if cancelRequested {
                    downloads[id]?.phase = .cancelled
                } else {
                    isOffline = !(await isOnline())
                    downloads[id]?.phase = .failed(isOffline ? Self.offlineNotice : "Download failed: \(error.localizedDescription)")
                    break
                }
            }
        }
        activeModel = nil
        downloadTask = nil
        await recompute()
    }

    /// Progress for a recommendation, if a download was started.
    public func progress(for id: ModelID) -> DownloadProgress? { downloads[id] }
}
