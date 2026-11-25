import AppCore
import Foundation

/// Shared translation defaults for Live and menu-bar capture. Appearance is consulted only for one-time migration.
public struct LiveTranslationPreferences: Sendable {
    public let isEnabled: Bool
    public let target: LanguageCode?
    public let engine: String

    public static func load(settings: any SettingsStore, legacyPreset: CaptionPreset?) async -> Self {
        let saved = await settings.value(for: SettingsKey.liveTranslationEnabled, as: Bool.self)
        let enabled = saved ?? ((legacyPreset?.showTranslation ?? false) || (legacyPreset?.translatedOnly ?? false))
        if saved == nil { await settings.set(enabled, for: SettingsKey.liveTranslationEnabled) }
        let raw = await settings.value(for: SettingsKey.translationTarget, as: String.self) ?? ""
        let target = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(
            isEnabled: enabled, target: target.isEmpty ? nil : LanguageCode(target),
            engine: await settings.value(for: SettingsKey.translationEngine, as: String.self) ?? "auto")
    }
    public func readiness(languageMode: LanguageMode, using service: (any TranslationPreparing)?) async -> TranslationReadiness {
        guard isEnabled else { return .ready }
        guard let target else { return .unavailable(reason: "Choose a target language in the Translation panel before starting.") }
        guard let service else { return .unavailable(reason: "Translation is unavailable in this build.") }
        let sources: Set<LanguageCode>
        switch languageMode {
        case .single(let language): sources = [language]
        case .multilingual(let languages): sources = languages
        case .autoDetect: return .ready // Readiness is checked for the detected source by the runtime router.
        }
        let distinct = sources.filter { $0.primary != target.primary }
        guard !distinct.isEmpty else { return .unavailable(reason: "Choose a translation target different from the spoken language.") }
        for source in distinct.sorted() {
            let result = await service.readiness(source: source, target: target)
            if result != .ready { return result }
        }
        return .ready
    }

    public static func setupMessage(_ readiness: TranslationReadiness, models: any ModelManaging) async -> String? {
        switch readiness {
        case .ready: return nil
        case .needsModel(let id):
            let name = await models.catalog().first(where: { $0.id == id })?.displayName ?? id.rawValue
            return "Install \(name) in Settings > Models before translating captions."
        case .needsApplePack:
            return "The translation language pack is not installed. Choose Prepare translation in Live."
        case .unavailable(let reason): return reason
        }
    }

}
