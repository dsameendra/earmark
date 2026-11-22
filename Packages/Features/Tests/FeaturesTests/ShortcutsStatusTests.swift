import AppCore
import FeatureSettings
import FeatureSupport
import Foundation
import Synchronization
import Testing

private final class FakeDiagnostics: HotkeyDiagnosing, @unchecked Sendable {
    private let state: Mutex<HotkeyDiagnostics>
    let refreshes = Mutex(0)
    init(_ d: HotkeyDiagnostics) { state = Mutex(d) }
    func set(_ d: HotkeyDiagnostics) { state.withLock { $0 = d } }
    func refreshDiagnostics() async -> HotkeyDiagnostics {
        refreshes.withLock { $0 += 1 }
        return state.withLock { $0 }
    }
}

private func healthy() -> HotkeyDiagnostics {
    HotkeyDiagnostics(capture: .swallowing, accessibilityTrusted: true, inputMonitoringGranted: true, globeKeyAction: .doNothing)
}

@MainActor
@Suite("Shortcuts hotkey status")
struct ShortcutsStatusTests {
    @Test func dictationDefaultIsControlOptionDAndFnDisplaysAsFn() async {
        let model = ShortcutsModel(store: InMemorySettingsStore(), hotkeys: nil)
        await model.load()
        #expect(model.combo(for: .dictation) == .defaultDictation)
        #expect(ShortcutsModel.display(.defaultDictation) == "⌃⌥D")
        #expect(ShortcutsModel.display(.functionKey) == "Fn")
    }

    @Test func healthyStatusShowsNoIssues() async {
        let model = ShortcutsModel(store: InMemorySettingsStore(), hotkeys: nil, diagnostics: FakeDiagnostics(healthy()))
        await model.load()
        await model.refreshHotkeyStatus()
        #expect(model.issues.isEmpty)
    }

    @Test func listenOnlyCaptureExplainsTheAccessibilityFix() async {
        var d = healthy()
        d.capture = .listenOnly
        d.accessibilityTrusted = false
        let model = ShortcutsModel(store: InMemorySettingsStore(), hotkeys: nil, diagnostics: FakeDiagnostics(d))
        await model.load()
        await model.refreshHotkeyStatus()
        #expect(model.issues.count == 1)
        #expect(model.issues[0].fix == .openAccessibilitySettings)
        #expect(model.issues[0].fixURL?.absoluteString.contains("Privacy_Accessibility") == true)
    }

    @Test func registrationFailureIsSurfacedWithItsReason() async {
        var d = healthy()
        d.capture = .unavailable
        d.accessibilityTrusted = false
        d.inputMonitoringGranted = false
        d.failures = [.dictation: "Allow Earmark under Accessibility."]
        let model = ShortcutsModel(store: InMemorySettingsStore(), hotkeys: nil, diagnostics: FakeDiagnostics(d))
        await model.load()
        await model.refreshHotkeyStatus()
        #expect(model.issues.first?.message.contains("Allow Earmark under Accessibility.") == true)
        #expect(model.issues.first?.fix == .openAccessibilitySettings)
    }

    @Test func failureRetriesRegistrationOnceAccessIsGranted() async {
        var d = healthy()
        d.capture = .unavailable
        d.failures = [.dictation: "no tap"]
        let diag = FakeDiagnostics(d)
        let retried = Mutex(0)
        let model = ShortcutsModel(
            store: InMemorySettingsStore(), hotkeys: nil, diagnostics: diag,
            retryRegistration: {
                retried.withLock { $0 += 1 }
                diag.set(healthy())
            })
        await model.load()
        await model.refreshHotkeyStatus()
        #expect(retried.withLock { $0 } == 1)
        #expect(model.issues.isEmpty)
    }

    @Test func fnWithGlobeKeyBoundToEmojiShowsKeyboardSettingsFix() async {
        var d = healthy()
        d.globeKeyAction = .showEmojiAndSymbols
        let model = ShortcutsModel(store: InMemorySettingsStore(), hotkeys: nil, diagnostics: FakeDiagnostics(d))
        await model.load()
        await model.refreshHotkeyStatus()
        #expect(model.issues.isEmpty)  // default combo is not Fn
        await model.useFunctionKey(for: .dictation)
        #expect(model.combo(for: .dictation) == .functionKey)
        #expect(model.issues.count == 1)
        #expect(model.issues[0].fix == .openKeyboardSettings)
        #expect(model.issues[0].message.contains("Show Emoji & Symbols"))
    }

    @Test func fnWithGlobeKeyDoNothingIsClean() async {
        let model = ShortcutsModel(store: InMemorySettingsStore(), hotkeys: nil, diagnostics: FakeDiagnostics(healthy()))
        await model.load()
        await model.useFunctionKey(for: .dictation)
        #expect(model.issues.isEmpty)
    }

    @Test func useFunctionKeyPersistsAndStealsFromAConflictingAction() async {
        let store = InMemorySettingsStore()
        let model = ShortcutsModel(store: store, hotkeys: nil)
        await model.load()
        await model.useFunctionKey(for: .dictation)
        #expect(await store.value(for: SettingsKey.shortcut("dictation"), as: KeyCombo.self) == .functionKey)
    }
}
