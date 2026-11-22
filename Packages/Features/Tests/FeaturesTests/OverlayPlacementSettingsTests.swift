import AppCore
import AppCoreTesting
import FeatureSettings
import FeatureSupport
import Foundation
import LiveCaptions
import Testing

@MainActor
private final class FakeDisplays: DisplayProviding {
    var list: [DisplayInfo]
    var active: UInt32?
    init(_ list: [DisplayInfo], active: UInt32? = nil) {
        self.list = list
        self.active = active
    }
    func displays() -> [DisplayInfo] { list }
    func activeDisplayID() -> UInt32? { active }
}

@MainActor
private final class FakeOverlay: OverlayPlacementControlling {
    var changes = 0
    var previews: [CaptionPreset?] = []
    var testShown = 0
    var testHidden = 0
    var clickThrough: Bool?
    var isTestCaptionActive = false
    var onLayoutChange: (@MainActor () -> Void)?
    func placementDidChange(previewing preset: CaptionPreset?) async {
        changes += 1
        previews.append(preset)
    }
    func showTestCaption(preset: CaptionPreset) async { testShown += 1 }
    func hideTestCaption() async { testHidden += 1 }
    func setClickThrough(_ enabled: Bool) async { clickThrough = enabled }
}

private let main = DisplayInfo(
    id: 1, frame: CGRect(x: 0, y: 0, width: 1_440, height: 900), visibleFrame: CGRect(x: 0, y: 70, width: 1_440, height: 805),
    isPrimary: true, name: "Built-in Retina Display")
private let side = DisplayInfo(
    id: 2, frame: CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080), visibleFrame: CGRect(x: -1_920, y: 0, width: 1_920, height: 1_055),
    name: "DELL U2723QE")

@Suite @MainActor struct OverlayPlacementSettingsTests {
    private func make(
        displays: [DisplayInfo] = [main, side], store: InMemorySettingsStore = InMemorySettingsStore()
    ) -> (OverlayPlacementSettingsModel, FakeOverlay, FakeDisplays, InMemorySettingsStore) {
        let overlay = FakeOverlay()
        let provider = FakeDisplays(displays)
        let model = OverlayPlacementSettingsModel(store: store, displays: provider, controller: overlay)
        return (model, overlay, provider, store)
    }

    @Test func defaultsAreMainDisplayBottomCentre() async {
        let (model, _, _, _) = make()
        await model.load()
        #expect(model.choice == .main)
        #expect(model.position == .bottomCenter)
        #expect(model.allowsDragging == false)
    }

    @Test func optionsListMainFollowAndEveryDisplayByName() async {
        let (model, _, _, _) = make()
        await model.load()
        let titles = model.choiceOptions.map(\.title)
        #expect(titles.first == "Main display")
        #expect(titles[1].hasPrefix("Follow the active window"))
        #expect(titles.contains("Built-in Retina Display - Main"))
        #expect(titles.contains("DELL U2723QE"))
        #expect(model.choiceOptions.map(\.id) == [.main, .followActive, .display(1), .display(2)])
    }

    @Test func displayAndPositionPersistAndMoveTheOverlay() async {
        let (model, overlay, _, store) = make()
        await model.load()
        await model.selectChoice(.display(2))
        await model.selectPosition(.topRight)
        #expect(overlay.changes == 2)
        #expect(overlay.previews.allSatisfy { $0 != nil })  // a change always previews, even with no live session
        #expect(await store.value(for: SettingsKey.liveOverlayDisplayChoice, as: String.self) == "display:2")
        #expect(await store.value(for: SettingsKey.liveOverlayPosition(display: 2), as: String.self) == "topRight")

        // A fresh model (next launch) sees the same choice.
        let (again, _, _, _) = make(store: store)
        await again.load()
        #expect(again.choice == .display(2))
        #expect(again.position == .topRight)
    }

    @Test func positionIsRememberedPerDisplay() async {
        let (model, _, _, _) = make()
        await model.load()
        await model.selectChoice(.display(1))
        await model.selectPosition(.bottomLeft)
        await model.selectChoice(.display(2))
        #expect(model.position == .bottomCenter)  // nothing saved for this display yet
        await model.selectPosition(.middleRight)
        await model.selectChoice(.display(1))
        #expect(model.position == .bottomLeft)
        await model.selectChoice(.display(2))
        #expect(model.position == .middleRight)
    }

