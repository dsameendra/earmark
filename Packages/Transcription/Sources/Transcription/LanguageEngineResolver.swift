import AppCore
import Foundation

/// Builds an ``EngineResolver`` that asks the ``EngineRouter`` per language (LANG-AC-04, LANG-AC-05, LANG-AC-09).
///
/// ``EngineBinding/resolver(plan:engines:)`` can only pick among the assignments of one plan. Auto-detect plans name a single
/// Whisper model, so a file detected as Sinhala would stay on Whisper; and a live or file plan for a set of languages can
/// collapse into one language-agnostic assignment. Resolving each concrete language through the router keeps the ADR-004
/// rules in one place: Sinhala always goes to the Qwen3-ASR engine, other languages to Apple/WhisperKit.
public enum LanguageEngineResolver {
    /// - Parameters:
    ///   - basePlan: Resolution for `language == nil` (not yet known): the plan of the job's own language mode.
    ///   - useCase: Routing use case of the request.
    ///   - explicitModel: The user's model choice; used for a language only when that model covers it.
    ///   - installed: Currently installed models (read per call, a download may finish mid-job).
    public static func make(
        router: any EngineRouter, basePlan: EnginePlan, useCase: UseCase, tier: HardwareTier, explicitModel: ModelID?,
        installed: @escaping @Sendable () async -> Set<ModelID>, engines: [EngineID: any TranscriptionEngine]
    ) -> EngineResolver {
        let fallback = EngineBinding.resolver(plan: basePlan, engines: engines)
        return { language in
            guard let language else { return try await fallback(nil) }
            let installedModels = await installed()
            func plan(explicit: ModelID?) throws -> EnginePlan {
                try router.plan(
                    for: RoutingRequest(
                        languageMode: .single(language), useCase: useCase, tier: tier, installedModels: installedModels,
                        explicitModel: explicit))
            }
            let routed: EnginePlan
            do {
                routed = try plan(explicit: explicitModel)
            } catch AppError.unsupportedLanguage where explicitModel != nil {
                routed = try plan(explicit: nil)
            }
            return try await EngineBinding.resolver(plan: routed, engines: engines)(language)
        }
    }
}
