import AppCore
import FeatureSupport
import Foundation
import Testing

@testable import Dictation

@Suite("DictationSettingsBridge")
struct SettingsBridgeTests {
    private func comboKey() -> String { SettingsKey.shortcut(HotkeyAction.dictation.rawValue) }

    @Test func emptyStoreYieldsDefaultsAndTheControlOptionDShortcut() async {
        let store = InMemorySettingsStore()
        await DictationSettingsBridge.sync(store: store)
        let s = await DictationSettings.load(from: store)
        #expect(s.combo == .defaultDictation)
        #expect(s.combo.keyCode == 2 && s.combo.modifiers == ModifierMask.control | ModifierMask.option)
        #expect(s.autoPunctuation)  // Settings default is on
        #expect(s.vocabulary.isEmpty)
        #expect(s.modelID == nil && s.translationTarget == nil && s.deviceUID == nil)
    }

    @Test func mirrorsSettingsSceneKeys() async {
        let store = InMemorySettingsStore()
        await store.set(HotkeyMode.toggle, for: SettingsKey.dictationMode)
        await store.set(TextInsertionMethod.accessibility, for: SettingsKey.dictationInsertion)
        await store.set(false, for: SettingsKey.dictationAutoPunctuate)
        await store.set(["Earmark", "WhisperKit"], for: SettingsKey.customVocabulary)
        await store.set("whisper-large", for: SettingsKey.preferredModel)
        await store.set("fr", for: SettingsKey.translationTarget)
        await store.set(KeyCombo.functionKey, for: comboKey())
        await DictationSettingsBridge.sync(store: store)
        let s = await DictationSettings.load(from: store)
        #expect(s.mode == .toggle)
        #expect(s.insertionMethod == .accessibility)
        #expect(!s.autoPunctuation)
        #expect(s.vocabulary == ["Earmark", "WhisperKit"])
        #expect(s.modelID == ModelID("whisper-large"))
        #expect(s.translationTarget == LanguageCode("fr"))
        #expect(s.combo == .functionKey)
    }

    @Test func historySizeZeroDisablesHistoryAndOtherwiseSetsTheLimit() async {
        let store = InMemorySettingsStore()
        await store.set(0, for: SettingsKey.dictationHistorySize)
        await DictationSettingsBridge.sync(store: store)
        var s = await DictationSettings.load(from: store)
        #expect(!s.historyEnabled && s.historyLimit == 1)
        await store.set(50, for: SettingsKey.dictationHistorySize)
        await DictationSettingsBridge.sync(store: store)
        s = await DictationSettings.load(from: store)
        #expect(s.historyEnabled && s.historyLimit == 50)
    }

    @Test func perFeatureDeviceOverridesTheGlobalDevice() async {
        let store = InMemorySettingsStore()
        await store.set("global-mic", for: SettingsKey.inputDeviceUID)
        await DictationSettingsBridge.sync(store: store)
        #expect(await DictationSettings.load(from: store).deviceUID == "global-mic")
        await store.set("dictation-mic", for: SettingsKey.dictationInputDeviceUID)
        await DictationSettingsBridge.sync(store: store)
        #expect(await DictationSettings.load(from: store).deviceUID == "dictation-mic")
        await store.set("", for: SettingsKey.dictationInputDeviceUID)
        await DictationSettingsBridge.sync(store: store)
        #expect(await DictationSettings.load(from: store).deviceUID == "global-mic")
    }

    @Test func keepsFieldsTheSettingsSceneDoesNotEdit() async {
        let store = InMemorySettingsStore()
        var existing = DictationSettings()
        existing.hudPosition = .bottomCenter
        await existing.save(to: store)
        await DictationSettingsBridge.sync(store: store)
        #expect(await DictationSettings.load(from: store).hudPosition == .bottomCenter)
    }

    @Test func observedKeysCoverTheShortcutAndEveryMirroredSetting() {
        let keys = Set(DictationSettingsBridge.observedKeys)
        #expect(keys.contains(comboKey()))
        #expect(keys.contains(SettingsKey.dictationMode) && keys.contains(SettingsKey.customVocabulary))
    }
}
