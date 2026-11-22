import AppCore
import AppKit
import DesignSystem
import SwiftUI
import AppCoreTesting
import Testing

@testable import LiveCaptions

// MARK: - Line state machine

@Suite("CaptionLineStore")
struct CaptionLineStoreTests {
    @Test("Volatile line finalizes in place, keeping its id and position")
    func inPlace() {
        var store = CaptionLineStore()
        let a = store.setVolatile(lane: 0, text: "hel", start: 0, language: nil, laneLabel: nil)
        store.setVolatile(lane: 0, text: "hello", start: 0, language: nil, laneLabel: nil)
        #expect(store.lines.count == 1)
        let finalID = store.finalize(
            lane: 0, text: "Hello.", start: 0, end: 1, language: .english, segmentID: SegmentID(), laneLabel: nil)
        #expect(finalID == a)
        #expect(store.lines.map(\.text) == ["Hello."])
        #expect(store.lines[0].isVolatile == false)
        let b = store.setVolatile(lane: 0, text: "next", start: 1, language: nil, laneLabel: nil)
        #expect(b != a)
        #expect(store.lines.map(\.id) == [a, b])
    }

    @Test("Lanes keep independent volatile lines")
    func lanes() {
        var store = CaptionLineStore()
        store.setVolatile(lane: 0, text: "me", start: 0, language: nil, laneLabel: "You")
        store.setVolatile(lane: 1, text: "them", start: 0, language: nil, laneLabel: "Them")
        #expect(store.lines.map(\.speakerLabel) == ["You", "Them"])
        store.removeVolatile(lane: 0)
        #expect(store.lines.map(\.text) == ["them"])
    }

    @Test("Very long unpunctuated speech keeps a rolling tail on a word boundary")
    func rolling() {
        let words = (0..<200).map { "word\($0)" }.joined(separator: " ")
        let tail = CaptionLineStore.rollingTail(words)
        #expect(tail.count <= CaptionLineStore.volatileCharacterLimit)
        #expect(tail.hasSuffix("word199"))
        #expect(tail.hasPrefix("word"))
    }

    @Test("Retained lines are bounded")
    func bounded() {
        var store = CaptionLineStore(maxRetained: 3)
        for i in 0..<10 {
            store.finalize(lane: 0, text: "\(i)", start: 0, end: 1, language: nil, segmentID: SegmentID(), laneLabel: nil)
        }
        #expect(store.lines.map(\.text) == ["7", "8", "9"])
    }
}

@Suite("LiveSpeakerTimeline")
struct LiveSpeakerTimelineTests {
    @Test("First-appearance order, capped at maxLiveSpeakers")
    func cap() {
        var t = LiveSpeakerTimeline()
        for (i, slot) in [7, 3, 9, 1, 5].enumerated() {
            t.apply(SpeakerTurn(range: TimeRange(start: Double(i), end: Double(i) + 1), slot: slot))
        }
        #expect(t.label(for: TimeRange(start: 0, end: 1))?.name == "Speaker 1")
        #expect(t.label(for: TimeRange(start: 3, end: 4))?.name == "Speaker 4")
        #expect(t.label(for: TimeRange(start: 4, end: 5)) == LiveSpeakerTimeline.Label(name: "More speakers", index: nil))
        #expect(t.limitReached)
        #expect(t.label(for: TimeRange(start: 20, end: 21)) == nil)
    }

    @Test("A revised turn replaces the older one for the same slot")
    func revision() {
        var t = LiveSpeakerTimeline()
        t.apply(SpeakerTurn(range: TimeRange(start: 0, end: 1), slot: 0, isProvisional: true))
        t.apply(SpeakerTurn(range: TimeRange(start: 0, end: 1.5), slot: 0))
        #expect(t.turns.count == 1)
        #expect(t.turns[0].isProvisional == false)
    }

