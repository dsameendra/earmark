import AppCore
import AudioCapture
import Foundation
import Testing

@testable import Transcription

/// Controllable stand-in for `AssetInventory`.
final class FakeSpeechBackend: AppleSpeechAssetBackend, @unchecked Sendable {
    var isAvailable = true
    var supported: [Locale] = ["en_US", "en_ZA", "en_GB", "fr_FR"].map(Locale.init(identifier:))
    var installed: [Locale] = ["en_US"].map(Locale.init(identifier:))
    var systemStatus: AppleSpeechSystemStatus = .supported
    var installError: (any Error)?
    private(set) var reserved: [String] = []
    private(set) var installRequests: [String] = []

    func supportedLocales() async -> [Locale] { supported }
    func installedLocales() async -> [Locale] { installed }
    func status(for locale: Locale) async -> AppleSpeechSystemStatus { systemStatus }
    func reserve(_ locale: Locale) async throws { reserved.append(locale.identifier) }
    func install(_ locale: Locale, progress: (@Sendable (Double) -> Void)?) async throws {
        installRequests.append(locale.identifier)
        if let installError { throw installError }
        progress?(1)
    }
}

@Suite("Apple speech asset status")
struct AppleSpeechAssetTests {
    @Test("installed-but-unreserved assets (system says supported) are reported installed")
    func installedButUnreserved() async {
        let backend = FakeSpeechBackend()
        let engine = AppleSpeechEngine(backend: backend)
        #expect(await engine.assetStatus(for: "en") == .installed)
        #expect(await engine.assetStatus(for: "fr") == .notInstalled)
    }

    @Test("unavailable framework and unsupported languages are distinguished")
    func unavailableAndUnsupported() async {
        let backend = FakeSpeechBackend()
        let engine = AppleSpeechEngine(backend: backend)
        #expect(await engine.assetStatus(for: "si") == .unsupported)
        backend.isAvailable = false
        #expect(await engine.assetStatus(for: "en") == .unavailable)
    }

    @Test("stream on an unavailable framework throws engineFailure and never hangs")
    func streamUnavailable() async {
        let backend = FakeSpeechBackend()
        backend.isAvailable = false
        let silence = AsyncStream<AudioChunk> { $0.finish() }
        do {
            for try await _ in AppleSpeechEngine(backend: backend).stream(
                audio: silence, options: TranscriptionOptions(languageMode: .single("en"), useCase: .live)) {}
            Issue.record("expected throw")
        } catch {
            guard case .engineFailure = error as? AppError else { Issue.record("unexpected \(error)"); return }
        }
    }

    @Test("stream with missing assets throws modelNotInstalled")
    func streamNotInstalled() async {
        let backend = FakeSpeechBackend()
        backend.installed = []
        let silence = AsyncStream<AudioChunk> { $0.finish() }
        do {
            for try await _ in AppleSpeechEngine(backend: backend).stream(
                audio: silence, options: TranscriptionOptions(languageMode: .single("en"), useCase: .live)) {}
            Issue.record("expected throw")
        } catch { #expect(error as? AppError == .modelNotInstalled(RoutingTargets.appleSpeech)) }
    }

    @Test("install failure surfaces the NSError domain/code and the System Settings hint")
    func installFailureReason() async {
        let backend = FakeSpeechBackend()
        backend.installError = NSError(domain: "SFSpeechErrorDomain", code: 14, userInfo: [NSLocalizedDescriptionKey: "No network"])
        let engine = AppleSpeechEngine(backend: backend)
        do {
            try await engine.installAssets(for: "fr")
            Issue.record("expected throw")
        } catch {
            guard case .modelDownloadFailed(let model, let reason) = error as? AppError else { Issue.record("unexpected \(error)"); return }
            #expect(model == RoutingTargets.appleSpeech)
            #expect(reason.contains("SFSpeechErrorDomain 14"))
            #expect(reason.contains("Keyboard > Dictation"))
        }
    }

    @Test("install on an unavailable Mac explains why instead of a generic failure")
    func installUnavailable() async {
        let backend = FakeSpeechBackend()
        backend.isAvailable = false
        do {
            try await AppleSpeechEngine(backend: backend).installAssets(for: "en")
            Issue.record("expected throw")
        } catch {
            guard case .modelDownloadFailed(_, let reason) = error as? AppError else { Issue.record("unexpected \(error)"); return }
            #expect(reason.contains("isn't available on this Mac"))
        }
        #expect(backend.installRequests.isEmpty)
    }

    @Test("successful install reports progress and reserves nothing extra when already reserved")
    func installSucceeds() async throws {
        let backend = FakeSpeechBackend()
        let engine = AppleSpeechEngine(backend: backend)
        try await engine.installAssets(for: "fr")
        #expect(backend.installRequests == ["fr_FR"])
    }

    @Test("locale resolver prefers the user's region, then installed, then US, never an arbitrary variant")
    func resolver() {
        let supported = ["en_US", "en_ZA", "en_GB", "en_AU"].map(Locale.init(identifier:))
        func pick(_ lang: LanguageCode, installed: [String], preferred: String) -> String? {
            AppleSpeechLocaleResolver.resolve(
                language: lang, supported: supported, installed: installed.map(Locale.init(identifier:)),
                preferred: Locale(identifier: preferred))?.identifier
        }
        #expect(pick("en", installed: ["en_ZA"], preferred: "en_GB") == "en_GB")
        #expect(pick("en", installed: ["en_ZA", "en_US"], preferred: "de_DE") == "en_US")
        #expect(pick("en", installed: ["en_ZA"], preferred: "de_DE") == "en_ZA")
        #expect(pick("en", installed: [], preferred: "de_DE") == "en_US")
        #expect(pick("en-AU", installed: ["en_US"], preferred: "en_US") == "en_AU")
        #expect(pick("fr", installed: [], preferred: "en_US") == nil)
    }

    @Test("translation packs cannot inherit speech installation state or install speech assets")
    func speechProviderRejectsTranslationModel() async throws {
        let backend = FakeSpeechBackend()
        let provider = AppleSpeechAssetProvider(engine: AppleSpeechEngine(backend: backend), language: { "en" })
        #expect(await provider.isInstalled("apple/translation") == false)
        await #expect(throws: AppError.self) { try await provider.install("apple/translation") { _ in } }
        #expect(backend.installRequests.isEmpty && backend.reserved.isEmpty)
    }

    @Test("provider reports the system-language model state and installs through the engine")
    func provider() async throws {
        let backend = FakeSpeechBackend()
        backend.installed = []
        let readiness = AppleSpeechReadiness()
        let provider = AppleSpeechAssetProvider(engine: AppleSpeechEngine(backend: backend), readiness: readiness, language: { "en" })
        #expect(await provider.isInstalled(RoutingTargets.appleSpeech) == false)
        #expect(readiness.status(for: "en") == .notInstalled)
        backend.installed = [Locale(identifier: "en_US")]
        try await provider.install(RoutingTargets.appleSpeech) { _ in }
        #expect(readiness.status(for: "en") == .installed)
        #expect(await provider.isInstalled(RoutingTargets.appleSpeech))
    }
}

@Suite("AppleAwareEngineRouter")
struct AppleAwareEngineRouterTests {
    private func request(_ language: LanguageCode, _ useCase: UseCase, model: ModelID? = nil) -> RoutingRequest {
        RoutingRequest(languageMode: .single(language), useCase: useCase, tier: .tier16, installedModels: [], explicitModel: model)
    }

