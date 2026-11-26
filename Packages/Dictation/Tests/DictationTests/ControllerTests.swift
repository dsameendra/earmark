import AppCore
import AppCoreTesting
import Foundation
import Testing

@testable import Dictation

private struct Harness {
    let controller: DictationController
    let source: FakeEventSource
    let inserter: FakeInserter
    let history: MemoryHistory
    let hud: FakeHUD
    let notifier: FakeNotifier
    let onboarding: FakeOnboarding
    let permissions: FakePermissions
    let clock: ManualClock
    let settings: MemorySettings

    init(
        events: [TranscriptionEvent] = [.final(seg("hello world"))], failure: AppError? = nil,
        accessibility: PermissionStatus = .granted, insertError: (any Error)? = nil, sourceFails: Bool = false,
        configure: (inout DictationSettings) -> Void = { _ in }, rules: MemoryRules = MemoryRules(),
        translation: (any TranslationRouter)? = nil, warnings: [String] = [], holdAccessibilityCheck: Bool = false
    ) async {
        let source = FakeEventSource(failStart: sourceFails)
        let inserter = FakeInserter(error: insertError)
        let history = MemoryHistory()
        let hud = FakeHUD()
        let notifier = FakeNotifier()
        let onboarding = FakeOnboarding()
        let permissions = FakePermissions(accessibility: accessibility, holdCheck: holdAccessibilityCheck)
        let clock = ManualClock()
        let settings = MemorySettings()
        var s = DictationSettings()
        configure(&s)
        await s.save(to: settings)
        let engine = MockTranscriptionEngine(events: events, failure: failure)
        let deps = DictationDependencies(
            hotkeys: GlobalHotkeyService(source: source), makeAudioSource: { _ in MockAudioSource() },
            engineProvider: { _ in ResolvedDictationEngine(engine: engine, warnings: warnings) },
            pipeline: DictationPipeline(postProcessor: SpyProcessor(), rules: rules, translation: translation), inserter: inserter,
            history: DictationHistory(repository: history), settings: settings, permissions: permissions, hud: hud,
            notifier: notifier, onboarding: onboarding)
        self.controller = DictationController(dependencies: deps, clock: { clock.now }, finalizeTimeout: .seconds(2))
        self.source = source
        self.inserter = inserter
        self.history = history
        self.hud = hud
        self.notifier = notifier
        self.onboarding = onboarding
        self.permissions = permissions
        self.clock = clock
        self.settings = settings
    }

    func hold(seconds: TimeInterval = 1) async {
        await controller.handle(.pressed)
        clock.advance(seconds)
        await controller.handle(.released)
    }
}

@Suite("Dictation controller")
struct ControllerTests {
    @Test func pushToTalkCapturesFinalizesInsertsAndSavesHistory() async throws {
        let h = await Harness()
        await h.controller.start()
        await h.hold()
        #expect(h.inserter.texts == ["hello world"])
        #expect(h.inserter.methods == [.pasteboardPaste])
        let saved = await h.history.entries
        #expect(saved.map(\.text) == ["hello world"])
        let log = h.hud.log
        #expect(log.first == "show:Release Fn to insert")
        #expect(log.contains("processing") && log.last == "dismiss")
        #expect(log.firstIndex(of: "processing")! < log.lastIndex(of: "dismiss")!)
        await h.controller.stop()
    }

    @Test func fullPathThroughRealHotkeyServiceWithFnEvents() async throws {
        let h = await Harness()
        await h.controller.start()
        h.source.emit(RawKeyEvent(kind: .flagsChanged, keyCode: 63, modifiers: ModifierMask.function))
        #expect(await eventually { h.hud.log.contains { $0.hasPrefix("show") } })
        h.clock.advance(1)
        h.source.emit(RawKeyEvent(kind: .flagsChanged, keyCode: 63, modifiers: 0))
        #expect(await eventually { h.inserter.texts == ["hello world"] })
        await h.controller.stop()
    }

