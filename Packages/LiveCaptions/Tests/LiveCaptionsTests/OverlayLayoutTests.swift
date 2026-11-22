import AppCore
import AppKit
import Foundation
import Testing

@testable import LiveCaptions

/// Display geometries used across the placement tests (AppKit coordinates, y up).
@MainActor
enum Geometry {
    /// 1440x900 primary with a 25 pt menu bar on top and a 70 pt Dock at the bottom.
    static let primary = DisplayInfo(
        id: 1, frame: CGRect(x: 0, y: 0, width: 1_440, height: 900), visibleFrame: CGRect(x: 0, y: 70, width: 1_440, height: 805),
        isPrimary: true, name: "Built-in Retina Display")
    /// Secondary to the left of the primary: negative x origin, menu bar only (Dock is on the primary).
    static let leftOfPrimary = DisplayInfo(
        id: 2, frame: CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080),
        visibleFrame: CGRect(x: -1_920, y: 0, width: 1_920, height: 1_055), name: "DELL U2723QE")
    /// Secondary above the primary and left of it: negative x, positive y beyond the primary.
    static let aboveLeft = DisplayInfo(
        id: 3, frame: CGRect(x: -2_560, y: 900, width: 2_560, height: 1_440),
        visibleFrame: CGRect(x: -2_560, y: 900, width: 2_560, height: 1_415), name: "Studio Display")
    /// Secondary below-left: negative x and negative y.
    static let belowLeft = DisplayInfo(
        id: 4, frame: CGRect(x: -1_280, y: -800, width: 1_280, height: 800), visibleFrame: CGRect(x: -1_280, y: -800, width: 1_280, height: 775),
        name: "Portable")
    /// Dock on the left edge (visible frame inset on the left).
    static let dockLeft = DisplayInfo(
        id: 5, frame: CGRect(x: 0, y: 0, width: 1_440, height: 900), visibleFrame: CGRect(x: 80, y: 0, width: 1_360, height: 875),
        isPrimary: true, name: "Left Dock")

    static let all = [primary, leftOfPrimary, aboveLeft, belowLeft, dockLeft]
}

@MainActor
final class MutableDisplays: DisplayProviding {
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
@Suite("Overlay position maths (LIVE-AC-21...23)")
struct OverlayPositionMathTests {
    private let size = CGSize(width: 600, height: 120)

    @Test("All nine positions on every geometry: inside the visible frame, with the expected insets")
    func ninePositions() {
        for display in Geometry.all {
            let v = display.visibleFrame
            for position in OverlayPosition.allCases where position != .custom {
                let f = OverlayPlacement.frame(for: position, size: size, in: display)
                #expect(f.size == size)
                #expect(v.contains(f), "\(position) on \(display.name)")
                switch position.horizontal {
                case .left: #expect(f.minX == v.minX + OverlayPlacement.gridInset)
                case .center: #expect(f.midX == v.midX)
                case .right: #expect(f.maxX == v.maxX - OverlayPlacement.gridInset)
                case nil: Issue.record("grid position without a column")
                }
                switch position.vertical {
                case .top: #expect(f.maxY == v.maxY - OverlayPlacement.gridInset)
                case .middle: #expect(f.midY == v.midY)
                case .bottom: #expect(f.minY == v.minY + OverlayPlacement.bottomInset)
                case nil: Issue.record("grid position without a row")
                }
            }
        }
    }

    @Test("Bottom centre is the historic default placement")
    func defaultMatchesHistory() {
        let d = Geometry.primary
        let f = OverlayPlacement.frame(for: .bottomCenter, size: size, in: d)
        #expect(f == OverlayPlacement.defaultFrame(size: size, in: d.visibleFrame))
        #expect(f.minY == 118.0)
    }

    @Test("Negative-origin secondary display: exact corner coordinates")
    func negativeOrigin() {
        let d = Geometry.leftOfPrimary
        #expect(OverlayPlacement.frame(for: .topLeft, size: size, in: d) == CGRect(x: -1_896, y: 1_055 - 24 - 120, width: 600, height: 120))
        #expect(OverlayPlacement.frame(for: .bottomRight, size: size, in: d) == CGRect(x: -24 - 600, y: 48, width: 600, height: 120))
        #expect(OverlayPlacement.frame(for: .middleCenter, size: size, in: d) == CGRect(x: -960 - 300, y: 527.5 - 60, width: 600, height: 120))
        let below = Geometry.belowLeft
        let f = OverlayPlacement.frame(for: .bottomLeft, size: size, in: below)
        #expect(f.origin == CGPoint(x: -1_256, y: -800 + 48))
    }

