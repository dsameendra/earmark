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
        contentMinSize = OverlayPlacement.minimumSize
        titleVisibility = .hidden
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Implements `OverlayControlling`: shows the caption panel, remembers its frame per display, and toggles
/// click-through. Appearance is entirely `CaptionOverlayView`; this class owns window behaviour.
@MainActor
public final class CaptionOverlayController: OverlayControlling {
    /// `Bool`; click-through persisted across launches (default `true`).
    public static let clickThroughKey = "liveCaptions.clickThrough"

    public let model: CaptionOverlayModel
    private let settings: any SettingsStore
    private let frames: OverlayFrameStore
    private let displays: any DisplayProviding

    private(set) var panel: CaptionPanel?
    private var observers: [any NSObjectProtocol] = []
    private var modifierMonitors: [Any] = []
    private var persistTask: Task<Void, Never>?
    private var bindingTasks: [Task<Void, Never>] = []
    private var isApplyingFrame = false
    private var modifierOverride = false

    public init(
        settings: any SettingsStore, displays: any DisplayProviding = SystemDisplayProvider(),
        model: CaptionOverlayModel = CaptionOverlayModel()
    ) {
        self.settings = settings
        self.displays = displays
        self.model = model
        frames = OverlayFrameStore(settings: settings)
    }

    public var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: OverlayControlling

    public func show(preset: CaptionPreset) async {
        let preset = CaptionPresetCatalog.sanitized(preset)
        model.preset = preset
        if let saved = await settings.value(for: Self.clickThroughKey, as: Bool.self) { model.clickThrough = saved }
        model.noteSpeechActivity()

        let list = displays.displays()
        let panel = self.panel ?? makePanel()
        self.panel = panel

        if panel.isVisible {
            // Preset change while visible: keep position, adopt the preset's size.
            guard let display = OverlayPlacement.display(containing: panel.frame, in: list) else { return }
            let size = Self.size(for: preset, on: display)
            apply(OverlayPlacement.resized(panel.frame, to: size, within: display.visibleFrame), to: panel)
            schedulePersist()
            return
        }

        let preferred = await frames.lastDisplayID()
        guard let display = OverlayPlacement.resolveDisplay(preferred: preferred, in: list) else { return }
        let rect: CGRect
        if let stored = await frames.frame(for: display.id) {
            rect = OverlayPlacement.restore(stored, on: display)
        } else {
            rect = OverlayPlacement.defaultFrame(size: Self.size(for: preset, on: display), in: display.visibleFrame)
        }
        apply(rect, to: panel)
        panel.ignoresMouseEvents = model.clickThrough
        installObservers(for: panel)
        installModifierMonitors()
        panel.orderFrontRegardless()
    }

    public func hide() async {
        persistTask?.cancel()
        if panel?.isVisible == true { await persistFrame() }
        panel?.orderOut(nil)
        removeObservers()
    }

    public func setClickThrough(_ enabled: Bool) async {
        model.clickThrough = enabled
        if !modifierOverride { panel?.ignoresMouseEvents = enabled }
        await settings.set(enabled, for: Self.clickThroughKey)
    }

    /// Hotkey entry point (`HotkeyAction.toggleOverlayClickThrough`).
    public func toggleClickThrough() async { await setClickThrough(!model.clickThrough) }

    public func setPaused(_ paused: Bool) { model.isPaused = paused }

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

    // MARK: Window plumbing

    private static func size(for preset: CaptionPreset, on display: DisplayInfo) -> CGSize {
        CGSize(
            width: min(preset.maxWidth, display.visibleFrame.width - 2 * OverlayPlacement.edgeMargin),
            height: CaptionStyle.panelHeight(for: preset))
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
    }

    private func installObservers(for panel: CaptionPanel) {
        removeObservers()
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, !self.isApplyingFrame else { return }
                        self.schedulePersist()
                    }
                })
        }
    }

    private func removeObservers() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        for m in modifierMonitors { NSEvent.removeMonitor(m) }
        modifierMonitors = []
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

    /// Snaps to the display edges, keeps the panel on screen and remembers the frame for that display.
    func persistFrame() async {
        guard let panel, let display = OverlayPlacement.display(containing: panel.frame, in: displays.displays()) else { return }
        let target = OverlayPlacement.clamp(
            OverlayPlacement.snap(panel.frame, within: display.visibleFrame), to: display.visibleFrame)
        if target != panel.frame { apply(target, to: panel) }
        await frames.save(OverlayPlacement.store(target, on: display), for: display.id)
    }
}
