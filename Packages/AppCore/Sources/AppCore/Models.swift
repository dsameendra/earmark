import Foundation

// MARK: - Hardware

public enum HardwareTier: String, Codable, Sendable, Comparable, CaseIterable {
    case tier8, tier16, tier32Plus
    private var rank: Int {
        switch self {
        case .tier8: 0
        case .tier16: 1
        case .tier32Plus: 2
        }
    }
    public static func < (l: Self, r: Self) -> Bool { l.rank < r.rank }
}

public struct HardwareProfile: Sendable, Hashable, Codable {
    public var chip: String
    public var memoryBytes: UInt64
    public var performanceCores: Int
    public var tier: HardwareTier
    public init(chip: String, memoryBytes: UInt64, performanceCores: Int, tier: HardwareTier) {
        self.chip = chip
        self.memoryBytes = memoryBytes
        self.performanceCores = performanceCores
        self.tier = tier
    }
    /// ≤ 11 GB → tier8, ≤ 24 GB → tier16, otherwise tier32Plus (ADR-007; 18 GB dev machine = tier16).
    public static func tier(forMemoryBytes bytes: UInt64) -> HardwareTier {
        let gb = Double(bytes) / 1_073_741_824
        return gb <= 11 ? .tier8 : (gb <= 24 ? .tier16 : .tier32Plus)
    }
}

public enum ThermalPressure: Sendable { case nominal, fair, serious, critical }

public protocol HardwareTierProviding: Sendable {
    var profile: HardwareProfile { get }
    /// Emits on memory-pressure warnings so the model manager can unload models.
    func memoryPressure() -> AsyncStream<Void>
    func thermalPressure() -> AsyncStream<ThermalPressure>
    func isOnBattery() -> Bool
}

// MARK: - Models

public enum ModelKind: String, Codable, Sendable { case asr, diarization, translation, languageID, vad }
public enum ModelRuntime: String, Codable, Sendable { case coreML, mlx, appleAsset, gguf, other }

public struct LicenseInfo: Hashable, Codable, Sendable {
    public var spdx: String  // e.g. "MIT", "CC-BY-NC-4.0"
    public var isNonCommercial: Bool
    public var attribution: String?
    public init(spdx: String, isNonCommercial: Bool = false, attribution: String? = nil) {
        self.spdx = spdx
        self.isNonCommercial = isNonCommercial
        self.attribution = attribution
    }
}

public struct ModelDescriptor: Hashable, Codable, Sendable, Identifiable {
    public var id: ModelID
    public var displayName: String
    public var kind: ModelKind
    public var runtime: ModelRuntime
    /// Engine that loads this model.
    public var engine: EngineID?
    /// Languages covered (ASR/translation source side). Drives `LanguageCapabilityTable` (ADR-008).
    public var languages: Set<LanguageCode>
    public var sizeBytes: Int64
    public var license: LicenseInfo
    public var minTier: HardwareTier
    public var sourceURL: URL?
    public var sha256: String?
    public var isExperimental: Bool
    public var notes: String
    public var isCustom: Bool
    /// Structured capabilities (SCR-011). Persisted descriptors written before SCR-011 decode to ``ModelCapabilities/standard``.
    public var capabilities: ModelCapabilities
    /// Repo-relative path prefixes to download when `sourceURL` points at a Hugging Face repository (or revision). Empty means
    /// everything under `sourceURL`. A prefix matches the file or directory of that exact path (SCR-011).
    public var downloadInclude: [String]
    public init(
        id: ModelID, displayName: String, kind: ModelKind, runtime: ModelRuntime, engine: EngineID? = nil,
        languages: Set<LanguageCode>, sizeBytes: Int64, license: LicenseInfo, minTier: HardwareTier = .tier8,
        sourceURL: URL? = nil, sha256: String? = nil, isExperimental: Bool = false, notes: String = "", isCustom: Bool = false,
        capabilities: ModelCapabilities = .standard, downloadInclude: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.runtime = runtime
        self.engine = engine
        self.languages = languages
        self.sizeBytes = sizeBytes
        self.license = license
        self.minTier = minTier
        self.sourceURL = sourceURL
        self.sha256 = sha256
        self.isExperimental = isExperimental
        self.notes = notes
        self.isCustom = isCustom
        self.capabilities = capabilities
        self.downloadInclude = downloadInclude
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, kind, runtime, engine, languages, sizeBytes, license, minTier, sourceURL, sha256, isExperimental
        case notes, isCustom, capabilities, downloadInclude
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(ModelID.self, forKey: .id), displayName: try c.decode(String.self, forKey: .displayName),
            kind: try c.decode(ModelKind.self, forKey: .kind), runtime: try c.decode(ModelRuntime.self, forKey: .runtime),
            engine: try c.decodeIfPresent(EngineID.self, forKey: .engine),
            languages: try c.decode(Set<LanguageCode>.self, forKey: .languages), sizeBytes: try c.decode(Int64.self, forKey: .sizeBytes),
            license: try c.decode(LicenseInfo.self, forKey: .license), minTier: try c.decode(HardwareTier.self, forKey: .minTier),
            sourceURL: try c.decodeIfPresent(URL.self, forKey: .sourceURL), sha256: try c.decodeIfPresent(String.self, forKey: .sha256),
            isExperimental: try c.decode(Bool.self, forKey: .isExperimental), notes: try c.decode(String.self, forKey: .notes),
            isCustom: try c.decode(Bool.self, forKey: .isCustom),
            capabilities: try c.decodeIfPresent(ModelCapabilities.self, forKey: .capabilities) ?? .standard,
            downloadInclude: try c.decodeIfPresent([String].self, forKey: .downloadInclude) ?? [])
    }
}

