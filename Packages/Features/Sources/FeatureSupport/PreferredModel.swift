import AppCore

/// Resolves the user's explicit ASR model for status displays, falling back to a compatible catalog model.
/// This does not load or download models; engine routing still owns execution-time selection.
public enum PreferredModel {
    public static func resolve(
        in catalog: [ModelDescriptor], settings: any SettingsStore, tier: HardwareTier = .tier16
    ) async -> ModelDescriptor? {
        await fileModels(in: catalog, settings: settings, tier: tier).first
    }

    /// Status-only counterpart to file routing: explicit compatible choice, otherwise the hardware/language defaults.
    /// A multilingual selection can need more than one model, so the sidebar must not label only one of them "Ready".
    public static func fileModels(
        in catalog: [ModelDescriptor], settings: any SettingsStore, tier: HardwareTier = .tier16
    ) async -> [ModelDescriptor] {
        let preferred = await settings.value(for: SettingsKey.preferredModel, as: String.self)
        let mode = await settings.value(for: SettingsKey.languageMode, as: LanguageMode.self) ?? .default
        let languages: Set<LanguageCode>
        switch mode {
        case .single(let language): languages = [language]
        case .multilingual(let selected): languages = selected
        case .autoDetect: languages = []
        }
        let covers: (ModelDescriptor, LanguageCode) -> Bool = { model, language in
            model.languages.contains(language) || model.languages.contains(language.primary)
        }
        let explicit = catalog.first { preferred == $0.id.rawValue && $0.kind == .asr }
        if let model = explicit {
            let permitsDetection = mode != .autoDetect || Set(model.languages.map(\.primary)).count > 1
            if permitsDetection && languages.allSatisfy({ covers(model, $0) }) { return [model] }
        }
        let defaultWhisper: ModelID = tier == .tier8 ? "whisperkit/small" : "whisperkit/large-v3-v20240930_626MB"
        let requested: [LanguageCode?] = languages.isEmpty ? [nil] : languages.sorted().map(Optional.some)
        var resolved: [ModelDescriptor] = []
        for language in requested {
            let defaultID: ModelID = language?.primary == .sinhala ? "mlx/qwen3-asr-0.6b-sinhala-8bit" : defaultWhisper
            let compatible = catalog.filter { model in
                model.kind == .asr && (language.map { covers(model, $0) } ?? true)
            }
            let model =
                compatible.first(where: { $0.id == defaultID })
                ?? compatible.first(where: { !$0.isExperimental && $0.minTier <= tier })
                ?? compatible.first(where: { $0.minTier <= tier }) ?? compatible.first
            if let model, !resolved.contains(where: { $0.id == model.id }) { resolved.append(model) }
        }
        return resolved
    }
}
