import AppCore
import Foundation
import Synchronization
import Testing

@testable import Dictation

@Suite("Hotkey swallowing and diagnostics")
struct HotkeySwallowTests {
    private let mods = ModifierMask.control | ModifierMask.option
    private func key(_ kind: RawKeyEvent.Kind, _ code: UInt16 = 2, mods: Int? = nil, repeat r: Bool = false) -> RawKeyEvent {
        RawKeyEvent(kind: kind, keyCode: code, modifiers: mods ?? self.mods, isAutorepeat: r)
    }

    @Test func comboKeyDownRepeatAndKeyUpAreAllConsumed() {
        var m = HotkeyMatcher(combo: KeyCombo(keyCode: 2, modifiers: mods))
        let down = m.process(key(.keyDown))
        #expect(down.event == .pressed && down.consume)
        let rep = m.process(key(.keyDown, repeat: true))
        #expect(rep.event == nil && rep.consume)
        let up = m.process(key(.keyUp, mods: 0))
        #expect(up.event == .released && up.consume)
    }

    @Test func keyUpAfterModifierReleasedFirstIsStillConsumed() {
        var m = HotkeyMatcher(combo: KeyCombo(keyCode: 2, modifiers: mods))
        _ = m.process(key(.keyDown))
        #expect(m.process(RawKeyEvent(kind: .flagsChanged, keyCode: 59, modifiers: 0)).event == .released)
        #expect(m.process(key(.keyUp, mods: 0)).consume)
        #expect(!m.process(key(.keyUp, mods: 0)).consume)
    }

    @Test func otherKeysAndOtherModifiersPassThrough() {
        var m = HotkeyMatcher(combo: KeyCombo(keyCode: 2, modifiers: mods))
        #expect(!m.process(key(.keyDown, 3)).consume)
        #expect(!m.process(key(.keyDown, 2, mods: ModifierMask.command)).consume)
        #expect(!m.process(key(.keyUp, 3, mods: 0)).consume)
        #expect(!m.process(RawKeyEvent(kind: .flagsChanged, keyCode: 59, modifiers: ModifierMask.control)).consume)
    }

    @Test func fnFlagsChangedIsConsumedButOtherModifierOnlyKeysAreNot() {
        var fn = HotkeyMatcher(combo: .fn)
        let down = fn.process(RawKeyEvent(kind: .flagsChanged, keyCode: 63, modifiers: ModifierMask.function))
        #expect(down.event == .pressed && down.consume)
        let up = fn.process(RawKeyEvent(kind: .flagsChanged, keyCode: 63, modifiers: 0))
        #expect(up.event == .released && up.consume)
        #expect(!fn.process(RawKeyEvent(kind: .flagsChanged, keyCode: 55, modifiers: ModifierMask.command)).consume)

        var rightOption = HotkeyMatcher(combo: KeyCombo(keyCode: 61, modifiers: ModifierMask.option))
        let r = rightOption.process(RawKeyEvent(kind: .flagsChanged, keyCode: 61, modifiers: ModifierMask.option))
        #expect(r.event == .pressed && !r.consume)
    }

    @Test func resetReleasesAHeldKey() {
        var m = HotkeyMatcher(combo: .fn)
        _ = m.process(RawKeyEvent(kind: .flagsChanged, keyCode: 63, modifiers: ModifierMask.function))
        #expect(m.process(RawKeyEvent(kind: .reset, keyCode: 0, modifiers: 0)).event == .released)
        #expect(m.process(RawKeyEvent(kind: .reset, keyCode: 0, modifiers: 0)).event == nil)
    }

    @Test func serviceReportsConsumptionToTheSource() async throws {
        let source = FakeEventSource()
        let service = GlobalHotkeyService(source: source)
        _ = try await service.register(.dictation, combo: KeyCombo(keyCode: 2, modifiers: mods))
        #expect(source.emit(key(.keyDown)))
        #expect(!source.emit(key(.keyDown, 9)))
        #expect(source.emit(key(.keyUp, mods: 0)))
    }

    // MARK: Diagnostics

    private func state(ax: Bool = true, im: Bool = true, fn: Int? = 0) -> HotkeySystemState {
        HotkeySystemState(accessibilityTrusted: { ax }, inputMonitoringGranted: { im }, fnUsageType: { fn })
    }

