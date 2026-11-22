import AppCore

/// File imports, drops and re-transcription use the same saved language/model/speaker defaults shown in the add sheet.
public enum FileJobSettings {
    /// What the add sheet remembers between uses (SCR-013).
    public struct Choices: Equatable, Sendable {
        public var languageMode: LanguageMode
        /// `nil` is Automatic.
        public var modelID: ModelID?
        public var diarize: Bool
        public var speakerCount: SpeakerCount
        public init(languageMode: LanguageMode, modelID: ModelID?, diarize: Bool, speakerCount: SpeakerCount) {
            self.languageMode = languageMode
            self.modelID = modelID
            self.diarize = diarize
            self.speakerCount = speakerCount
        }
    }

    public static let maxRecentLanguages = 5

    public static func load(
        from settings: any SettingsStore, catalog: [ModelDescriptor], languageOverride: LanguageMode? = nil
    ) async -> JobSettings {
        let stored = await settings.value(for: SettingsKey.languageMode, as: LanguageMode.self) ?? .default
        let requested = languageOverride ?? stored
        let mode: LanguageMode
        if case .multilingual(let languages) = requested, languages.isEmpty { mode = .autoDetect } else { mode = requested }
        // The sheet's own last pick wins ("" is an explicit Automatic); otherwise the file model chosen in Settings.
        let lastPick = await settings.value(for: SettingsKey.filesLastModel, as: String.self)
        let filePick = await PreferredModel.explicitID(for: .file, settings: settings)?.rawValue
        let preferred = lastPick ?? filePick
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
        let diarize = await settings.value(for: SettingsKey.filesDiarize, as: Bool.self) ?? false
        let count = SpeakerCount(storedValue: await settings.value(for: SettingsKey.filesSpeakerCount, as: Int.self))
        return JobSettings(
            languageMode: mode, modelID: modelID, diarize: diarize, diarization: diarize ? count.diarization : [:])
    }

    /// Whether adding files shows the Transcribe sheet first. Absent means yes (default on).
    public static func asksBeforeAdding(in settings: any SettingsStore) async -> Bool {
        await settings.value(for: SettingsKey.askBeforeAdding, as: Bool.self) ?? true
    }

    /// Remembers what the user chose in the sheet. The speaker choices always persist. Language and model persist only when the
    /// user changed them (`persistLanguageAndModel`), so merely opening and confirming the sheet never rewrites the defaults.
    /// The model is saved as the file-scoped default only; the live-caption and dictation models are separate keys.
    public static func save(_ choices: Choices, persistLanguageAndModel: Bool, to settings: any SettingsStore) async {
        await settings.set(choices.diarize, for: SettingsKey.filesDiarize)
        await settings.set(choices.speakerCount.storedValue, for: SettingsKey.filesSpeakerCount)
        guard persistLanguageAndModel else { return }
        await settings.set(choices.languageMode, for: SettingsKey.languageMode)
        // Also the file default shown by the sidebar chip, Settings and the model picker, so nothing disagrees about which
        // model files will use (``PreferredModel/set(_:for:settings:)`` mirrors it into `files.lastModel`).
        await PreferredModel.set(choices.modelID, for: .file, settings: settings)
        let used: [LanguageCode]
        switch choices.languageMode {
        case .single(let code): used = [code]
        case .multilingual(let codes): used = codes.sorted()
        case .autoDetect: used = []
        }
        if !used.isEmpty {
            let previous = await settings.value(for: SettingsKey.filesRecentLanguages, as: [String].self) ?? []
            await settings.set(
                recent(adding: used, to: previous.map { LanguageCode($0) }).map(\.rawValue), for: SettingsKey.filesRecentLanguages)
        }
    }

    /// Most-recently-used first, no duplicates, at most ``maxRecentLanguages``.
    public static func recent(adding used: [LanguageCode], to previous: [LanguageCode]) -> [LanguageCode] {
        var result: [LanguageCode] = []
        for code in used + previous where !result.contains(code) { result.append(code) }
        return Array(result.prefix(maxRecentLanguages))
    }

    public static func recentLanguages(in settings: any SettingsStore) async -> [LanguageCode] {
        (await settings.value(for: SettingsKey.filesRecentLanguages, as: [String].self) ?? []).map { LanguageCode($0) }
    }
}