    @Test func toggleModeFirstPressStartsSecondInserts() async {
        let h = await Harness(configure: { $0.mode = .toggle })
        await h.controller.start()
        await h.controller.handle(.pressed)
        await h.controller.handle(.released)
        #expect(h.inserter.texts.isEmpty)
        #expect(h.hud.log.first == "show:Press Fn to insert")
        h.clock.advance(2)
        await h.controller.handle(.pressed)
        #expect(h.inserter.texts == ["hello world"])
    }

    @Test func releaseDuringAccessibilityCheckDoesNotLeaveDictationListening() async {
        let h = await Harness(holdAccessibilityCheck: true)
        await h.controller.start()
        let pressed = Task { await h.controller.handle(.pressed) }
        await h.permissions.checkStarted()
        h.clock.advance(1)
        await h.controller.handle(.released)  // arrives while the Accessibility check is still running
        h.permissions.releaseCheck()
        await pressed.value
        #expect(!h.hud.log.contains { $0.hasPrefix("show") })
        var states = h.controller.states().makeAsyncIterator()
        #expect(await states.next() == .idle)
        #expect(h.inserter.texts.isEmpty)
        // The slot is free again.
        await h.hold()
        #expect(h.inserter.texts == ["hello world"])
    }

    @Test func cancelDuringAccessibilityCheckIsHonoured() async {
        let h = await Harness(holdAccessibilityCheck: true)
        await h.controller.start()
        let pressed = Task { await h.controller.handle(.pressed) }
        await h.permissions.checkStarted()
        await h.controller.cancel()  // arrives while the Accessibility check is still running
        h.permissions.releaseCheck()
        await pressed.value
        #expect(!h.hud.log.contains { $0.hasPrefix("show") })
        var states = h.controller.states().makeAsyncIterator()
        #expect(await states.next() == .idle)
    }

    @Test func fallbackNoticeFromTheRouterIsShownToTheUser() async {
        let notice = "Apple Speech is unavailable. Using Whisper instead."
        let h = await Harness(warnings: [notice])
        await h.controller.start()
        await h.hold()
        #expect(h.notifier.notices.contains(DictationNotice(kind: .info, message: notice)))
        #expect(h.inserter.texts == ["hello world"])
    }

    @Test func accidentalTapCancelsWithoutInserting() async {
        let h = await Harness()
        await h.controller.start()
        await h.hold(seconds: 0.1)
        #expect(h.inserter.texts.isEmpty)
        #expect(h.hud.log.last == "dismiss")
        #expect(await h.history.entries.isEmpty)
        // And a normal dictation still works afterwards.
        await h.hold()
        #expect(h.inserter.texts == ["hello world"])
    }

    @Test func engineFailureDismissesHUDWithErrorAndNeverInsertsPartialText() async {
        let h = await Harness(
            events: [.partial(PartialSegment(text: "half a sent", start: 0))], failure: .engineFailure("e", reason: "boom"))
        await h.controller.start()
        await h.controller.handle(.pressed)
        #expect(await eventually { h.hud.log.contains { $0.hasPrefix("error:") } })
        h.clock.advance(1)
        await h.controller.handle(.released)
        #expect(h.inserter.texts.isEmpty)
        #expect(await h.history.entries.isEmpty)
    }

    @Test func accessibilityDeniedShowsOnboardingAndNeverCapturesOrInserts() async {
        let h = await Harness(accessibility: .denied)
        await h.controller.start()
        await h.hold()
        #expect(h.onboarding.presented == 1)
        #expect(h.hud.log.isEmpty)
        #expect(h.inserter.texts.isEmpty)
        var states = h.controller.states().makeAsyncIterator()
        #expect(await states.next() == .needsAccessibility)
    }