    @Test("Reconciliation maps live slots to offline slots by overlap")
    func reconcile() {
        var t = LiveSpeakerTimeline()
        t.apply(SpeakerTurn(range: TimeRange(start: 0, end: 5), slot: 0))
        t.apply(SpeakerTurn(range: TimeRange(start: 5, end: 10), slot: 1))
        let map = t.reconciliation(offline: [
            SpeakerTurn(range: TimeRange(start: 0, end: 5.5), slot: 1),
            SpeakerTurn(range: TimeRange(start: 5.5, end: 10), slot: 0),
        ])
        #expect(map == [0: 1, 1: 0])
    }
}

// MARK: - Presets

@Suite("Caption presets")
struct CaptionPresetTests {
    @Test("Built-ins exist and cannot be deleted or edited; Save As makes a user preset (LIVE-AC-11)")
    func builtIns() async throws {
        #expect(CaptionPresetCatalog.builtIns.map(\.name) == ["Subtle", "Presentation", "High contrast"])
        #expect(CaptionPresetCatalog.builtIns.allSatisfy { $0.isBuiltIn })
        let store = CaptionPresetStore(repository: InMemoryPresets(), settings: InMemorySettings())
        for preset in CaptionPresetCatalog.builtIns {
            await #expect(throws: CaptionPresetError.builtInPresetIsReadOnly) { try await store.delete(preset.id) }
            await #expect(throws: CaptionPresetError.builtInPresetIsReadOnly) { try await store.update(preset) }
        }
        let copy = try await store.saveAs(CaptionPresetCatalog.highContrast, name: "My captions")
        #expect(copy.isBuiltIn == false)
        #expect(copy.id != CaptionPresetCatalog.highContrastID)
        let all = try await store.all()
        #expect(all.count == 4)
        try await store.delete(copy.id)
        #expect(try await store.all().count == 3)
    }

    @Test("Active preset persists and falls back to Subtle")
    func active() async throws {
        let store = CaptionPresetStore(repository: InMemoryPresets(), settings: InMemorySettings())
        #expect(try await store.activePreset().id == CaptionPresetCatalog.subtleID)
        await store.setActive(CaptionPresetCatalog.presentationID)
        #expect(try await store.activePreset().id == CaptionPresetCatalog.presentationID)
    }

    @Test("Sanitizing clamps lines to 1...6, size and opacity")
    func clamps() {
        var p = CaptionPreset(name: "x", fontSize: 500, backgroundOpacity: 3, visibleLines: 99)
        p = CaptionPresetCatalog.sanitized(p)
        #expect(p.visibleLines == 6 && p.fontSize == 96 && p.backgroundOpacity == 1)
        #expect(CaptionPresetCatalog.sanitized(CaptionPreset(name: "y", visibleLines: 0)).visibleLines == 1)
    }

    @Test("Preset codec round trips (built-ins included)")
    func codec() throws {
        for p in CaptionPresetCatalog.builtIns {
            let data = try JSONEncoder().encode(p)
            #expect(try JSONDecoder().decode(CaptionPreset.self, from: data) == p)
        }
    }

    @Test("Hex colours and weights")
    func style() {
        let c = CaptionStyle.rgba(fromHex: "#FF8000")
        #expect(c?.r == 1 && abs((c?.g ?? 0) - 128 / 255) < 0.001 && c?.b == 0 && c?.a == 1)
        #expect(CaptionStyle.rgba(fromHex: "#12345678")?.a ?? 0 > 0.46)
        #expect(CaptionStyle.rgba(fromHex: "nope") == nil)
        #expect(CaptionStyle.weight(for: 0) == .regular)
        #expect(CaptionStyle.weight(for: 0.4) == .bold)
        #expect(CaptionSizeStep.nearest(to: 30) == .medium)
        #expect(CaptionStyle.panelHeight(for: CaptionPreset(name: "t", visibleLines: 3)) > CaptionStyle.panelHeight(for: CaptionPreset(name: "t", visibleLines: 1)))
    }
}

// MARK: - Placement (LIVE-AC-03)

@Suite("OverlayPlacement")
struct OverlayPlacementTests {
    let bounds = CGRect(x: 0, y: 0, width: 1_000, height: 800)

