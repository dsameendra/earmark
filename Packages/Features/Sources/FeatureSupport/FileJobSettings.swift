import AppCore

/// File imports, drops and re-transcription use the same saved language/model defaults shown in the workspace.
public enum FileJobSettings {
    public static func load(
        from settings: any SettingsStore, catalog: [ModelDescriptor], languageOverride: LanguageMode? = nil
    ) async -> JobSettings {
        let stored = await settings.value(for: SettingsKey.languageMode, as: LanguageMode.self) ?? .default
        let requested = languageOverride ?? stored
        let mode: LanguageMode
        if case .multilingual(let languages) = requested, languages.isEmpty { mode = .autoDetect } else { mode = requested }
        let preferred = await settings.value(for: SettingsKey.preferredModel, as: String.self)
        var modelID: ModelID?
        if let preferred, let descriptor = catalog.first(where: { $0.kind == .asr && $0.id.rawValue == preferred }) {
            let supported = Set(descriptor.languages.map(\.primary))
            let compatible: Bool
            switch mode {
            case .single(let language): compatible = supported.contains(language.primary)
            case .multilingual(let languages): compatible = !languages.isEmpty && Set(languages.map(\.primary)).isSubset(of: supported)
            case .autoDetect: compatible = supported.count > 1
            }
            if compatible { modelID = descriptor.id }
        }
        return JobSettings(languageMode: mode, modelID: modelID)
    }
}