    @Test("Top positions sit below the menu bar and bottom positions above the Dock")
    func menuBarAndDock() {
        let d = Geometry.primary
        let top = OverlayPlacement.frame(for: .topCenter, size: size, in: d)
        #expect(top.maxY <= d.frame.maxY - 25 - OverlayPlacement.gridInset)
        let bottom = OverlayPlacement.frame(for: .bottomCenter, size: size, in: d)
        #expect(bottom.minY >= 70 + OverlayPlacement.gridInset)
        let left = Geometry.dockLeft
        let f = OverlayPlacement.frame(for: .middleLeft, size: size, in: left)
        #expect(f.minX == 80 + OverlayPlacement.gridInset)
    }

    @Test("A frame that cannot fit is shrunk into the visible frame, never placed off screen")
    func tooBig() {
        let tiny = DisplayInfo(id: 9, frame: CGRect(x: 0, y: 0, width: 300, height: 200), isPrimary: true)
        for p in OverlayPosition.allCases where p != .custom {
            let f = OverlayPlacement.frame(for: p, size: CGSize(width: 900, height: 400), in: tiny)
            #expect(tiny.visibleFrame.contains(f))
        }
    }

    @Test("Side columns wrap in a narrower width and get more height; centre and corners keep proportions")
    func sideSizing() {
        let d = Geometry.primary
        var preset = CaptionPresetCatalog.presentation
        preset.maxWidth = 1_100
        let centre = OverlayPlacement.size(for: preset, position: .bottomCenter, on: d)
        let side = OverlayPlacement.size(for: preset, position: .middleLeft, on: d)
        let sideRight = OverlayPlacement.size(for: preset, position: .middleRight, on: d)
        let corner = OverlayPlacement.size(for: preset, position: .topRight, on: d)
        #expect(centre.width == 1_100)
        #expect(side.width <= OverlayPlacement.sideColumnMaxWidth)
        #expect(side.width >= OverlayPlacement.minimumSize.width)
        #expect(side == sideRight)
        #expect(side.height > centre.height)
        #expect(corner.width == d.visibleFrame.width * OverlayPlacement.cornerWidthShare)
        #expect(corner.height == centre.height)
    }

    @Test("Custom uses the normal width")
    func customSize() {
        let d = Geometry.primary
        let p = CaptionPresetCatalog.subtle
        #expect(OverlayPlacement.size(for: p, position: .custom, on: d).width == min(CGFloat(p.maxWidth), d.visibleFrame.width - 48))
    }

    @Test("Position grid is 3x3 and round-trips through its row and column")
    func grid() {
        #expect(OverlayPosition.gridRows.count == 3)
        #expect(OverlayPosition.gridRows.allSatisfy { $0.count == 3 })
        for v in OverlayVertical.allCases {
            for h in OverlayHorizontal.allCases {
                let p = OverlayPosition(v, h)
                #expect(p.vertical == v && p.horizontal == h)
            }
        }
        #expect(OverlayPosition.custom.vertical == nil)
        #expect(OverlayPosition.allCases.count == 10)
    }
}

@MainActor
@Suite("Display choice and fallback (LIVE-AC-22)")
struct DisplayChoiceTests {
    private let both = [Geometry.primary, Geometry.leftOfPrimary]

    @Test("Raw value round-trips")
    func raw() {
        for c in [DisplayChoice.main, .followActive, .display(2), .display(4_294_967_295)] {
            #expect(DisplayChoice(rawValue: c.rawValue) == c)
        }
        #expect(DisplayChoice(rawValue: "display:x") == nil)
        #expect(DisplayChoice(rawValue: "nonsense") == nil)
    }

    @Test("Main resolves to the primary display, follow to the active one, specific to itself")
    func resolve() {
        #expect(OverlayPlacement.resolveTarget(.main, in: both, activeDisplayID: 2)?.id == 1)
        #expect(OverlayPlacement.resolveTarget(.followActive, in: both, activeDisplayID: 2)?.id == 2)
        #expect(OverlayPlacement.resolveTarget(.display(2), in: both, activeDisplayID: 1)?.id == 2)
    }

