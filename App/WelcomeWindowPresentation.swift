import AppKit
import DesignSystem
import SwiftUI

/// A welcome utility window has no title or Window-menu entry; Settings and Help own its explicit entry points.
struct WelcomeWindowPresentation: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowPolicyView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowPolicyView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(DSColor.contentBackground)
            window.titlebarSeparatorStyle = .none
            window.titleVisibility = .hidden
            window.title = ""
            window.isExcludedFromWindowsMenu = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        }
    }
}
