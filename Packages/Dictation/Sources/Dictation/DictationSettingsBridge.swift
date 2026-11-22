import AppCore
import FeatureSupport
import Foundation

/// Mirrors the Settings scene's separate dictation keys, the Shortcuts pane's combo and the global defaults into the single
/// `DictationSettings` value the controller reads, and reloads the controller when any of them changes. Without this the
/// Settings UI and the controller would hold two disconnected copies (a changed hotkey or mode would never apply).
public enum DictationSettingsBridge {
    public static let observedKeys = [
        SettingsKey.dictationMode, SettingsKey.dictationInsertion, SettingsKey.dictationAutoPunctuate, SettingsKey.dictationHistorySize,
        SettingsKey.dictationInputDeviceUID, SettingsKey.inputDeviceUID, SettingsKey.shortcut(HotkeyAction.dictation.rawValue),
        SettingsKey.languageMode, SettingsKey.preferredModelDictation, SettingsKey.customVocabulary, SettingsKey.translationTarget,
    ]

    /// Rebuilds the controller's settings from the Settings-scene keys (keeps fields the UI does not edit, such as the HUD position).
    public static func sync(store: any SettingsStore) async {
        var settings = await DictationSettings.load(from: store)
        if let mode = await store.value(for: SettingsKey.dictationMode, as: HotkeyMode.self) { settings.mode = mode }
        if let method = await store.value(for: SettingsKey.dictationInsertion, as: TextInsertionMethod.self) {
            settings.insertionMethod = method
        }
        settings.autoPunctuation = await store.value(for: SettingsKey.dictationAutoPunctuate, as: Bool.self) ?? true
        if let size = await store.value(for: SettingsKey.dictationHistorySize, as: Int.self) {
            settings.historyEnabled = size > 0
            settings.historyLimit = max(size, 1)
        }
        let override = await store.value(for: SettingsKey.dictationInputDeviceUID, as: String.self)
        let global = await store.value(for: SettingsKey.inputDeviceUID, as: String.self)
        let uid = (override?.isEmpty ?? true) ? global : override
        settings.deviceUID = (uid?.isEmpty ?? true) ? nil : uid
        let comboKey = SettingsKey.shortcut(HotkeyAction.dictation.rawValue)
        if let combo = await store.value(for: comboKey, as: KeyCombo.self) {
            settings.combo = combo
        } else if await store.value(for: comboKey + ".cleared", as: Bool.self) != true {
            settings.combo = .defaultDictation  // the Shortcuts pane default, Control-Option-D
        }
        if let mode = await store.value(for: SettingsKey.languageMode, as: LanguageMode.self) { settings.languageMode = mode }
        settings.modelID = await PreferredModel.explicitID(for: .dictation, settings: store)
        settings.vocabulary = await store.value(for: SettingsKey.customVocabulary, as: [String].self) ?? []
        let target = await store.value(for: SettingsKey.translationTarget, as: String.self)
        settings.translationTarget = (target?.isEmpty ?? true) ? nil : target.map { LanguageCode($0) }
        await settings.save(to: store)
    }

    /// Syncs once, starts the controller, then follows the observed keys.
    public static func run(store: any SettingsStore, controller: DictationController) async {
        await sync(store: store)
        await controller.start()
        await withTaskGroup(of: Void.self) { group in
            for key in observedKeys {
                group.addTask {
                    for await _ in store.changes(for: key) {
                        await sync(store: store)
                        await controller.reloadSettings()
                    }
                }
            }
        }
    }
}