    @Test("Unplugged display falls back to the main display; follow without an active display does too")
    func fallbacks() {
        let only = [Geometry.primary]
        #expect(OverlayPlacement.resolveTarget(.display(2), in: only, activeDisplayID: nil)?.id == 1)
        #expect(OverlayPlacement.resolveTarget(.followActive, in: only, activeDisplayID: 2)?.id == 1)
        #expect(OverlayPlacement.resolveTarget(.followActive, in: both, activeDisplayID: nil)?.id == 1)
        #expect(OverlayPlacement.resolveTarget(.main, in: [], activeDisplayID: nil) == nil)
        // No display flagged primary: the first one stands in.
        let noPrimary = [Geometry.leftOfPrimary]
        #expect(OverlayPlacement.resolveTarget(.display(77), in: noPrimary, activeDisplayID: nil)?.id == 2)
    }

    @Test("Names are unique and tag the main display")
    func naming() {
        let twins = [
            DisplayInfo(id: 1, frame: .zero, isPrimary: true, name: "LG"), DisplayInfo(id: 2, frame: .zero, name: "LG"),
            DisplayInfo(id: 3, frame: .zero, name: "Dell"),
        ]
        let names = DisplayNaming.names(for: twins)
        #expect(names[1] == "LG (1) - Main")
        #expect(names[2] == "LG (2)")
        #expect(names[3] == "Dell")
    }

    @Test("Core Graphics global rects convert to AppKit coordinates")
    func coordinateConversion() {
        let r = OverlayPlacement.appKitRect(fromGlobalDisplayRect: CGRect(x: -1_920, y: 100, width: 800, height: 600), primaryHeight: 900)
        #expect(r == CGRect(x: -1_920, y: 200, width: 800, height: 600))
        #expect(OverlayPlacement.displayID(containing: CGPoint(x: -500, y: 500), in: both) == 2)
        #expect(OverlayPlacement.displayID(containing: CGPoint(x: 5_000, y: 5_000), in: both) == nil)
    }
}

@Suite("OverlayLayoutStore persistence")
struct OverlayLayoutStoreTests {
    @Test("Display choice and per-display positions persist independently")
    func choiceAndPosition() async {
        let store = OverlayLayoutStore(settings: InMemorySettings())
        #expect(await store.displayChoice() == .main)
        #expect(await store.storedPosition(for: .main) == nil)
        await store.setDisplayChoice(.display(2))
        #expect(await store.displayChoice() == .display(2))
        await store.setPosition(.topRight, for: .display(2))
        await store.setPosition(.middleLeft, for: .display(3))
        await store.setPosition(.bottomLeft, for: .main)
        #expect(await store.storedPosition(for: .display(2)) == .topRight)
        #expect(await store.storedPosition(for: .display(3)) == .middleLeft)
        #expect(await store.storedPosition(for: .main) == .bottomLeft)
        #expect(await store.storedPosition(for: .followActive) == .bottomLeft)  // shared scope
    }

    @Test("Custom frames are per display and per preset; clearing reads back as nil")
    func customFrames() async {
        let store = OverlayLayoutStore(settings: InMemorySettings())
        let a = StoredOverlayFrame(x: 10, y: 20, width: 400, height: 90)
        let b = StoredOverlayFrame(x: 50, y: 60, width: 500, height: 100)
        await store.setCustomFrame(a, display: 1, preset: CaptionPresetCatalog.subtleID)
        await store.setCustomFrame(b, display: 1, preset: CaptionPresetCatalog.presentationID)
        await store.setCustomFrame(b, display: 2, preset: CaptionPresetCatalog.subtleID)
        #expect(await store.customFrame(display: 1, preset: CaptionPresetCatalog.subtleID) == a)
        #expect(await store.customFrame(display: 1, preset: CaptionPresetCatalog.presentationID) == b)
        #expect(await store.customFrame(display: 2, preset: CaptionPresetCatalog.subtleID) == b)
        #expect(await store.customFrame(display: 2, preset: CaptionPresetCatalog.presentationID) == nil)
        await store.clearCustomFrame(display: 1, preset: CaptionPresetCatalog.subtleID)
        #expect(await store.customFrame(display: 1, preset: CaptionPresetCatalog.subtleID) == nil)
    }

