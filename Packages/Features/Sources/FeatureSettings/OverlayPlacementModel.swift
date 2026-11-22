import AppCore
import FeatureSupport
import Foundation
import LiveCaptions
import Observation

/// Settings > Live Captions > Display and Position: which display the caption overlay appears on, and where on it.
/// Every change is saved at once and moves the live overlay (or a test caption) straight away (LIVE-AC-21...25).
@MainActor @Observable
public final class OverlayPlacementSettingsModel {
    public struct DisplayOption: Identifiable, Hashable, Sendable {
        public var id: DisplayChoice
        public var title: String
    }

    public private(set) var choice: DisplayChoice = .main
    public private(set) var position: OverlayPosition = .default
    /// `true` when the user may drag the overlay without Option (click-through off).
    public private(set) var allowsDragging = false
    public private(set) var displays: [DisplayInfo] = []

    @ObservationIgnored private let store: any SettingsStore
    @ObservationIgnored private let layout: OverlayLayoutStore
    @ObservationIgnored private let provider: any DisplayProviding
    @ObservationIgnored private let controller: (any OverlayPlacementControlling)?
    @ObservationIgnored private let previewPreset: @MainActor () -> CaptionPreset
    @ObservationIgnored private let knownPresetIDs: @MainActor () -> [PresetID]

    public init(
        store: any SettingsStore, displays: any DisplayProviding, controller: (any OverlayPlacementControlling)?,
        previewPreset: @escaping @MainActor () -> CaptionPreset = { CaptionPresetCatalog.defaultPreset },
        knownPresetIDs: @escaping @MainActor () -> [PresetID] = { [] }
    ) {
        self.store = store
        layout = OverlayLayoutStore(settings: store)
        provider = displays
        self.controller = controller
        self.previewPreset = previewPreset
        self.knownPresetIDs = knownPresetIDs
    }

    // MARK: Loading

    public func load() async {
        refreshDisplays()
        await reload()
        controller?.onLayoutChange = { [weak self] in
            guard let self else { return }
            Task { await self.reload() }
        }
    }

    /// Re-reads the saved layout (also after the overlay was dragged, which saves Custom and may change the display).
    public func reload() async {
        choice = await layout.displayChoice()
        position = await layout.storedPosition(for: choice) ?? .default
        allowsDragging = !(await store.value(for: CaptionOverlayController.clickThroughKey, as: Bool.self) ?? true)
        refreshDisplays()
    }

    /// Call when displays are plugged or unplugged.
    public func refreshDisplays() { displays = provider.displays() }

    // MARK: Display choice

    /// "Main display", "Follow the active window", then every connected display by name. A saved display that is no
    /// longer attached is listed too, so the picker still shows the saved choice (the overlay uses the main display).
    public var choiceOptions: [DisplayOption] {
        var options = [
            DisplayOption(id: .main, title: "Main display"),
            DisplayOption(id: .followActive, title: "Follow the active window or mouse"),
        ]
        let names = DisplayNaming.names(for: displays)
        for d in displays { options.append(DisplayOption(id: .display(d.id), title: names[d.id] ?? d.name)) }
        if case .display(let id) = choice, !displays.contains(where: { $0.id == id }) {
            options.append(DisplayOption(id: choice, title: "Disconnected display (using the main display)"))
        }
        return options
    }

    /// The display captions will be on right now.
    public var effectiveDisplay: DisplayInfo? {
        OverlayPlacement.resolveTarget(choice, in: displays, activeDisplayID: provider.activeDisplayID())
    }

    public var isChosenDisplayMissing: Bool {
        if case .display(let id) = choice { return !displays.contains { $0.id == id } }
        return false
    }

    public func selectChoice(_ newChoice: DisplayChoice) async {
        choice = newChoice
        await layout.setDisplayChoice(newChoice)
        position = await layout.storedPosition(for: newChoice) ?? .default
        await changed()
    }

    // MARK: Position

    public func selectPosition(_ newPosition: OverlayPosition) async {
        position = newPosition
        await layout.setPosition(newPosition, for: choice)
        await changed()
    }

    /// Back to the default (bottom centre) and forgets every dragged frame on the display captions are on now.
    public func resetPosition() async {
        position = .default
        await layout.setPosition(.default, for: choice)
        if let display = effectiveDisplay {
            let ids = Set(knownPresetIDs() + CaptionPresetCatalog.builtIns.map(\.id) + [previewPreset().id])
            for id in ids { await layout.clearCustomFrame(display: display.id, preset: id) }
            await OverlayFrameStore(settings: store).clearFrame(for: display.id)
        }
        await changed()
    }

    // MARK: Dragging and preview

    /// Off means click-through (the overlay ignores the mouse unless Option is held).
    public func setAllowsDragging(_ allowed: Bool) async {
        allowsDragging = allowed
        if let controller {
            await controller.setClickThrough(!allowed)
        } else {
            await store.set(!allowed, for: CaptionOverlayController.clickThroughKey)
        }
    }

    public func showTestCaption() async { await controller?.showTestCaption(preset: previewPreset()) }
    public func hideTestCaption() async { await controller?.hideTestCaption() }
    public var canPreview: Bool { controller != nil }

    private func changed() async { await controller?.placementDidChange(previewing: previewPreset()) }
}