public enum ModelState: Sendable, Equatable {
    case notInstalled
    case downloading(fraction: Double)
    case paused(fraction: Double)
    case installed(bytesOnDisk: Int64)
    case failed(reason: String)
}

public enum ModelDownloadEvent: Sendable, Equatable {
    case progress(fraction: Double, bytesReceived: Int64, bytesTotal: Int64?)
    case verifying
    case completed
}

public struct DiskUsage: Sendable, Equatable {
    public var totalBytes: Int64
    public var perModel: [ModelID: Int64]
    public init(totalBytes: Int64, perModel: [ModelID: Int64]) {
        self.totalBytes = totalBytes
        self.perModel = perModel
    }
}

/// Owns model catalog, downloads (pause/resume, checksum), deletion, custom import and LRU residency.
/// Selecting an undownloaded model must go through `ensureAvailable` so the UI can show progress and continue.
public protocol ModelManaging: Sendable {
    func catalog() async -> [ModelDescriptor]
    func state(of model: ModelID) async -> ModelState
    func stateChanges() -> AsyncStream<(ModelID, ModelState)>
    func installedModels() async -> Set<ModelID>
    /// Downloads if needed, verifying checksum; finishes immediately if already installed.
    func ensureAvailable(_ model: ModelID) -> AsyncThrowingStream<ModelDownloadEvent, any Error>
    func pauseDownload(_ model: ModelID) async
    func resumeDownload(_ model: ModelID) async
    func cancelDownload(_ model: ModelID) async
    func delete(_ model: ModelID) async throws
    /// Imports a user-supplied model folder (e.g. a converted WhisperKit CoreML Sinhala fine-tune).
    func importModel(folder: URL, displayName: String, languages: Set<LanguageCode>) async throws -> ModelDescriptor
    func diskUsage() async -> DiskUsage
    /// Local path of an installed model, for engines.
    func location(of model: ModelID) async throws -> URL
    /// Licence, hardware and disk checks to run (and show) **before** `ensureAvailable` (SCR-011). Never touches the network.
    func preflight(_ model: ModelID) async -> ModelPreflightResult
    /// Restarts a failed download from a clean state (stale resume data discarded). Same events as `ensureAvailable`.
    func retryDownload(_ model: ModelID) -> AsyncThrowingStream<ModelDownloadEvent, any Error>
}

extension ModelManaging {
    /// Default for managers without a policy: nothing to confirm.
    public func preflight(_ model: ModelID) async -> ModelPreflightResult {
        let descriptor = await catalog().first { $0.id == model }
        return ModelPreflightResult(model: model, displayName: descriptor?.displayName ?? model.rawValue, downloadBytes: 0)
    }
    public func retryDownload(_ model: ModelID) -> AsyncThrowingStream<ModelDownloadEvent, any Error> { ensureAvailable(model) }
}

// MARK: - Language ↔ model capability (ADR-008)

/// Pure capability table derived from model descriptors; drives both directions of the language/model pickers.
public struct LanguageCapabilityTable: Sendable {
    public let models: [ModelDescriptor]
    public init(models: [ModelDescriptor]) { self.models = models }

    /// All languages any model of `kind` supports (language picker when no model is chosen).
    public func languages(kind: ModelKind = .asr) -> Set<LanguageCode> {
        models.filter { $0.kind == kind && $0.isRunnable }.reduce(into: Set<LanguageCode>()) { $0.formUnion($1.languages) }
    }
    /// Languages a specific model supports (language picker after a model is chosen).
    public func languages(forModel id: ModelID) -> Set<LanguageCode> {
        models.first { $0.id == id && $0.isRunnable }?.languages ?? []
    }
    /// Models that cover **all** the requested languages (model picker after languages are chosen).
    public func models(coveringAll languages: Set<LanguageCode>, kind: ModelKind = .asr) -> [ModelDescriptor] {
        models.filter { $0.kind == kind && $0.isRunnable && languages.isSubset(of: $0.languages) }
    }
}