    @Test func unpluggedDisplayFallsBackToMainButStaysSelected() async {
        let (model, _, provider, _) = make()
        await model.load()
        await model.selectChoice(.display(2))
        #expect(model.effectiveDisplay?.id == 2)
        provider.list = [main]
        model.refreshDisplays()
        #expect(model.effectiveDisplay?.id == 1)
        #expect(model.isChosenDisplayMissing)
        #expect(model.choice == .display(2))
        #expect(model.choiceOptions.last?.id == .display(2))  // still shown so the picker has a selection
        provider.list = [main, side]
        model.refreshDisplays()
        #expect(model.effectiveDisplay?.id == 2)
        #expect(model.isChosenDisplayMissing == false)
    }

    @Test func followUsesTheActiveDisplay() async {
        let (model, _, provider, _) = make()
        await model.load()
        await model.selectChoice(.followActive)
        provider.active = 2
        #expect(model.effectiveDisplay?.id == 2)
        provider.active = nil
        #expect(model.effectiveDisplay?.id == 1)
    }

    @Test func resetPositionRestoresDefaultAndClearsDraggedFrames() async {
        let (model, overlay, _, store) = make()
        await model.load()
        await model.selectChoice(.display(2))
        await model.selectPosition(.custom)
        let layout = OverlayLayoutStore(settings: store)
        let frame = StoredOverlayFrame(x: 10, y: 10, width: 400, height: 100)
        await layout.setCustomFrame(frame, display: 2, preset: CaptionPresetCatalog.subtleID)
        await OverlayFrameStore(settings: store).save(frame, for: 2)

        await model.resetPosition()
        #expect(model.position == .bottomCenter)
        #expect(await layout.storedPosition(for: .display(2)) == .bottomCenter)
        #expect(await layout.customFrame(display: 2, preset: CaptionPresetCatalog.subtleID) == nil)
        #expect(await OverlayFrameStore(settings: store).frame(for: 2) == nil)
        #expect(overlay.changes == 3)
    }

    @Test func draggingToggleWritesClickThroughAndTellsTheOverlay() async {
        let (model, overlay, _, store) = make()
        await model.load()
        await model.setAllowsDragging(true)
        #expect(model.allowsDragging)
        #expect(overlay.clickThrough == false)
        let loaded = OverlayPlacementSettingsModel(store: store, displays: FakeDisplays([main]), controller: nil)
        await loaded.setAllowsDragging(true)
        #expect(await store.value(for: SettingsKey.liveClickThrough, as: Bool.self) == false)
    }

    @Test func testCaptionButtonsReachTheOverlay() async {
        let (model, overlay, _, _) = make()
        await model.showTestCaption()
        await model.hideTestCaption()
        #expect(overlay.testShown == 1 && overlay.testHidden == 1)
        let none = OverlayPlacementSettingsModel(store: InMemorySettingsStore(), displays: FakeDisplays([main]), controller: nil)
        #expect(none.canPreview == false)
        await none.showTestCaption()  // no overlay wired: nothing happens, no crash
    }

    @Test func overlayDragRefreshesThePickers() async {
        let (model, overlay, _, store) = make()
        await model.load()
        // The overlay was dragged onto the second display and saved Custom there.
        let layout = OverlayLayoutStore(settings: store)
        await layout.setDisplayChoice(.display(2))
        await layout.setPosition(.custom, for: .display(2))
        overlay.onLayoutChange?()
        #expect(await waitUntil { model.choice == .display(2) && model.position == .custom })
    }

    @Test func settingKeysMatchTheOverlayStore() {
        #expect(SettingsKey.liveOverlayDisplayChoice == OverlayLayoutStore.displayChoiceKey)
        #expect(SettingsKey.liveOverlayPosition == OverlayLayoutStore.sharedPositionKey)
        #expect(SettingsKey.liveOverlayPosition(display: 9) == OverlayLayoutStore.positionKey(display: 9))
        #expect(SettingsKey.liveClickThrough == CaptionOverlayController.clickThroughKey)
        let preset = CaptionPresetCatalog.presentationID
        #expect(
            SettingsKey.liveOverlayCustomFrame(display: 3, preset: preset.rawValue.uuidString)
                == OverlayLayoutStore.customFrameKey(display: 3, preset: preset))
    }
}

@MainActor private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<300 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
