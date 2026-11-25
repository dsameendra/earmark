import AppCore
import EarmarkTranslation
import FeatureSupport
import Foundation
import ModelStore
import Observation
import SwiftUI
@preconcurrency import Translation

/// Translation wiring: the router (Apple first, bundled native NLLB for Sinhala), readiness for the UI,
/// the `.translate` job handler and Apple language-pack installation.
struct TranslationRuntime: Sendable {
    let router: any TranslationRouter
    let service: AppTranslationService
    let packs: ApplePackInstaller
    let nllbEnabled: Bool

    /// - Parameter nllbPython: value of the `dev.nllbPython` setting (the `EARMARK_DEV_NLLB_PYTHON` environment variable also enables it).
    @MainActor
    static func make(models: any ModelManaging, settings: any SettingsStore, nllbPython: String?) -> TranslationRuntime {
        let apple = AppleTranslationEngine()
        let nativePool = BundledNLLBRuntime.pool()
        // The native helper is bundled and signed with the app; Python remains an explicit development override.
        #if DEBUG
            let runtime = NLLBDevRuntime.runtime(settingValue: nllbPython) ?? nativePool?.runtime(profile: .nllb)
        #else
            let runtime = nativePool?.runtime(profile: .nllb)
        #endif
        let nllb = runtime.map { NLLBEngine(models: models, runtime: $0) }
        let madlad = nativePool.map { MADLADEngine(models: models, runtime: $0.runtime(profile: .madlad)) }
        let opus = nativePool.map { OPUSTranslationEngine(models: models, runtime: $0.runtime(profile: .marian)) }
        // Hy-MT2 and TranslateGemma run in the isolated text worker and offer only their screened directions.
        let generative = nativePool.map { GenerativeTranslationEngine.all(models: models, pool: $0) } ?? []
        var additional: [any TranslationEngine] = []
        if let opus { additional.append(opus) }
        if let madlad { additional.append(madlad) }
        additional.append(contentsOf: generative)
        let router = DefaultTranslationRouter(
            apple: apple, nllb: nllb,
            additional: additional,
            selectedEngine: {
                let choice = await settings.value(for: SettingsKey.translationEngine, as: String.self) ?? "auto"
                switch choice {
                case "auto", "": return nil
                case "apple": return TranslationEngineIDs.apple
                default: return EngineID(choice)
                }
            },
            isAllowed: { engine in
                if engine == TranslationEngineIDs.nllb {
                    return await settings.value(for: SettingsKey.translationAllowNonCommercial, as: Bool.self) ?? false
                }
                return true
            },
            isReady: { engine, pair in
                if engine == TranslationEngineIDs.apple {
                    return await SystemAppleTranslationBackend().status(from: pair.source.translationIdentity, to: pair.target.translationIdentity) == .installed
                }
                let model: ModelID?
                switch engine {
                case TranslationEngineIDs.nllb: model = TranslationEngineIDs.nllbModel
                case "madlad": model = MADLADEngine.modelID
                case "opus-mt": model = OPUSTranslationEngine.model(for: pair)
                default: model = generative.first { $0.id == engine }?.modelID
                }
                guard let model else { return false }
                if case .installed = await models.state(of: model) { return true }
                return false
            })
        let packs = ApplePackInstaller()
        let service = AppTranslationService(models: models, nllb: nllb, madlad: madlad, opus: opus, generative: generative, packs: packs, settings: settings)
        return TranslationRuntime(router: router, service: service, packs: packs, nllbEnabled: nllb != nil)
    }
}

/// `TranslationPreparing`: what each target language still needs (TRN-AC-03, TRN-AC-15).
final class AppTranslationService: TranslationPreparing, Sendable {
    static let sinhalaUnavailable = "Translation for this language pair is unavailable in this build."

    private let models: any ModelManaging
    private let nllb: NLLBEngine?
    private let madlad: MADLADEngine?
    private let opus: OPUSTranslationEngine?
    private let generative: [GenerativeTranslationEngine]
    private let packs: ApplePackInstaller
    private let backend = SystemAppleTranslationBackend()
    private let settings: any SettingsStore

    init(models: any ModelManaging, nllb: NLLBEngine?, madlad: MADLADEngine? = nil, opus: OPUSTranslationEngine? = nil, generative: [GenerativeTranslationEngine] = [], packs: ApplePackInstaller, settings: any SettingsStore) {
        self.models = models
        self.nllb = nllb
        self.madlad = madlad
        self.opus = opus
        self.generative = generative
        self.packs = packs
        self.settings = settings
    }

