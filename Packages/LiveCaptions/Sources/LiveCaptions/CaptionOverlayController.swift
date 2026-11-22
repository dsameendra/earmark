import AppCore
import AppKit
import SwiftUI

/// Non-activating, floating caption panel (LIVE-AC-01, LIVE-AC-20). It never becomes key or main, so it cannot take
/// focus from the frontmost app, and it joins every Space and sits above fullscreen apps.
final class CaptionPanel: NSPanel {
    init(contentRect: CGRect) {
        super.init(
            contentRect: contentRect, styleMask: [.nonactivatingPanel, .borderless, .resizable], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = true
        animationBehavior = .none
        isReleasedWhenClosed = false
        // Captions are dark-styled so appearance tokens resolve to dark and light text stays legible.
        appearance = NSAppearance(named: .darkAqua)
        contentMinSize = OverlayPlacement.minimumSize
        titleVisibility = .hidden
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Implements `OverlayControlling`: shows the caption panel on the chosen display at the chosen position (a 3x3 grid
/// cell or a dragged custom frame), remembers frames per display and preset, and toggles click-through. Appearance is
/// entirely `CaptionOverlayView`; this class owns window behaviour.
@MainActor
public final class CaptionOverlayController: OverlayControlling, OverlayPlacementControlling {
    /// `Bool`; click-through persisted across launches (default `true`).
    public static let clickThroughKey = "liveCaptions.clickThrough"
    /// How long the Settings test caption stays up after the last change.
    public static let testCaptionDuration: Duration = .seconds(8)

    public let model: CaptionOverlayModel
    private let settings: any SettingsStore
    private let frames: OverlayFrameStore
    private let layout: OverlayLayoutStore
    private let displays: any DisplayProviding

    private(set) var panel: CaptionPanel?
    private var observers: [any NSObjectProtocol] = []
    private var modifierMonitors: [Any] = []
    private var persistTask: Task<Void, Never>?
    private var replaceTask: Task<Void, Never>?
    private var followTask: Task<Void, Never>?
    private var testTask: Task<Void, Never>?
    private var bindingTasks: [Task<Void, Never>] = []
    private var isApplyingFrame = false
    private var modifierOverride = false
    /// The last frame this controller set; a different `panel.frame` means the user moved or resized it.
    private var lastApplied: CGRect = .zero
    private var targetDisplayID: UInt32?
    private var cachedChoice: DisplayChoice = .main
    private var suppressPersistUntil: ContinuousClock.Instant = .now

    public private(set) var isTestCaptionActive = false
    public var onLayoutChange: (@MainActor () -> Void)?

    public init(
        settings: any SettingsStore, displays: any DisplayProviding = SystemDisplayProvider(),
        model: CaptionOverlayModel = CaptionOverlayModel()
    ) {
        self.settings = settings
        self.displays = displays
        self.model = model
        frames = OverlayFrameStore(settings: settings)
        layout = OverlayLayoutStore(settings: settings)
    }

    public var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: OverlayControlling

    public func show(preset: CaptionPreset) async {
        if isTestCaptionActive {
            // A live session takes over from the Settings test caption.
            cancelTestCaption()
            model.reset()
        }
        await present(preset: preset)
    }

    private func present(preset: CaptionPreset) async {
        let preset = CaptionPresetCatalog.sanitized(preset)
        model.preset = preset
        if let saved = await settings.value(for: Self.clickThroughKey, as: Bool.self) { model.clickThrough = saved }
        model.noteSpeechActivity()

        let panel = self.panel ?? makePanel()
        self.panel = panel
        let wasVisible = panel.isVisible
        await place(preset: preset)
        guard !wasVisible else { return }
        panel.ignoresMouseEvents = model.clickThrough
        installObservers(for: panel)
        installModifierMonitors()
        startFollowing()
        panel.orderFrontRegardless()
    }

    public func hide() async {
        persistTask?.cancel()
        replaceTask?.cancel()
        cancelTestCaption()
        if panel?.isVisible == true { await persistFrame() }
        panel?.orderOut(nil)
        removeObservers()
        stopFollowing()
        model.optionHeld = false
    }

    public func setClickThrough(_ enabled: Bool) async {
        model.clickThrough = enabled
        if !modifierOverride { panel?.ignoresMouseEvents = enabled }
        await settings.set(enabled, for: Self.clickThroughKey)
    }

    /// Hotkey entry point (`HotkeyAction.toggleOverlayClickThrough`).
    public func toggleClickThrough() async { await setClickThrough(!model.clickThrough) }

    public func setPaused(_ paused: Bool) { model.isPaused = paused }

    // MARK: OverlayPlacementControlling

    public func placementDidChange(previewing preset: CaptionPreset?) async {
        if isVisible {
            await place(preset: model.preset)
            if isTestCaptionActive { armTestCaptionTimer() }
        } else if let preset {
            await showTestCaption(preset: preset)
        }
    }

    public func showTestCaption(preset: CaptionPreset) async {
        // With a live session running the real overlay is the preview.
        if model.isCaptioning {
            await place(preset: model.preset)
            return
        }
        isTestCaptionActive = true
        model.ingest([
            CaptionLine(text: "This is how live captions will look.", isVolatile: false),
            CaptionLine(text: "Choose a display and position in Settings.", isVolatile: true),
        ])
        await present(preset: preset)
        armTestCaptionTimer()
    }

    public func hideTestCaption() async {
        guard isTestCaptionActive else { return }
        cancelTestCaption()
        guard !model.isCaptioning else { return }
        await hide()
        model.reset()
    }

    private func armTestCaptionTimer() {
        testTask?.cancel()
        testTask = Task { [weak self] in
            try? await Task.sleep(for: Self.testCaptionDuration)
            guard !Task.isCancelled else { return }
            await self?.hideTestCaption()
        }
    }

    private func cancelTestCaption() {
        testTask?.cancel()
        testTask = nil
        isTestCaptionActive = false
    }

    // MARK: Session binding

    /// Mirrors a live session: lines feed the overlay, `.running` shows it, `.idle`/`.failed` hide it.
    public func bind(to session: any LiveSessionControlling) {
        unbind()
        let lines = session.lines()
        let states = session.state()
        bindingTasks.append(
            Task { [weak self] in
                for await l in lines { self?.model.ingest(l) }
            })
        bindingTasks.append(
            Task { [weak self] in
                for await s in states {
                    guard let self else { return }
                    switch s {
                    case .running:
                        model.isCaptioning = true
                        await show(preset: model.preset)
                    case .idle, .failed:
                        model.isCaptioning = false
                        await hide()
                    case .starting, .stopping:
                        break
                    }
                }
            })
    }

    public func unbind() {
        for t in bindingTasks { t.cancel() }
        bindingTasks = []
    }

    // MARK: Placement

    /// Where the overlay should be right now: the target display, and the frame for the saved position.
    func resolvePlacement(preset: CaptionPreset) async -> (display: DisplayInfo, rect: CGRect)? {
        let list = displays.displays()
        let choice = await layout.displayChoice()
        cachedChoice = choice
        guard let display = OverlayPlacement.resolveTarget(choice, in: list, activeDisplayID: displays.activeDisplayID()) else {
            return nil
        }
        let legacy = await frames.frame(for: display.id)
        let position = await layout.storedPosition(for: choice) ?? (legacy != nil ? .custom : .default)
        let rect: CGRect
        if position == .custom {
            if let stored = await layout.customFrame(display: display.id, preset: preset.id) ?? legacy {
                rect = OverlayPlacement.restore(stored, on: display)
            } else if let panel, panel.isVisible, OverlayPlacement.display(containing: panel.frame, in: list)?.id == display.id {
                let size = OverlayPlacement.size(for: preset, position: .custom, on: display)
                rect = OverlayPlacement.resized(panel.frame, to: size, within: display.visibleFrame)
            } else {
                rect = OverlayPlacement.frame(
                    for: .default, size: OverlayPlacement.size(for: preset, position: .default, on: display), in: display)
            }
        } else {
            rect = OverlayPlacement.frame(
                for: position, size: OverlayPlacement.size(for: preset, position: position, on: display), in: display)
        }
        return (display, rect)
    }

    private func place(preset: CaptionPreset) async {
        guard let panel, let placement = await resolvePlacement(preset: preset) else { return }
        targetDisplayID = placement.display.id
        if placement.rect != panel.frame { apply(placement.rect, to: panel) } else { lastApplied = placement.rect }
    }

    private func makePanel() -> CaptionPanel {
        let panel = CaptionPanel(contentRect: CGRect(x: 0, y: 0, width: 600, height: 120))
        let host = NSHostingView(rootView: CaptionOverlayView(model: model))
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }

    private func apply(_ rect: CGRect, to panel: CaptionPanel) {
        isApplyingFrame = true
        panel.setFrame(rect, display: true)
        isApplyingFrame = false
        lastApplied = rect
    }

    // MARK: Observers

    private func installObservers(for panel: CaptionPanel) {
        removeObservers()
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, !self.isApplyingFrame else { return }
                        if ContinuousClock.now < self.suppressPersistUntil {
                            self.scheduleReplace()  // AppKit moved it because a display changed: re-assert, never save
                        } else {
                            self.schedulePersist()
                        }
                    }
                })
        }
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.displaysChanged() }
            })
    }

    private func removeObservers() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        for m in modifierMonitors { NSEvent.removeMonitor(m) }
        modifierMonitors = []
    }

    /// A display was plugged, unplugged or rearranged: put the overlay back where the saved layout says (main display
    /// when the chosen one is gone) and do not mistake AppKit's own repositioning for a user drag.
    func displaysChanged() {
        guard isVisible else { return }
        suppressPersistUntil = .now + .seconds(1)
        persistTask?.cancel()
        scheduleReplace()
    }

    private func scheduleReplace() {
        replaceTask?.cancel()
        replaceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, let self else { return }
            await place(preset: model.preset)
        }
    }

    /// "Follow the active window": re-places the overlay when the active display changes.
    private func startFollowing() {
        guard followTask == nil else { return }
        followTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                guard cachedChoice == .followActive, let panel, panel.isVisible, panel.frame == lastApplied else { continue }
                let next = OverlayPlacement.resolveTarget(
                    .followActive, in: displays.displays(), activeDisplayID: displays.activeDisplayID())
                if let next, next.id != targetDisplayID { await place(preset: model.preset) }
            }
        }
    }

    private func stopFollowing() {
        followTask?.cancel()
        followTask = nil
    }

    /// Holding Option temporarily makes a click-through overlay interactive so it can be dragged (LIVE-AC-02).
    private func installModifierMonitors() {
        guard modifierMonitors.isEmpty else { return }
        let handler: @Sendable (NSEvent) -> Void = { [weak self] event in
            let optionDown = event.modifierFlags.contains(.option)
            Task { @MainActor in self?.setModifierOverride(optionDown) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler) {
            modifierMonitors.append(global)
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handler(event)
            return event
        }
        if let local { modifierMonitors.append(local) }
    }

    func setModifierOverride(_ active: Bool) {
        guard model.clickThrough else { return }
        modifierOverride = active
        model.optionHeld = active
        panel?.ignoresMouseEvents = !active
    }

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.persistFrame()
        }
    }

    /// When the user moved or resized the overlay: snaps to the display edges, keeps it on screen and remembers it as
    /// the Custom position for that display and preset. Frames set by the controller itself are never saved.
    func persistFrame() async {
        guard let panel, panel.frame != lastApplied, ContinuousClock.now >= suppressPersistUntil else { return }
        let list = displays.displays()
        guard let display = OverlayPlacement.display(containing: panel.frame, in: list) else { return }
        let target = OverlayPlacement.clamp(
            OverlayPlacement.snap(panel.frame, within: display.visibleFrame), to: display.visibleFrame)
        if target != panel.frame { apply(target, to: panel) } else { lastApplied = target }

        var choice = await layout.displayChoice()
        let resolved = OverlayPlacement.resolveTarget(choice, in: list, activeDisplayID: displays.activeDisplayID())
        if resolved?.id != display.id {
            // Dragged onto another display: that display becomes the chosen one.
            choice = .display(display.id)
            await layout.setDisplayChoice(choice)
        }
        cachedChoice = choice
        targetDisplayID = display.id
        let stored = OverlayPlacement.store(target, on: display)
        await layout.setPosition(.custom, for: choice)
        await layout.setCustomFrame(stored, display: display.id, preset: model.preset.id)
        await frames.save(stored, for: display.id)
        onLayoutChange?()
    }
}