    @Test("Snaps to edges within 12 pt and not beyond")
    func snap() {
        let near = CGRect(x: 11, y: 5, width: 300, height: 100)
        #expect(OverlayPlacement.snap(near, within: bounds) == CGRect(x: 0, y: 0, width: 300, height: 100))
        let far = CGRect(x: 13, y: 13, width: 300, height: 100)
        #expect(OverlayPlacement.snap(far, within: bounds) == far)
        let right = CGRect(x: 1_000 - 300 - 12, y: 800 - 100 - 3, width: 300, height: 100)
        #expect(OverlayPlacement.snap(right, within: bounds) == CGRect(x: 700, y: 700, width: 300, height: 100))
    }

    @Test("Clamp keeps the overlay on screen")
    func clamp() {
        let r = OverlayPlacement.clamp(CGRect(x: 900, y: -50, width: 300, height: 100), to: bounds)
        #expect(r == CGRect(x: 700, y: 0, width: 300, height: 100))
    }

    @Test("Preset resize keeps centre and bottom")
    func resize() {
        let r = OverlayPlacement.resized(CGRect(x: 400, y: 100, width: 200, height: 80), to: CGSize(width: 400, height: 120), within: bounds)
        #expect(r == CGRect(x: 300, y: 100, width: 400, height: 120))
    }

    @Test("Stored frames are relative to the display and survive rearrangement")
    func relative() {
        let d1 = DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1_000, height: 800), isPrimary: true)
        let d2 = DisplayInfo(id: 2, frame: CGRect(x: 1_000, y: 0, width: 1_000, height: 800))
        let stored = OverlayPlacement.store(CGRect(x: 1_100, y: 50, width: 300, height: 100), on: d2)
        #expect(stored == StoredOverlayFrame(x: 100, y: 50, width: 300, height: 100))
        let moved = DisplayInfo(id: 2, frame: CGRect(x: -1_000, y: 0, width: 1_000, height: 800))
        #expect(OverlayPlacement.restore(stored, on: moved) == CGRect(x: -900, y: 50, width: 300, height: 100))
        #expect(OverlayPlacement.display(containing: CGRect(x: 1_100, y: 50, width: 300, height: 100), in: [d1, d2])?.id == 2)
    }

    @Test("A missing saved display falls back to the primary")
    func hotPlug() {
        let d1 = DisplayInfo(id: 1, frame: bounds, isPrimary: true)
        #expect(OverlayPlacement.resolveDisplay(preferred: 9, in: [d1])?.id == 1)
        #expect(OverlayPlacement.resolveDisplay(preferred: nil, in: [d1])?.id == 1)
        #expect(OverlayPlacement.resolveDisplay(preferred: 1, in: []) == nil)
    }

    @Test("Frame memory is keyed per display ID")
    func perDisplayStore() async {
        let store = OverlayFrameStore(settings: InMemorySettings())
        await store.save(StoredOverlayFrame(x: 1, y: 2, width: 3, height: 4), for: 10)
        await store.save(StoredOverlayFrame(x: 5, y: 6, width: 7, height: 8), for: 20)
        #expect(await store.frame(for: 10)?.x == 1)
        #expect(await store.frame(for: 20)?.x == 5)
        #expect(await store.frame(for: 30) == nil)
        #expect(await store.lastDisplayID() == 20)
    }
}

// MARK: - Overlay model, view, panel

@MainActor
@Suite("Caption overlay")
struct CaptionOverlayTests {
    @Test("Visible lines follow the preset's line count and never exceed 6")
    func visibleLines() {
        let model = CaptionOverlayModel(preset: CaptionPreset(name: "t", visibleLines: 2))
        model.ingest((0..<5).map { CaptionLine(text: "l\($0)", isVolatile: false) })
        #expect(model.visibleLines.map(\.text) == ["l3", "l4"])
        model.preset.visibleLines = 50
        #expect(model.visibleLines.count == 5)
    }