    func targets(from source: LanguageCode) async -> [(language: LanguageCode, readiness: TranslationReadiness)] {
        var candidates = await backend.supportedLanguages().filter { !LanguagePair(source: source, target: $0).isSameWrittenLanguage }
        candidates.formUnion(NLLBLanguages.defaultLanguages.filter { !LanguagePair(source: source, target: $0).isSameWrittenLanguage })
        if madlad != nil { candidates.formUnion(MADLADLanguages.languages.filter { !LanguagePair(source: source, target: $0).isSameWrittenLanguage }) }
        if opus != nil {
            candidates.formUnion(OPUSTranslationEngine.modelsByPair.keys.filter { $0.source == source }.map(\.target))
        }
        for engine in generative {
            candidates.formUnion(await engine.supportedPairs().filter { $0.source == source }.map(\.target))
        }
        var out: [(language: LanguageCode, readiness: TranslationReadiness)] = []
        for language in candidates.sorted() {
            out.append((language, await readiness(source: source, target: language)))
        }
        return out
    }

    func readiness(source: LanguageCode, target: LanguageCode) async -> TranslationReadiness {
        let (s, t) = (source.translationIdentity, target.translationIdentity)
        guard !LanguagePair(source: source, target: target).isSameWrittenLanguage else { return .unavailable(reason: "The source and target language are the same.") }
        let choice = await settings.value(for: SettingsKey.translationEngine, as: String.self) ?? "auto"
        if choice == "opus-mt" {
            let pair = LanguagePair(source: source, target: target)
            guard let opus, await opus.supports(pair), let model = OPUSTranslationEngine.model(for: pair) else {
                return .unavailable(reason: "Add an OPUS pack for this exact language direction in Settings > Models.")
            }
            return await modelReadiness(model)
        }
        if choice == "madlad" {
            guard let madlad, await madlad.supports(LanguagePair(source: source, target: target)) else {
                return .unavailable(reason: "MADLAD does not support this language pair or language variant in this build.")
            }
            return await modelReadiness(MADLADEngine.modelID)
        }
        if let engine = generative.first(where: { $0.id.rawValue == choice }) {
            guard await engine.supports(LanguagePair(source: source, target: target)) else {
                return .unavailable(reason: "This model has not passed Earmark's quality screen for this language direction.")
            }
            return await modelReadiness(engine.modelID)
        }
        if choice == "nllb" {
            guard await nllbAllowed else { return .unavailable(reason: "Enable non-commercial models in Settings > Translation to use NLLB.") }
            guard let nllb, await nllb.supports(LanguagePair(source: source, target: target)) else {
                return .unavailable(reason: "NLLB does not support this language pair in this build.")
            }
            return await nllbModelReadiness()
        }
        if choice == "apple" {
            switch await backend.status(from: s, to: t) {
            case .installed: return .ready
            case .supported: return .needsApplePack(source: s, target: t)
            case .unsupported: return .unavailable(reason: "Apple Translation does not support this language pair.")
            }
        }
        guard choice == "auto" || choice.isEmpty else {
            return .unavailable(reason: "The selected translation engine is not available in this build.")
        }
        if s.primary == .sinhala || t.primary == .sinhala {
            if let local = await localReadiness(source: source, target: target) { return local }
            return await sinhalaReadiness(source, target)
        }
        switch await backend.status(from: s, to: t) {
        case .installed: return .ready
        case .supported:
            if let local = await localReadiness(source: source, target: target), case .ready = local { return local }
            return .needsApplePack(source: s, target: t)
        case .unsupported:
            if let local = await localReadiness(source: source, target: target) { return local }
            return .unavailable(reason: "Apple Translation does not support this language pair.")
        }
    }

    private func localReadiness(source: LanguageCode, target: LanguageCode) async -> TranslationReadiness? {
        let pair = LanguagePair(source: source, target: target)
        var candidates: [ModelID] = []
        if let nllb, await nllbAllowed, await nllb.supports(pair) { candidates.append(TranslationEngineIDs.nllbModel) }
        if let opus, await opus.supports(pair), let model = OPUSTranslationEngine.model(for: pair) { candidates.append(model) }
        if let madlad, await madlad.supports(pair) { candidates.append(MADLADEngine.modelID) }
        for engine in generative where await engine.supports(pair) { candidates.append(engine.modelID) }
        for model in candidates {
            if case .installed = await models.state(of: model) { return .ready }
        }
        return candidates.first.map { .needsModel($0) }
    }

    private func modelReadiness(_ model: ModelID) async -> TranslationReadiness {
        if case .installed = await models.state(of: model) { return .ready }
        return .needsModel(model)
    }

