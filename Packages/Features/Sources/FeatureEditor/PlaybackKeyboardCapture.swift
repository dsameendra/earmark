import AppKit
import SwiftUI

/// Window-scoped transport shortcuts. Native text entry and controls keep ownership of their keyboard interaction.
@MainActor enum PlaybackKeyboardFocus {
    static func permitsPlayback(firstResponder: NSResponder?) -> Bool {
        if let text = firstResponder as? NSTextView, text.isEditable { return false }
        if firstResponder is NSPopUpButton { return false }
        if firstResponder is NSControl, !(firstResponder is NSSlider), !(firstResponder is NSButton) { return false }
        return true
    }
}

extension PlaybackShortcut {
    static func resolve(event: NSEvent) -> PlaybackShortcut? {
        var modifiers = EventModifiers()
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        let key: KeyEquivalent
        switch event.keyCode {
        case 49: key = .space
        case 123: key = .leftArrow
        case 124: key = .rightArrow
        default:
            guard let character = event.charactersIgnoringModifiers?.lowercased().first else { return nil }
            key = KeyEquivalent(character)
        }
        return resolve(key: key, modifiers: modifiers)
    }
}

/// The same handler is attached to the Editor and detached media window; it does not depend on transcript-list focus.
struct PlaybackKeyboardCapture: NSViewRepresentable {
    let playback: PlaybackModel
    var isEnabled: () -> Bool = { true }

    func makeNSView(context: Context) -> KeyboardCaptureView {
        KeyboardCaptureView(playback: playback, isEnabled: isEnabled)
    }

    func updateNSView(_ view: KeyboardCaptureView, context: Context) {
        view.playback = playback
        view.isEnabled = isEnabled
    }

    static func dismantleNSView(_ view: KeyboardCaptureView, coordinator: ()) { view.stopMonitoring() }

    @MainActor final class KeyboardCaptureView: NSView {
        var playback: PlaybackModel
        var isEnabled: () -> Bool
        private var monitor: Any?

        init(playback: PlaybackModel, isEnabled: @escaping () -> Bool) {
            self.playback = playback
            self.isEnabled = isEnabled
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.consume(event) ?? false }
                return consumed ? nil : event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func consume(_ event: NSEvent) -> Bool {
            guard isEnabled(), playback.canPlay, let window, window.isKeyWindow,
                event.window === window, window.attachedSheet == nil, NSApplication.shared.modalWindow == nil,
                PlaybackKeyboardFocus.permitsPlayback(firstResponder: window.firstResponder),
                let shortcut = PlaybackShortcut.resolve(event: event)
            else { return false }
            if event.isARepeat && shortcut == .togglePlay { return true }
            playback.perform(shortcut)
            return true
        }
    }
}