    @Test("Translation low-confidence marker is parsed")
    func translation() {
        #expect(CaptionOverlayModel.parseTranslation(nil) == nil)
        #expect(CaptionOverlayModel.parseTranslation("plain")?.isLowConfidence == false)
        let marked = LiveCaptionMarkers.lowConfidenceTranslationPrefix + "text"
        let parsed = CaptionOverlayModel.parseTranslation(marked)
        #expect(parsed?.text == "text" && parsed?.isLowConfidence == true)
    }

    @Test("Overlay fades after silence and returns on speech (LIVE-AC-09)")
    func autoHide() async {
        let model = CaptionOverlayModel(preset: CaptionPreset(name: "t", autoHideAfterSilence: 0.1))
        model.isCaptioning = true
        model.ingest([CaptionLine(text: "hello", isVolatile: true)])
        #expect(model.isFaded == false)
        #expect(await waitUntilMain { model.isFaded })
        model.ingest([CaptionLine(text: "hello again", isVolatile: true)])
        #expect(model.isFaded == false)
    }

    @Test("Never fades when auto-hide is off")
    func noAutoHide() async throws {
        let model = CaptionOverlayModel(preset: CaptionPreset(name: "t", autoHideAfterSilence: nil))
        model.isCaptioning = true
        model.ingest([CaptionLine(text: "x", isVolatile: false)])
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.isFaded == false)
    }

    @Test("Overlay renders in glass and in the Reduce Transparency / Increase Contrast solid fallback (LIVE-AC-10)")
    func renders() {
        let model = CaptionOverlayModel()
        model.isCaptioning = true
        model.ingest([
            CaptionLine(text: "Hello world", translation: LiveCaptionMarkers.lowConfidenceTranslationPrefix + "ආයුබෝවන්", speakerLabel: "Speaker 1", speakerSlot: 0, language: .english, isVolatile: false),
            CaptionLine(text: "partial text", isVolatile: true),
        ])
        model.preset.showTranslation = true
        for policy in [AccessibilityPolicy(), AccessibilityPolicy(reduceTransparency: true), AccessibilityPolicy(increaseContrast: true, reduceMotion: true)] {
            let view = CaptionOverlayView(model: model)
                .environment(\.accessibilityPolicyOverride, policy)
                .frame(width: 700, height: 160)
            let renderer = ImageRenderer(content: view)
            #expect(renderer.cgImage != nil)
        }
        #expect(AccessibilityPolicy(reduceTransparency: true).usesSolidSurface)
        #expect(AccessibilityPolicy(increaseContrast: true).usesHighContrast)
    }

    @Test("Panel is a non-activating floating panel on all spaces and above fullscreen that never takes focus (LIVE-AC-01, 20)")
    func panelProperties() {
        let panel = CaptionPanel(contentRect: CGRect(x: 0, y: 0, width: 400, height: 100))
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.isFloatingPanel)
        #expect(panel.level == .floating)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.canBecomeKey == false)
        #expect(panel.canBecomeMain == false)
        #expect(panel.hidesOnDeactivate == false)
    }

    @Test("Controller shows, remembers the frame per display, toggles click-through (LIVE-AC-02, 03)")
    func controller() async {
        let settings = InMemorySettings()
        let display = DisplayInfo(id: 42, frame: CGRect(x: 0, y: 0, width: 1_440, height: 900), visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 870), isPrimary: true)
        let provider = FixedDisplays(list: [display])
        let controller = CaptionOverlayController(settings: settings, displays: provider)

        await controller.show(preset: CaptionPresetCatalog.subtle)
        let panel = controller.panel
        #expect(controller.isVisible)
        #expect(panel?.ignoresMouseEvents == true)  // click-through defaults on
        let first = panel?.frame
        #expect(first.map { display.visibleFrame.contains($0) } == true)

        await controller.setClickThrough(false)
        #expect(panel?.ignoresMouseEvents == false)
        #expect(await settings.value(for: CaptionOverlayController.clickThroughKey, as: Bool.self) == false)
        await controller.toggleClickThrough()
        #expect(panel?.ignoresMouseEvents == true)

        // User moves the panel near the bottom-left edge; hiding snaps (within 12 pt) and remembers the frame.
        panel?.setFrame(CGRect(x: 7, y: 9, width: 500, height: 100), display: false)
        await controller.hide()
        #expect(controller.isVisible == false)
        let stored = await OverlayFrameStore(settings: settings).frame(for: 42)
        #expect(stored == StoredOverlayFrame(x: 0, y: 0, width: 500, height: 100))

        await controller.show(preset: CaptionPresetCatalog.subtle)
        #expect(controller.panel?.frame == CGRect(x: 0, y: 0, width: 500, height: 100))
        await controller.hide()
    }

    @Test("Holding Option makes a click-through overlay temporarily interactive (LIVE-AC-02)")
    func modifierHover() async {
        let display = DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1_000, height: 700), isPrimary: true)
        let controller = CaptionOverlayController(settings: InMemorySettings(), displays: FixedDisplays(list: [display]))
        await controller.show(preset: CaptionPresetCatalog.subtle)
        #expect(controller.panel?.ignoresMouseEvents == true)
        controller.setModifierOverride(true)
        #expect(controller.panel?.ignoresMouseEvents == false)
        controller.setModifierOverride(false)
        #expect(controller.panel?.ignoresMouseEvents == true)
        await controller.hide()
    }

    @Test("A saved display that is no longer attached falls back to the primary")
    func controllerHotPlug() async {
        let settings = InMemorySettings()
        let frames = OverlayFrameStore(settings: settings)
        await frames.save(StoredOverlayFrame(x: 100, y: 100, width: 400, height: 100), for: 99)
        let primary = DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1_000, height: 700), isPrimary: true)
        let controller = CaptionOverlayController(settings: settings, displays: FixedDisplays(list: [primary]))
        await controller.show(preset: CaptionPresetCatalog.subtle)
        #expect(controller.panel.map { primary.frame.contains($0.frame) } == true)
        await controller.hide()
    }
}