    @Test("installed readiness keeps Apple for live and dictation")
    func appleKept() throws {
        let readiness = AppleSpeechReadiness()
        let router = AppleAwareEngineRouter(readiness: readiness)
        readiness.set(.installed, for: "en")
        #expect(try router.plan(for: request("en", .live)).assignments.first?.model == RoutingTargets.appleSpeech)
        #expect(try router.plan(for: request("en", .dictation)).assignments.first?.model == RoutingTargets.appleSpeech)
    }

    @Test("unchecked language does not assume installed assets")
    func uncheckedLanguageFallsBack() throws {
        let readiness = AppleSpeechReadiness()
        readiness.set(.installed, for: "en")
        let plan = try AppleAwareEngineRouter(readiness: readiness).plan(for: request("hi", .live))
        #expect(plan.assignments.first?.model == RoutingTargets.whisperSmall)
        #expect(plan.warnings.first == AppleSpeechMessages.notInstalledNotice)
    }

    @Test("execution checks the selected language and can recover after assets become installed")
    func preparesSelectedLanguage() async throws {
        let backend = FakeSpeechBackend()
        let readiness = AppleSpeechReadiness()
        let router = AppleAwareEngineRouter(readiness: readiness, engine: AppleSpeechEngine(backend: backend))
        let missing = try await router.preparedPlan(for: request("fr", .live))
        #expect(missing.assignments.first?.model == RoutingTargets.whisperSmall)
        backend.installed.append(Locale(identifier: "fr_FR"))
        let installed = try await router.preparedPlan(for: request("fr", .live))
        #expect(installed.assignments.first?.model == RoutingTargets.appleSpeech)
        #expect(readiness.status(for: "fr") == .installed)
    }

    @Test("readiness for one locale does not authorize a different region")
    func localeReadinessIsSeparate() {
        let readiness = AppleSpeechReadiness()
        readiness.set(.installed, for: "en-US")
        #expect(readiness.status(for: "en-GB") == nil)
    }

    @Test("unavailable Apple falls back to Whisper with a visible notice")
    func fallbackUnavailable() throws {
        let readiness = AppleSpeechReadiness()
        readiness.set(.unavailable, for: "en")
        let plan = try AppleAwareEngineRouter(readiness: readiness).plan(for: request("en", .live))
        #expect(plan.assignments.first?.engine == RoutingTargets.whisperKitEngine)
        #expect(plan.warnings.first == AppleSpeechMessages.unavailableNotice)
    }

    @Test("assets not installed also fall back, pointing at Settings > Models")
    func fallbackNotInstalled() throws {
        let readiness = AppleSpeechReadiness()
        readiness.set(.notInstalled, for: "en")
        let plan = try AppleAwareEngineRouter(readiness: readiness).plan(for: request("en", .dictation))
        #expect(plan.assignments.first?.model == RoutingTargets.whisperSmall)
        #expect(plan.warnings.first == AppleSpeechMessages.notInstalledNotice)
    }

    @Test("file routing and explicit model choices are untouched")
    func passthrough() throws {
        let readiness = AppleSpeechReadiness()
        readiness.set(.unavailable, for: "en")
        let router = AppleAwareEngineRouter(readiness: readiness)
        #expect(try router.plan(for: request("en", .file)).assignments.first?.model == RoutingTargets.whisperLarge)
        let explicit = try router.plan(for: request("en", .live, model: RoutingTargets.appleSpeech))
        #expect(explicit.assignments.first?.model == RoutingTargets.appleSpeech)
    }
}
