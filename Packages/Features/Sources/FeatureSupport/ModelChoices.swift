import AppCore

/// One speech-recognition model in a picker, with whether it can be chosen for the current language(s) and why not (SCR-011).
public struct ModelChoiceRow: Identifiable, Sendable, Equatable {
    public var descriptor: ModelDescriptor
    public var availability: ModelAvailability
    public var isInstalled: Bool
    public var isRecommended: Bool

    public var id: ModelID { descriptor.id }
    public var isEnabled: Bool { availability.isOK }
    /// One line explaining why the row is greyed out; `nil` when it can be chosen.
    public var disabledReason: String? {
        let reasons = availability.reasons
        return reasons.isEmpty ? nil : reasons.map(\.message).joined(separator: "; ")
    }
}

/// Shared model-picker logic for the add sheet and the editor's Re-transcribe popover: every row of the catalog that this build
/// can run, greyed out with a reason through ``ModelCompatibility``, and the recommended model through ``ModelRecommender``.
public enum ModelChoices {
    public static func requirement(for mode: LanguageMode) -> ModelRequirement {
        switch mode {
        case .single(let code): ModelRequirement(useCase: .file, languages: [code])
        case .multilingual(let codes): ModelRequirement(useCase: .file, languages: codes)
        case .autoDetect: ModelRequirement(useCase: .file, needsAutoDetect: true)
        }
    }

    /// The recommended model for `mode` (auto-detect and multilingual ask for a model that identifies the language itself).
    public static func recommended(
        for mode: LanguageMode, tier: HardwareTier, catalog: [ModelDescriptor], availableEngines: Set<EngineID>? = nil,
        allowFallback: Bool = true
    ) -> ModelDescriptor? {
        let language: LanguageCode?
        switch mode {
        case .single(let code): language = code
        case .autoDetect, .multilingual: language = nil
        }
        return ModelRecommender.recommendedModel(
            for: tier, useCase: .file, language: language, in: catalog, availableEngines: availableEngines,
            allowFallback: allowFallback)
    }

    /// Runnable ASR models, enabled rows first (then by name). Models that cannot run in this build are not listed at all.
    public static func rows(
        catalog: [ModelDescriptor], installed: Set<ModelID>, mode: LanguageMode, tier: HardwareTier,
        availableEngines: Set<EngineID>? = nil
    ) -> [ModelChoiceRow] {
        let requirement = requirement(for: mode)
        let recommended = recommended(for: mode, tier: tier, catalog: catalog, availableEngines: availableEngines)?.id
        return catalog.filter { $0.kind == .asr && $0.isRunnable }.map { descriptor in
            ModelChoiceRow(
                descriptor: descriptor,
                availability: ModelCompatibility.evaluate(descriptor, for: requirement, tier: tier, availableEngines: availableEngines),
                isInstalled: installed.contains(descriptor.id), isRecommended: descriptor.id == recommended)
        }.sorted { ($0.isEnabled ? 0 : 1, $0.descriptor.displayName) < ($1.isEnabled ? 0 : 1, $1.descriptor.displayName) }
    }
}
