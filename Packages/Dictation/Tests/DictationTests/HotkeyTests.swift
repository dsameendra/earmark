import AppCore
import Foundation
import Testing

@testable import Dictation

@Suite("Hotkeys")
struct HotkeyTests {
    private func fnEvent(down: Bool) -> RawKeyEvent {
        RawKeyEvent(kind: .flagsChanged, keyCode: 63, modifiers: down ? ModifierMask.function : 0)
    }

    @Test func fnPressAndHoldProducesPressedThenReleased() {
        var m = HotkeyMatcher(combo: .fn)
        #expect(m.handle(fnEvent(down: true)) == .pressed)
        #expect(m.handle(fnEvent(down: true)) == nil)  // duplicate flagsChanged
        #expect(m.handle(fnEvent(down: false)) == .released)
        #expect(m.handle(fnEvent(down: false)) == nil)
    }

    @Test func otherModifierKeysDoNotTriggerFn() {
        var m = HotkeyMatcher(combo: .fn)
        #expect(m.handle(RawKeyEvent(kind: .flagsChanged, keyCode: 55, modifiers: ModifierMask.command)) == nil)
    }

    @Test func comboKeyDownUpWithModifiers() {
        let mods = ModifierMask.control | ModifierMask.option
        var m = HotkeyMatcher(combo: KeyCombo(keyCode: 2, modifiers: mods))  // ⌃⌥D
        #expect(m.handle(RawKeyEvent(kind: .keyDown, keyCode: 2, modifiers: mods)) == .pressed)
        #expect(m.handle(RawKeyEvent(kind: .keyDown, keyCode: 2, modifiers: mods, isAutorepeat: true)) == nil)
        #expect(m.handle(RawKeyEvent(kind: .keyUp, keyCode: 2, modifiers: 0)) == .released)
    }

    @Test func wrongModifiersIgnored() {
        var m = HotkeyMatcher(combo: KeyCombo(keyCode: 2, modifiers: ModifierMask.control))
        #expect(m.handle(RawKeyEvent(kind: .keyDown, keyCode: 2, modifiers: ModifierMask.command)) == nil)
    }

    @Test func releasingModifierFirstEndsHold() {
        var m = HotkeyMatcher(combo: KeyCombo(keyCode: 2, modifiers: ModifierMask.control))
        _ = m.handle(RawKeyEvent(kind: .keyDown, keyCode: 2, modifiers: ModifierMask.control))
        #expect(m.handle(RawKeyEvent(kind: .flagsChanged, keyCode: 59, modifiers: 0)) == .released)
    }

    @Test func serviceDeliversEventsAndStopsSourceWhenEmpty() async throws {
        let source = FakeEventSource()
        let service = GlobalHotkeyService(source: source)
        let stream = try await service.register(.dictation, combo: .fn)
        #expect(source.starts == 1)
        source.emit(fnEvent(down: true))
        source.emit(fnEvent(down: false))
        var got: [HotkeyEvent] = []
        for await e in stream {
            got.append(e)
            if got.count == 2 { break }
        }
        #expect(got == [.pressed, .released])
        await service.unregister(.dictation)
        #expect(source.stops == 1)
    }

