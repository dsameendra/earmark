import AppCore

/// Resolves the user's explicit ASR model for status displays, falling back to a compatible catalog model.
/// This does not load or download models; engine routing still owns execution-time selection.
public enum PreferredModel {
    public static func resolve(in catalog: [ModelDescriptor], settings: any SettingsStore) async -> ModelDescriptor? {
        let preferred = await settings.value(for: SettingsKey.preferredModel, as: String.self)
        if let preferred, let model = catalog.first(where: { $0.id.rawValue == preferred && $0.kind == .asr }) { return model }
        let mode = await settings.value(for: SettingsKey.languageMode, as: LanguageMode.self) ?? .default
        let languages: Set<LanguageCode>
        switch mode {
        case .single(let language): languages = [language]
        case .multilingual(let selected): languages = selected
        case .autoDetect: languages = []
        }
        let candidates = catalog.filter { $0.kind == .asr && languages.isSubset(of: $0.languages) }
        return candidates.first(where: { !$0.isExperimental }) ?? candidates.first
    }
}
