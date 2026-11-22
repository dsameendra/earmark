import AppKit
import ApplicationServices
import SwiftUI

/// Non-activating, click-through panel: never takes focus from the app being dictated into (DICT-AC-03).
final class DictationHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(content: NSView, size: CGSize) {
        super.init(
            contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
            defer: true)
        isFloatingPanel = true
        level = .statusBar
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        animationBehavior = .none  // no animated transitions (Reduce Motion)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = content
    }
}

/// Finds the text caret of the focused element via Accessibility, in AppKit screen coordinates.
public protocol CaretLocating: Sendable {
    func caretRect() -> CGRect?
}

public struct SystemCaretLocator: CaretLocating {
    public init() {}
    public func caretRect() -> CGRect? {
        guard AXIsProcessTrusted(), let element = AXFocus.focusedElement() else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.2)
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
            let rangeValue
        else { return nil }
        var bounds: CFTypeRef?
        guard
            AXUIElementCopyParameterizedAttributeValue(
                element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &bounds) == .success,
            let bounds, CFGetTypeID(bounds) == AXValueGetTypeID()
        else { return nil }
        var rect = CGRect.zero
        // Safe: type ID checked above.
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect), rect != .zero else { return nil }  // swiftlint:disable:this force_cast
        // AX uses a top-left origin on the primary screen; convert to AppKit's bottom-left.
        guard let primary = NSScreen.screens.first else { return nil }
        rect.origin.y = primary.frame.height - rect.origin.y - rect.height
        return rect
    }
}

/// AppKit presenter for the dictation HUD. Owns one reusable panel.
@MainActor
public final class DictationHUDController: DictationHUDPresenting {
    public let model = DictationHUDModel()
    private var panel: DictationHUDPanel?
    private var position = DictationHUDPosition.nearCursor
    private var hideTask: Task<Void, Never>?
    private let caretLocator: any CaretLocating
    private let errorDuration: Duration

    public init(caretLocator: any CaretLocating = SystemCaretLocator(), errorDuration: Duration = .seconds(2.5)) {
        self.caretLocator = caretLocator
        self.errorDuration = errorDuration
    }

    public func show(_ info: DictationHUDInfo) async {
        hideTask?.cancel()
        model.begin(info)
        position = info.position
        let panel = ensurePanel()
        panel.setFrame(placement(for: info.position), display: true)
        panel.orderFrontRegardless()
    }

    public func update(partial: String) async { model.partialText = partial }
    public func update(level: Float) async { model.push(level: level) }
    public func showProcessing() async { model.phase = .processing }
    public func showExperimentalBadge() async { model.isExperimental = true }

    public func dismiss() async {
        hideTask?.cancel()
        panel?.orderOut(nil)
    }

    public func dismissWithError(_ message: String) async {
        model.phase = .error(message)
        if let panel { panel.setFrame(placement(for: position), display: true) }
        panel?.orderFrontRegardless()
        hideTask?.cancel()
        let duration = errorDuration
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
        }
    }

    private func ensurePanel() -> DictationHUDPanel {
        if let panel { return panel }
        let host = NSHostingView(rootView: DictationHUDView(model: model))
        let p = DictationHUDPanel(content: host, size: DictationHUDView.size)
        panel = p
        return p
    }

    private func placement(for position: DictationHUDPosition) -> CGRect {
        let caret = position == .nearCursor ? caretLocator.caretRect() : nil
        let screen =
            caret.flatMap { c in NSScreen.screens.first { $0.frame.intersects(c) } } ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return DictationHUDPlacement.frame(size: DictationHUDView.size, position: position, caret: caret, visibleFrame: visible)
    }
}
