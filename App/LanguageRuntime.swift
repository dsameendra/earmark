import AppCore
import FeatureSupport
import Foundation
import LiveCaptions
import ModelStore
import Transcription

/// Re-transcribes one segment's time range with the engine of the language the user chose (EDIT-AC-09, LANG-AC-08): the
/// router picks per language, so Sinhala reaches the Qwen3-ASR engine and never stock Whisper.
struct SegmentRetranscriptionAdapter: SegmentRetranscriptionService {
    let router: any EngineRouter
    let hardware: any HardwareTierProviding
    let models: any ModelManaging
    let engines: [EngineID: any TranscriptionEngine]
    let explicitModel: @Sendable () async -> ModelID?

    func retranscribe(segment: Segment, mediaURL: URL, language: LanguageCode) async throws -> Segment {
        let tier = hardware.profile.tier
        let installed = await models.installedModels()
        let explicit = await explicitModel()
        let base = try router.plan(
            for: RoutingRequest(languageMode: .single(language), useCase: .file, tier: tier, installedModels: installed))
        let resolver = LanguageEngineResolver.make(
            router: router, basePlan: base, useCase: .file, tier: tier, explicitModel: explicit,
            installed: { [models] in await models.installedModels() }, engines: engines)
        // The engine that will really run (the user's model when it covers the language) must have its model installed; the
        // editor shows a download hint otherwise.
        if let model = try await resolver(language).model,
            await models.catalog().first(where: { $0.id == model })?.runtime != .appleAsset
        {
            guard case .installed = await models.state(of: model) else { throw AppError.modelNotInstalled(model) }
        }
        let retranscriber = SegmentRetranscriber(engines: resolver)
        return try await retranscriber.retranscribe(
            segment: segment, file: mediaURL, language: language, options: TranscriptionOptions(useCase: .file))
    }
}

/// Live engine selection with code-switching: a multilingual set of several languages runs through `MultilingualEngine`
/// (language ID per utterance, one engine per language, LANG-AC-05); everything else goes through the plain router provider.
struct LiveLanguageEngineProvider: LiveEngineProviding {
    let base: RouterEngineProvider
    let router: any EngineRouter
    let hardware: any HardwareTierProviding
    let models: any ModelManaging
    let engines: [EngineID: any TranscriptionEngine]
    let identifier: any LanguageIdentifier
    let explicitModel: @Sendable () async -> ModelID?

    func resolve(languageMode: LanguageMode) async throws -> LiveEngineSelection {
        guard case .multilingual(let set) = languageMode, set.count > 1 else { return try await base.resolve(languageMode: languageMode) }
        let installed = await models.installedModels()
        let tier = hardware.profile.tier
        let plan = try router.plan(
            for: RoutingRequest(languageMode: languageMode, useCase: .live, tier: tier, installedModels: installed))
        // Every language needs its model now: a missing one would only fail mid-session, on the first utterance in it.
        for assignment in plan.assignments where assignment.requiresDownload {
            if let model = assignment.model { throw AppError.modelNotInstalled(model) }
        }
        // Language ID runs on Whisper small.
        guard installed.contains(RoutingTargets.whisperSmall) else { throw AppError.modelNotInstalled(RoutingTargets.whisperSmall) }
        let resolver = LanguageEngineResolver.make(
            router: router, basePlan: plan, useCase: .live, tier: tier, explicitModel: nil,
            installed: { [models] in await models.installedModels() }, engines: engines)
        let engine = MultilingualEngine(languages: set, resolver: resolver, identifier: identifier)
        return LiveEngineSelection(engine: engine, model: nil, warnings: plan.warnings)
    }
}