    /// Sinhala goes through NLLB (directly, or via English for other languages, where the English leg runs on Apple).
    private func sinhalaReadiness(_ s: LanguageCode, _ t: LanguageCode) async -> TranslationReadiness {
        guard let nllb else { return .unavailable(reason: Self.sinhalaUnavailable) }
        let other = s.primary == .sinhala ? t : s
        if await !nllb.supports(LanguagePair(source: s, target: t)) {
            guard other != .english,
                await nllb.supports(LanguagePair(source: s.primary == .sinhala ? s : .english, target: s.primary == .sinhala ? .english : t))
            else { return .unavailable(reason: "Sinhala to or from \(other.rawValue) is not supported.") }
            let leg = s.primary == .sinhala ? LanguagePair(source: .english, target: t) : LanguagePair(source: s, target: .english)
            switch await backend.status(from: leg.source, to: leg.target) {
            case .installed: break
            case .supported: return .needsApplePack(source: leg.source, target: leg.target)
            case .unsupported: return .unavailable(reason: "Sinhala to or from \(other.rawValue) is not supported.")
            }
        }
        return await nllbModelReadiness()
    }

    private var nllbAllowed: Bool {
        get async { await settings.value(for: SettingsKey.translationAllowNonCommercial, as: Bool.self) ?? false }
    }

    private func nllbModelReadiness() async -> TranslationReadiness {
        guard await nllbAllowed else { return .unavailable(reason: "Enable non-commercial models in Settings > Translation to use NLLB.") }
        if case .installed = await models.state(of: TranslationEngineIDs.nllbModel) { return .ready }
        return .needsModel(TranslationEngineIDs.nllbModel)
    }

    func prepareApplePack(source: LanguageCode, target: LanguageCode) async -> Bool {
        await packs.install(source: source, target: target)
    }
}

// MARK: - Apple language packs

/// Installs Apple Translation language packs through the system download sheet (TRN-AC-15). The sheet needs a SwiftUI
/// `.translationTask` host in a window: `TranslationPackHost` is attached to the main window's content.
@MainActor @Observable
final class ApplePackInstaller {
    var configuration: TranslationSession.Configuration?
    @ObservationIgnored private var waiter: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var hostStarted = false
    @ObservationIgnored private var watchdog: Task<Void, Never>?

    /// Shows the system sheet for the pair and returns whether the pack is installed afterwards.
    func install(source: LanguageCode, target: LanguageCode) async -> Bool {
        waiter?.resume(returning: false)
        hostStarted = false
        let new = TranslationSession.Configuration(source: Self.language(source), target: Self.language(target))
        // If no host view picks the configuration up (the main window is gone) nothing would ever resume the caller.
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, !self.hostStarted else { return }
            self.finish(installed: false)
        }
        return await withCheckedContinuation { continuation in
            waiter = continuation
            if configuration?.source == new.source, configuration?.target == new.target {
                configuration?.invalidate()
            } else {
                configuration = new
            }
        }
    }

    /// Called by the host once the system sheet finished (or failed) for the current configuration.
    func finish(installed: Bool) {
        watchdog?.cancel()
        waiter?.resume(returning: installed)
        waiter = nil
    }

    /// The host received the session: the system sheet is up and the user is in charge of how long it takes.
    func hostDidStart() { hostStarted = true }

    private static func language(_ code: LanguageCode) -> Locale.Language {
        Locale.Language(identifier: code.rawValue == "zh" ? "zh-Hans" : code.rawValue)
    }
}

/// Zero-size view that hosts the `.translationTask` used to install language packs.
struct TranslationPackHost: View {
    let installer: ApplePackInstaller

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(installer.configuration) { session in
                installer.hostDidStart()
                var installed = false
                do {
                    try await session.prepareTranslation()
                    installed = true
                } catch {
                    AppLog.logger("translation").error("Language pack install failed: \(String(describing: error), privacy: .public)")
                }
                installer.finish(installed: installed)
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Dictation timeout

/// Wraps a router so a translation that takes longer than `limit` fails (DICT-AC-08): dictation then inserts the original.
struct TimeLimitedTranslationRouter: TranslationRouter {
    let base: any TranslationRouter
    var limit: Duration = .seconds(3)

    func engine(for pair: LanguagePair) async throws -> any TranslationEngine {
        TimeLimitedEngine(inner: try await base.engine(for: pair), limit: limit)
    }

    private struct TimeLimitedEngine: TranslationEngine {
        let inner: any TranslationEngine
        let limit: Duration
        var id: EngineID { inner.id }
        func supportedPairs() async -> Set<LanguagePair> { await inner.supportedPairs() }

        func translate(
            items: [TranslationItem], from: LanguageCode, to: LanguageCode
        ) -> AsyncThrowingStream<TranslatedSegment, any Error> {
            let (inner, limit) = (inner, limit)
            return AsyncThrowingStream { continuation in
                let work = Task {
                    do {
                        for try await out in inner.translate(items: items, from: from, to: to) { continuation.yield(out) }
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                let timer = Task {
                    try? await Task.sleep(for: limit)
                    if !work.isCancelled {
                        work.cancel()
                        continuation.finish(throwing: AppError.other("Translation took longer than \(limit)."))
                    }
                }
                continuation.onTermination = { _ in
                    work.cancel()
                    timer.cancel()
                }
            }
        }
    }
}