    @Test("Setting keys follow the documented names")
    func keys() {
        #expect(OverlayLayoutStore.displayChoiceKey == "liveCaptions.overlayDisplayChoice")
        #expect(OverlayLayoutStore.sharedPositionKey == "liveCaptions.overlayPosition")
        #expect(OverlayLayoutStore.positionKey(display: 7) == "liveCaptions.overlayPosition.7")
    }
}

@MainActor
@Suite("Overlay controller placement")
struct OverlayControllerPlacementTests {
    @Test("Chosen display and grid position decide the panel frame, including a negative-origin display")
    func placesOnChosenDisplay() async {
        let settings = InMemorySettings()
        let layout = OverlayLayoutStore(settings: settings)
        await layout.setDisplayChoice(.display(2))
        await layout.setPosition(.topRight, for: .display(2))
        let provider = MutableDisplays([Geometry.primary, Geometry.leftOfPrimary])
        let controller = CaptionOverlayController(settings: settings, displays: provider)
        await controller.show(preset: CaptionPresetCatalog.subtle)
        let size = OverlayPlacement.size(for: CaptionPresetCatalog.subtle, position: .topRight, on: Geometry.leftOfPrimary)
        let expected = OverlayPlacement.frame(for: .topRight, size: size, in: Geometry.leftOfPrimary)
        #expect(controller.panel?.frame == expected)
        #expect(expected.maxX == -24.0)
        await controller.hide()
    }

    @Test("Hiding after a controller-placed grid position never turns it into Custom")
    func gridStaysGrid() async {
        let settings = InMemorySettings()
        let layout = OverlayLayoutStore(settings: settings)
        await layout.setPosition(.middleRight, for: .main)
        let controller = CaptionOverlayController(settings: settings, displays: MutableDisplays([Geometry.primary]))
        await controller.show(preset: CaptionPresetCatalog.subtle)
        await controller.hide()
        #expect(await layout.storedPosition(for: .main) == .middleRight)
        #expect(await layout.customFrame(display: 1, preset: CaptionPresetCatalog.subtleID) == nil)
    }

    @Test("Unplugging the chosen display moves the overlay to the main display and keeps the choice for replug")
    func unplugFallsBack() async {
        let settings = InMemorySettings()
        let layout = OverlayLayoutStore(settings: settings)
        await layout.setDisplayChoice(.display(2))
        await layout.setPosition(.bottomLeft, for: .display(2))
        let provider = MutableDisplays([Geometry.primary, Geometry.leftOfPrimary])
        let controller = CaptionOverlayController(settings: settings, displays: provider)
        await controller.show(preset: CaptionPresetCatalog.subtle)
        #expect(Geometry.leftOfPrimary.frame.intersects(controller.panel?.frame ?? .zero))

        provider.list = [Geometry.primary]
        controller.displaysChanged()
        let moved = await waitUntilMain { controller.panel.map { Geometry.primary.frame.contains($0.frame) } == true }
        #expect(moved)
        #expect(await layout.displayChoice() == .display(2))  // not overwritten by the fallback
        #expect(await layout.customFrame(display: 1, preset: CaptionPresetCatalog.subtleID) == nil)

        provider.list = [Geometry.primary, Geometry.leftOfPrimary]
        controller.displaysChanged()
        let back = await waitUntilMain { controller.panel.map { Geometry.leftOfPrimary.frame.contains($0.frame) } == true }
        #expect(back)
        await controller.hide()
    }

    @Test("Dragging saves Custom for that display and preset, and changing preset restores that preset's own frame")
    func dragIsCustomPerPreset() async {
        let settings = InMemorySettings()
        let layout = OverlayLayoutStore(settings: settings)
        let controller = CaptionOverlayController(settings: settings, displays: MutableDisplays([Geometry.primary]))
        await controller.show(preset: CaptionPresetCatalog.subtle)
        controller.panel?.setFrame(CGRect(x: 300, y: 300, width: 500, height: 100), display: false)
        await controller.persistFrame()
        #expect(await layout.storedPosition(for: .main) == .custom)
        let saved = await layout.customFrame(display: 1, preset: CaptionPresetCatalog.subtleID)
        #expect(saved == StoredOverlayFrame(x: 300, y: 300, width: 500, height: 100))

        // Another preset has no custom frame of its own yet: it starts from the last remembered frame.
        await controller.show(preset: CaptionPresetCatalog.presentation)
        let other = controller.panel?.frame
        #expect(other?.midX == 550 && other?.minY == 300)
        controller.panel?.setFrame(CGRect(x: 100, y: 200, width: 600, height: 140), display: false)
        await controller.persistFrame()

        await controller.show(preset: CaptionPresetCatalog.subtle)
        #expect(controller.panel?.frame == CGRect(x: 300, y: 300, width: 500, height: 100))
        await controller.show(preset: CaptionPresetCatalog.presentation)
        #expect(controller.panel?.frame == CGRect(x: 100, y: 200, width: 600, height: 140))
        await controller.hide()
    }