    @Test func accessibilityGrantIsDetectedWithoutRestart() async {
        let h = await Harness(accessibility: .denied)
        await h.controller.start()
        await h.hold()
        h.permissions.grant()
        #expect(await eventually { h.onboarding.dismissed == 1 })
        #expect(await eventually {
            var it = h.controller.states().makeAsyncIterator()
            return await it.next() == .idle
        })
        await h.hold()
        #expect(h.inserter.texts == ["hello world"])
    }

    @Test func secureInputRefusalIsReportedNotSilent() async {
        let h = await Harness(insertError: DictationError.secureInputActive)
        await h.controller.start()
        await h.hold()
        #expect(h.inserter.texts.isEmpty)
        #expect(h.notifier.notices.contains { $0.kind == .error && $0.message.contains("password") })
        #expect(await h.history.entries.isEmpty)
    }

    @Test func insertionPermissionLossFallsBackToOnboarding() async {
        let h = await Harness(insertError: AppError.permissionDenied(.accessibility))
        await h.controller.start()
        await h.hold()
        #expect(h.onboarding.presented == 1)
    }

    @Test func emptyAfterProcessingDoesNotInsert() async {
        let h = await Harness(events: [.final(seg("um"))], rules: MemoryRules(ignore: [IgnoreRule(pattern: "um")]))
        await h.controller.start()
        await h.hold()
        #expect(h.inserter.texts.isEmpty)
        #expect(await h.history.entries.isEmpty)
        #expect(h.hud.log.last == "dismiss")
    }

    @Test func historyDisabledInsertsButDoesNotSave() async {
        let h = await Harness(configure: { $0.historyEnabled = false })
        await h.controller.start()
        await h.hold()
        #expect(h.inserter.texts == ["hello world"])
        #expect(await h.history.entries.isEmpty)
    }

    @Test func insertionMethodFromSettingsIsUsed() async {
        let h = await Harness(configure: { $0.insertionMethod = .accessibility })
        await h.controller.start()
        await h.hold()
        #expect(h.inserter.methods == [.accessibility])
    }

    @Test func translationFailureInsertsOriginalAndNotifies() async {
        let h = await Harness(
            configure: {
                $0.translateBeforeInsert = true
                $0.translationTarget = .sinhala
            }, translation: ThrowingTranslationRouter())
        await h.controller.start()
        await h.hold()
        #expect(h.inserter.texts == ["hello world"])
        #expect(h.notifier.notices.contains { $0.kind == .warning && $0.message.contains("Translation") })
    }

    @Test func hotkeySourceUnavailableDegradesGracefully() async {
        let h = await Harness(sourceFails: true)
        await h.controller.start()
        var it = h.controller.states().makeAsyncIterator()
        #expect(await it.next() == .hotkeyUnavailable)
        // Programmatic start (menu bar) still works: the app is never blocked.
        await h.hold()
        #expect(h.inserter.texts == ["hello world"])
    }

    @Test func conflictingComboSurfacesAsFailedState() async {
        let source = FakeEventSource()
        let service = GlobalHotkeyService(source: source)
        _ = try? await service.register(.toggleLiveCaptions, combo: .fn)
        let engine = MockTranscriptionEngine()
        let deps = DictationDependencies(
            hotkeys: service, makeAudioSource: { _ in MockAudioSource() },
            engineProvider: { _ in ResolvedDictationEngine(engine: engine) },
            pipeline: DictationPipeline(postProcessor: SpyProcessor(), rules: MemoryRules()), inserter: FakeInserter(),
            history: DictationHistory(repository: MemoryHistory()), settings: MemorySettings(), permissions: FakePermissions(),
            hud: FakeHUD(), notifier: FakeNotifier(), onboarding: FakeOnboarding())
        let c = DictationController(dependencies: deps)
        await c.start()
        var it = c.states().makeAsyncIterator()
        guard case .failed = await it.next() else {
            Issue.record("expected failed state")
            return
        }
    }

    @Test func cancelDuringSessionDismissesAndDoesNotInsert() async {
        let h = await Harness()
        await h.controller.start()
        await h.controller.handle(.pressed)
        await h.controller.cancel()
        #expect(h.hud.log.last == "dismiss")
        #expect(h.inserter.texts.isEmpty)
    }

    @Test func partialTextReachesHUDAndStateStream() async {
        let h = await Harness(events: [.partial(PartialSegment(text: "hel", start: 0)), .final(seg("hello"))])
        await h.controller.start()
        await h.controller.handle(.pressed)
        #expect(await eventually { h.hud.log.contains("partial:hello") })
        await h.controller.cancel()
    }
}