@MainActor
struct FixedDisplays: DisplayProviding {
    var list: [DisplayInfo]
    func displays() -> [DisplayInfo] { list }
}

// MARK: - Router-backed engine provider

struct FixedRouter: EngineRouter {
    var plan: EnginePlan
    func plan(for request: RoutingRequest) throws -> EnginePlan { plan }
}

struct FixedHardware: HardwareTierProviding {
    var profile: HardwareProfile { HardwareProfile(chip: "test", memoryBytes: 16 << 30, performanceCores: 8, tier: .tier16) }
    func memoryPressure() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    func thermalPressure() -> AsyncStream<ThermalPressure> { AsyncStream { $0.finish() } }
    func isOnBattery() -> Bool { false }
}

@Suite("RouterEngineProvider")
struct RouterEngineProviderTests {
    private func provider(_ assignment: EngineAssignment, registry: [EngineID: ScriptedEngine]) -> RouterEngineProvider {
        RouterEngineProvider(
            router: FixedRouter(plan: EnginePlan(assignments: [assignment])), hardware: FixedHardware(),
            models: MockModelManager(), engine: { registry[$0] })
    }

    @Test("Uses the router's live plan to pick the registered engine and model")
    func picks() async throws {
        let engine = ScriptedEngine([])
        let p = provider(EngineAssignment(language: nil, engine: "scripted", model: "m/1"), registry: ["scripted": engine])
        let selection = try await p.resolve(languageMode: .default)
        #expect(selection.engine.id == "scripted" && selection.model == "m/1")
    }

    @Test("Missing model or unregistered engine is an error, not a crash")
    func errors() async {
        let needsDownload = provider(
            EngineAssignment(language: nil, engine: "scripted", model: "m/1", requiresDownload: true), registry: ["scripted": ScriptedEngine([])])
        await #expect(throws: AppError.modelNotInstalled("m/1")) { try await needsDownload.resolve(languageMode: .default) }
        let missing = provider(EngineAssignment(language: nil, engine: "nope", model: nil), registry: [:])
        await #expect(throws: AppError.engineFailure("nope", reason: "Engine is not registered")) {
            try await missing.resolve(languageMode: .default)
        }
    }
}