    @Test func globeKeySettingDecoding() {
        #expect(GlobeKeyAction(appleFnUsageType: 0) == .doNothing)
        #expect(GlobeKeyAction(appleFnUsageType: 1) == .changeInputSource)
        #expect(GlobeKeyAction(appleFnUsageType: 2) == .showEmojiAndSymbols)
        #expect(GlobeKeyAction(appleFnUsageType: 3) == .startDictation)
        #expect(GlobeKeyAction(appleFnUsageType: nil) == .systemDefault)
        #expect(!GlobeKeyAction.doNothing.competesWithEarmark)
        #expect(GlobeKeyAction.systemDefault.competesWithEarmark)
    }

    @Test func failedRegistrationIsRememberedWithAnActionableMessage() async throws {
        let service = GlobalHotkeyService(source: FakeEventSource(failStart: true), system: state(ax: false, im: false, fn: 2))
        await #expect(throws: HotkeyError.eventSourceUnavailable) { _ = try await service.register(.dictation, combo: .fn) }
        let d = await service.refreshDiagnostics()
        #expect(d.capture == .unavailable)
        #expect(d.failures[.dictation]?.contains("Accessibility") == true)
        #expect(!d.accessibilityTrusted)
        #expect(d.globeKeyAction == .showEmojiAndSymbols)
    }

    @Test func successfulRegistrationClearsFailureAndReportsCapture() async throws {
        let source = FakeEventSource(failStart: true)
        let service = GlobalHotkeyService(source: source)
        _ = try? await service.register(.dictation, combo: .fn)
        source.setFailStart(false)
        _ = try await service.register(.dictation, combo: .fn)
        let d = await service.refreshDiagnostics()
        #expect(d.failures.isEmpty)
        #expect(d.capture == .swallowing)
    }

    @Test func conflictFailureIsRecorded() async throws {
        let service = GlobalHotkeyService(source: FakeEventSource())
        _ = try await service.register(.dictation, combo: .fn)
        _ = try? await service.register(.toggleLiveCaptions, combo: .fn)
        #expect(await service.refreshDiagnostics().failures[.toggleLiveCaptions]?.contains("already used") == true)
    }

    @Test func listenOnlySourceUpgradesWhenAccessibilityIsGranted() async throws {
        final class Upgradable: HotkeyEventSource, @unchecked Sendable {
            let mode = Mutex(HotkeyCapture.listenOnly)
            let starts = Mutex(0)
            var capture: HotkeyCapture { mode.withLock { $0 } }
            func start(handler: @escaping @Sendable (RawKeyEvent) -> Bool) throws {
                starts.withLock { $0 += 1 }
                mode.withLock { $0 = .swallowing }
            }
            func stop() {}
        }
        let source = Upgradable()
        source.mode.withLock { $0 = .listenOnly }
        let trusted = Mutex(false)
        let service = GlobalHotkeyService(
            source: source,
            system: HotkeySystemState(
                accessibilityTrusted: { trusted.withLock { $0 } }, inputMonitoringGranted: { true }, fnUsageType: { 0 }))
        // Simulate a listen-only start: first start leaves it listen-only.
        _ = try await service.register(.dictation, combo: .fn)
        source.mode.withLock { $0 = .listenOnly }
        #expect(await service.refreshDiagnostics().capture == .listenOnly)
        #expect(source.starts.withLock { $0 } == 1)
        trusted.withLock { $0 = true }
        let d = await service.refreshDiagnostics()
        #expect(d.capture == .swallowing)
        #expect(source.starts.withLock { $0 } == 2)
    }

    @Test func fallbackSourceUsesFirstSourceThatStartsAndReportsItsCapture() throws {
        let failing = FakeEventSource(failStart: true)
        let listen = FakeEventSource(capture: .listenOnly)
        let fallback = FallbackHotkeySource(sources: [failing, listen])
        #expect(fallback.capture == .unavailable)
        try fallback.start { _ in false }
        #expect(fallback.capture == .listenOnly)
        #expect(listen.starts == 1)
        fallback.stop()
        #expect(fallback.capture == .unavailable)
    }
}