    @Test func serviceRejectsConflictWithOtherEarmarkAction() async throws {
        let service = GlobalHotkeyService(source: FakeEventSource())
        _ = try await service.register(.dictation, combo: .fn)
        await #expect(throws: HotkeyError.conflict(.dictation)) {
            _ = try await service.register(.toggleLiveCaptions, combo: .fn)
        }
    }

    @Test func serviceReportsUnavailableSourceWithoutCrashing() async {
        let service = GlobalHotkeyService(source: FakeEventSource(failStart: true))
        await #expect(throws: HotkeyError.eventSourceUnavailable) { _ = try await service.register(.dictation, combo: .fn) }
    }

    @Test func reRegisteringSameActionReplacesComboAndFinishesOldStream() async throws {
        let source = FakeEventSource()
        let service = GlobalHotkeyService(source: source)
        let first = try await service.register(.dictation, combo: .fn)
        _ = try await service.register(.dictation, combo: KeyCombo(keyCode: 2, modifiers: ModifierMask.control))
        var firstEnded = true
        for await _ in first { firstEnded = false }
        #expect(firstEnded)
        #expect(source.starts == 1)
    }

    @Test func conflictCheckerRejectsEarmarkAndWarnsSystem() {
        let combo = KeyCombo(keyCode: 37, modifiers: ModifierMask.command | ModifierMask.shift)
        let existing: [HotkeyAction: KeyCombo] = [.toggleLiveCaptions: combo]
        let clash = ShortcutConflictChecker.check(combo, for: .dictation, existing: existing)
        #expect(clash == .earmarkAction(.toggleLiveCaptions))
        #expect(clash.isRejected)
        let sys = ShortcutConflictChecker.check(KeyCombo(keyCode: 49, modifiers: ModifierMask.command), for: .dictation, existing: [:])
        guard case .systemShortcut = sys else {
            Issue.record("expected system warning")
            return
        }
        #expect(!sys.isRejected)
        #expect(
            ShortcutConflictChecker.check(KeyCombo(keyCode: 2, modifiers: ModifierMask.control), for: .dictation, existing: existing)
                == .none)
        // Re-recording the action's own combo is not a conflict.
        #expect(ShortcutConflictChecker.check(combo, for: .toggleLiveCaptions, existing: existing) == .none)
    }

    @Test func conflictCheckerIgnoresNonModifierBitsInRawFlags() {
        // Raw CGEventFlags carry device bits; they must not defeat conflict detection.
        let existing: [HotkeyAction: KeyCombo] = [.bookmarkMoment: KeyCombo(keyCode: 11, modifiers: ModifierMask.command | 0x100)]
        let clash = ShortcutConflictChecker.check(
            KeyCombo(keyCode: 11, modifiers: ModifierMask.command), for: .dictation, existing: existing)
        #expect(clash.isRejected)
    }

    @Test func combosAreNamedForTheHUD() {
        #expect(KeyComboFormatter.name(for: .fn) == "Fn")
        #expect(KeyComboFormatter.name(for: KeyCombo(keyCode: 2, modifiers: ModifierMask.control | ModifierMask.option)) == "⌃⌥D")
    }
}

@Suite("Trigger state machine")
struct TriggerTests {
    @Test func pushToTalkStartsOnPressAndFinishesOnRelease() {
        var t = DictationTrigger(mode: .pushToTalk)
        #expect(t.handle(.pressed, at: 10) == .start)
        #expect(t.handle(.pressed, at: 10.1) == nil)
        #expect(t.handle(.released, at: 11) == .finish)
    }

    @Test func accidentalTapUnder250msCancels() {
        var t = DictationTrigger(mode: .pushToTalk)
        _ = t.handle(.pressed, at: 10)
        #expect(t.handle(.released, at: 10.2) == .cancel)
        _ = t.handle(.pressed, at: 20)
        #expect(t.handle(.released, at: 20.25) == .finish)
    }

    @Test func toggleFirstPressStartsSecondStops() {
        var t = DictationTrigger(mode: .toggle)
        #expect(t.handle(.pressed, at: 1) == .start)
        #expect(t.handle(.released, at: 1.05) == nil)
        #expect(t.handle(.pressed, at: 5) == .finish)
        #expect(t.handle(.released, at: 5.1) == nil)
        #expect(t.handle(.pressed, at: 8) == .start)
    }

    @Test func sessionEndedResetsSoReleaseIsIgnored() {
        var t = DictationTrigger(mode: .pushToTalk)
        _ = t.handle(.pressed, at: 1)
        t.sessionEnded()
        #expect(t.handle(.released, at: 3) == nil)
    }

    @Test func hintCopy() {
        #expect(DictationHint.text(mode: .pushToTalk, combo: .fn) == "Release Fn to insert")
        #expect(DictationHint.text(mode: .toggle, combo: .fn) == "Press Fn to insert")
    }

    @Test func autoPunctuationFormatting() {
        #expect(DictationTextFormatter.clean("  hello   world ", autoPunctuation: true) == "Hello world.")
        #expect(DictationTextFormatter.clean("hello  world", autoPunctuation: false) == "hello world")
        #expect(DictationTextFormatter.clean("Really?", autoPunctuation: true) == "Really?")
        #expect(DictationTextFormatter.clean("   ", autoPunctuation: true) == "")
    }
}
