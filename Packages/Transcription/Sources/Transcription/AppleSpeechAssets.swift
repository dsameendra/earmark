import AppCore
import Foundation
import ModelStore
import Speech

/// Raw system view of the on-device speech assets, as reported by `AssetInventory` (before any Earmark-specific mapping).
public enum AppleSpeechSystemStatus: Sendable, Equatable {
    case unsupported, supported, downloading, installed
}

/// Seam over `SpeechTranscriber` / `AssetInventory` so the status, locale and install logic is unit testable without
/// touching the real system assets.
public protocol AppleSpeechAssetBackend: Sendable {
    /// `SpeechTranscriber.isAvailable`.
    var isAvailable: Bool { get }
    func supportedLocales() async -> [Locale]
    func installedLocales() async -> [Locale]
    func status(for locale: Locale) async -> AppleSpeechSystemStatus
    /// Reserves `locale` for this app (`AssetInventory.reserve(locale:)`).
    func reserve(_ locale: Locale) async throws
    /// Downloads and installs the assets for `locale`; returns normally when nothing needs to be installed.
    func install(_ locale: Locale, progress: (@Sendable (Double) -> Void)?) async throws
}

/// The real backend.
public struct SystemAppleSpeechBackend: AppleSpeechAssetBackend {
    public init() {}

    public var isAvailable: Bool { SpeechTranscriber.isAvailable }
    public func supportedLocales() async -> [Locale] { await SpeechTranscriber.supportedLocales }
    public func installedLocales() async -> [Locale] { await SpeechTranscriber.installedLocales }

    public func status(for locale: Locale) async -> AppleSpeechSystemStatus {
        switch await AssetInventory.status(forModules: [Self.transcriber(locale)]) {
        case .unsupported: return .unsupported
        case .supported: return .supported
        case .downloading: return .downloading
        case .installed: return .installed
        @unknown default: return .unsupported
        }
    }

    public func reserve(_ locale: Locale) async throws {
        _ = try await AssetInventory.reserve(locale: locale)
    }

    public func install(_ locale: Locale, progress: (@Sendable (Double) -> Void)?) async throws {
        // `assetInstallationRequest` also reserves the locale for this app, and returns nil when the assets are already there.
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [Self.transcriber(locale)]) else { return }
        let watcher = Task { [progress] in
            while !Task.isCancelled {
                progress?(request.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { watcher.cancel() }
        try await request.downloadAndInstall()
        progress?(1)
    }

    static func transcriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
    }
}

/// Chooses the concrete speech locale for a language code.
///
/// `SpeechTranscriber.supportedLocale(equivalentTo: "en")` returns an arbitrary regional variant (`en_ZA` on the test Mac),
/// which is rarely the one the user installed. The resolver prefers, in order: an exact match when the code carries a
/// region, the user's own region, an already-installed variant, then a deterministic alphabetical pick.
enum AppleSpeechLocaleResolver {
    static func resolve(language: LanguageCode, supported: [Locale], installed: [Locale], preferred: Locale) -> Locale? {
        let normalized = language.rawValue.replacingOccurrences(of: "_", with: "-")
        let parts = normalized.split(separator: "-").map(String.init)
        guard let primary = parts.first?.lowercased() else { return nil }
        let candidates = supported.filter { $0.language.languageCode?.identifier.lowercased() == primary }
            .sorted { $0.identifier < $1.identifier }
        guard !candidates.isEmpty else { return nil }
        if parts.count > 1, let region = parts.last?.uppercased(),
            let exact = candidates.first(where: { $0.region?.identifier.uppercased() == region })
        {
            return exact
        }
        let installedIDs = Set(installed.map { key($0) })
        let preferredRegion = preferred.region?.identifier.uppercased()
        let sameLanguageAsPreferred = preferred.language.languageCode?.identifier.lowercased() == primary
        if sameLanguageAsPreferred, let match = candidates.first(where: { $0.region?.identifier.uppercased() == preferredRegion }) {
            return match
        }
        if let match = candidates.first(where: { installedIDs.contains(key($0)) && $0.region?.identifier.uppercased() == "US" }) {
            return match
        }
        if let match = candidates.first(where: { installedIDs.contains(key($0)) }) { return match }
        return candidates.first { $0.region?.identifier.uppercased() == "US" } ?? candidates.first
    }

    static func key(_ locale: Locale) -> String { locale.identifier.replacingOccurrences(of: "-", with: "_").lowercased() }
}

/// User-facing explanations for Apple speech problems (shown in Settings > Models and live/dictation notices).
public enum AppleSpeechMessages {
    public static let unavailableNotice = "Apple's on-device speech isn't available on this Mac; using Whisper."
    public static let notInstalledNotice =
        "Apple's on-device speech isn't installed for this language yet; using Whisper. Install it in Settings > Models."
    public static let systemSettingsHint =
        "Check System Settings > Keyboard > Dictation (and Siri & Apple Intelligence language) and make sure the language is enabled."

    static func unavailable(language: LanguageCode?) -> String {
        "Apple's on-device speech isn't available on this Mac\(language.map { " for \($0.rawValue)" } ?? ""). \(systemSettingsHint)"
    }

