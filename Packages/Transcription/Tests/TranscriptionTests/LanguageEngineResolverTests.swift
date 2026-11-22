import AppCore
import AppCoreTesting
import Foundation
import Testing

@testable import Transcription

@Suite("LanguageEngineResolver")
struct LanguageEngineResolverTests {
    private let whisper = MockTranscriptionEngine(id: RoutingTargets.whisperKitEngine, languages: ["en", "de"])
    private let qwen = MockTranscriptionEngine(id: RoutingTargets.qwenEngine, languages: ["si"])
    private let apple = MockTranscriptionEngine(id: RoutingTargets.appleEngine, languages: ["en"])

    private func resolver(mode: LanguageMode, useCase: UseCase = .file, explicit: ModelID? = nil) throws -> EngineResolver {
        let router = DefaultEngineRouter()
        let plan = try router.plan(
            for: RoutingRequest(languageMode: mode, useCase: useCase, tier: .tier16, installedModels: [], explicitModel: explicit))
        return LanguageEngineResolver.make(
            router: router, basePlan: plan, useCase: useCase, tier: .tier16, explicitModel: explicit, installed: { [] },
            engines: [whisper.id: whisper, qwen.id: qwen, apple.id: apple])
    }

    @Test("LANG-AC-09: auto-detect resolves Sinhala to the Qwen engine and English to Whisper")
    func autoDetectReachesSinhala() async throws {
        let resolve = try resolver(mode: .autoDetect)
        #expect(try await resolve(nil).engine.id == RoutingTargets.whisperKitEngine)
        #expect(try await resolve("si").engine.id == RoutingTargets.qwenEngine)
        #expect(try await resolve("si").model == RoutingTargets.qwenSinhala)
        #expect(try await resolve("de").engine.id == RoutingTargets.whisperKitEngine)
    }

    @Test("live multilingual: English stays on Apple, Sinhala goes to Qwen")
    func liveSplit() async throws {
        let resolve = try resolver(mode: .multilingual(["en", "si"]), useCase: .live)
        #expect(try await resolve("en").engine.id == RoutingTargets.appleEngine)
        #expect(try await resolve("si").engine.id == RoutingTargets.qwenEngine)
    }

    @Test("an explicit model that does not cover a detected language yields to the router for that language")
    func explicitModelYields() async throws {
        let resolve = try resolver(mode: .single("en"), explicit: RoutingTargets.whisperSmall)
        #expect(try await resolve("en").model == RoutingTargets.whisperSmall)
        #expect(try await resolve("si").engine.id == RoutingTargets.qwenEngine)
    }

    @Test("an engine missing from the build is an engine failure, not a crash")
    func missingEngine() async throws {
        let router = DefaultEngineRouter()
        let plan = try router.plan(
            for: RoutingRequest(languageMode: .single("en"), useCase: .file, tier: .tier16, installedModels: []))
        let resolve = LanguageEngineResolver.make(
            router: router, basePlan: plan, useCase: .file, tier: .tier16, explicitModel: nil, installed: { [] },
            engines: [whisper.id: whisper])
        await #expect(throws: AppError.self) { _ = try await resolve("si") }
    }
}