    @Test("Dragging onto another display makes it the chosen display")
    func dragAcrossDisplays() async {
        let settings = InMemorySettings()
        let layout = OverlayLayoutStore(settings: settings)
        let provider = MutableDisplays([Geometry.primary, Geometry.leftOfPrimary])
        let controller = CaptionOverlayController(settings: settings, displays: provider)
        await controller.show(preset: CaptionPresetCatalog.subtle)
        controller.panel?.setFrame(CGRect(x: -1_000, y: 400, width: 500, height: 100), display: false)
        await controller.persistFrame()
        #expect(await layout.displayChoice() == .display(2))
        #expect(await layout.storedPosition(for: .display(2)) == .custom)
        #expect(await layout.customFrame(display: 2, preset: CaptionPresetCatalog.subtleID)?.x == 920)
        await controller.hide()
    }

    @Test("An existing per-display frame from before this setting is honoured as Custom")
    func legacyFrame() async {
        let settings = InMemorySettings()
        await OverlayFrameStore(settings: settings).save(StoredOverlayFrame(x: 120, y: 130, width: 500, height: 100), for: 1)
        let controller = CaptionOverlayController(settings: settings, displays: MutableDisplays([Geometry.primary]))
        await controller.show(preset: CaptionPresetCatalog.subtle)
        #expect(controller.panel?.frame == CGRect(x: 120, y: 130, width: 500, height: 100))
        await controller.hide()
    }

    @Test("Changing the position while visible moves the overlay immediately")
    func liveChange() async {
        let settings = InMemorySettings()
        let layout = OverlayLayoutStore(settings: settings)
        let controller = CaptionOverlayController(settings: settings, displays: MutableDisplays([Geometry.primary]))
        await controller.show(preset: CaptionPresetCatalog.subtle)
        let before = controller.panel?.frame
        await layout.setPosition(.topLeft, for: .main)
        await controller.placementDidChange(previewing: nil)
        let after = controller.panel?.frame
        #expect(before != after)
        #expect(after?.minX == 24)
        await controller.hide()
    }

    @Test("Test caption shows without a session, moves with changes, and hides again")
    func testCaption() async {
        let settings = InMemorySettings()
        let layout = OverlayLayoutStore(settings: settings)
        let controller = CaptionOverlayController(settings: settings, displays: MutableDisplays([Geometry.primary]))
        #expect(controller.isVisible == false)
        await controller.placementDidChange(previewing: CaptionPresetCatalog.subtle)  // starts the preview
        #expect(controller.isVisible && controller.isTestCaptionActive)
        #expect(controller.model.lines.count == 2)
        #expect(controller.model.isCaptioning == false)  // no recording dot for a preview

        await layout.setPosition(.middleLeft, for: .main)
        await controller.placementDidChange(previewing: CaptionPresetCatalog.subtle)
        #expect(controller.panel?.frame.minX == 24)
        #expect(controller.panel.map { abs($0.frame.midY - 472.5) < 1 } == true)

        await controller.hideTestCaption()
        #expect(controller.isVisible == false && controller.isTestCaptionActive == false)
        #expect(controller.model.lines.isEmpty)
    }

    @Test("A live session takes over from the test caption and a test never hides a live overlay")
    func testCaptionVersusLive() async {
        let controller = CaptionOverlayController(settings: InMemorySettings(), displays: MutableDisplays([Geometry.primary]))
        await controller.showTestCaption(preset: CaptionPresetCatalog.subtle)
        controller.model.isCaptioning = true
        await controller.show(preset: CaptionPresetCatalog.subtle)
        #expect(controller.isTestCaptionActive == false)
        #expect(controller.model.lines.isEmpty)
        await controller.hideTestCaption()
        #expect(controller.isVisible)
        await controller.showTestCaption(preset: CaptionPresetCatalog.subtle)  // live: moves only, keeps real lines
        #expect(controller.isTestCaptionActive == false)
        await controller.hide()
    }

    @Test("The drag handle shows while click-through is off or Option is held")
    func dragHandle() async {
        let controller = CaptionOverlayController(settings: InMemorySettings(), displays: MutableDisplays([Geometry.primary]))
        await controller.show(preset: CaptionPresetCatalog.subtle)
        #expect(controller.model.isDragHandleVisible == false)
        controller.setModifierOverride(true)
        #expect(controller.model.isDragHandleVisible)
        controller.setModifierOverride(false)
        #expect(controller.model.isDragHandleVisible == false)
        await controller.setClickThrough(false)
        #expect(controller.model.isDragHandleVisible)
        await controller.hide()
    }
}