    /// Install failure text including the underlying NSError domain/code, so a bug report carries the exact cause.
    static func installFailure(_ error: any Error) -> String {
        let ns = error as NSError
        let detail = ns.localizedDescription
        return "Apple's on-device speech couldn't be installed: \(detail) [\(ns.domain) \(ns.code)]. "
            + "Check your network connection and free disk space, then Retry. \(systemSettingsHint)"
    }
}

/// Cached per-language readiness of Apple speech, read synchronously by ``AppleAwareEngineRouter``.
public final class AppleSpeechReadiness: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [LanguageCode: AppleSpeechAssetStatus] = [:]

    public init() {}

    /// The last known status for `language`, or `nil` when never checked (not safe to use until refreshed).
    public func status(for language: LanguageCode) -> AppleSpeechAssetStatus? {
        lock.lock()
        defer { lock.unlock() }
        return statuses[language]
    }

    public func set(_ status: AppleSpeechAssetStatus, for language: LanguageCode) {
        lock.lock()
        statuses[language] = status
        lock.unlock()
    }

    /// Re-reads the status of each language from the engine.
    public func refresh(engine: AppleSpeechEngine, languages: [LanguageCode]) async {
        for language in languages { set(await engine.assetStatus(for: language), for: language) }
    }
}

/// Wraps ``DefaultEngineRouter`` and routes away from Apple Speech when it cannot be used on this Mac (unavailable,
/// language unsupported, assets not installed): live and dictation then fall back to WhisperKit with a visible notice.
public struct AppleAwareEngineRouter: EngineRouter {
    private let full: DefaultEngineRouter
    private let withoutApple: DefaultEngineRouter
    private let readiness: AppleSpeechReadiness
    private let engine: AppleSpeechEngine?

    public init(
        catalog: [ModelDescriptor] = BuiltInCatalog.models, readiness: AppleSpeechReadiness,
        engine: AppleSpeechEngine? = nil
    ) {
        full = DefaultEngineRouter(catalog: catalog)
        withoutApple = DefaultEngineRouter(catalog: catalog.filter { $0.id != RoutingTargets.appleSpeech })
        self.readiness = readiness
        self.engine = engine
    }

    public func preparedPlan(for request: RoutingRequest) async throws -> EnginePlan {
        if request.useCase != .file, let engine {
            let languages: [LanguageCode]
            switch request.languageMode {
            case .single(let language): languages = [language]
            case .multilingual(let set): languages = Array(set)
            case .autoDetect: languages = []
            }
            await readiness.refresh(engine: engine, languages: languages)
        }
        try Task.checkCancellation()
        return try plan(for: request)
    }

    public func plan(for request: RoutingRequest) throws -> EnginePlan {
        guard request.explicitModel == nil, request.useCase != .file, let blocked = blockedStatus(request) else {
            return try full.plan(for: request)
        }
        var plan = try withoutApple.plan(for: request)
        let notice =
            blocked == .notInstalled || blocked == .downloading
            ? AppleSpeechMessages.notInstalledNotice : AppleSpeechMessages.unavailableNotice
        plan.warnings.insert(notice, at: 0)
        return plan
    }

    /// The first non-usable cached status among the requested languages, or `nil` when Apple may be used.
    private func blockedStatus(_ request: RoutingRequest) -> AppleSpeechAssetStatus? {
        let languages: [LanguageCode]
        switch request.languageMode {
        case .single(let language): languages = [language]
        case .multilingual(let set): languages = Array(set)
        case .autoDetect: return nil
        }
        for language in languages where language.primary != .sinhala {
            let status = readiness.status(for: language) ?? .notInstalled
            if status != .installed { return status }
        }
        return nil
    }
}

/// `ModelManager`'s hook for the system-managed Apple speech model: reports whether the user's language is installed and
/// performs the user-initiated install through ``AppleSpeechEngine/installAssets(for:progress:)``.
public struct AppleSpeechAssetProvider: AppleAssetProviding {
    private let engine: AppleSpeechEngine
    private let readiness: AppleSpeechReadiness?
    private let language: @Sendable () -> LanguageCode

    /// - Parameter language: The language whose assets represent the "Apple Speech" model; defaults to the system language.
    public init(
        engine: AppleSpeechEngine, readiness: AppleSpeechReadiness? = nil,
        language: @escaping @Sendable () -> LanguageCode = { LanguageCode(Locale.current.language.languageCode?.identifier ?? "en") }
    ) {
        self.engine = engine
        self.readiness = readiness
        self.language = language
    }

    private func effectiveLanguage() async -> LanguageCode {
        let preferred = language()
        if await engine.assetStatus(for: preferred) == .unsupported { return .english }
        return preferred
    }

    public func isInstalled(_ model: ModelID) async -> Bool {
        guard model == RoutingTargets.appleSpeech else { return false }
        let language = await effectiveLanguage()
        let status = await engine.assetStatus(for: language)
        readiness?.set(status, for: language)
        return status == .installed
    }

    public func install(_ model: ModelID, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard model == RoutingTargets.appleSpeech else {
            throw AppError.modelDownloadFailed(model, reason: "Choose a language pair in Live captions or Translate to prepare Apple Translation packs.")
        }
        let language = await effectiveLanguage()
        try await engine.installAssets(for: language, progress: progress)
        readiness?.set(await engine.assetStatus(for: language), for: language)
    }
}
