import AppKit
import Combine
import DesignSystem
import SwiftUI

/// Match native window chrome to the paper surface. Settings uses its sidebar instead of a preferences toolbar.
struct WorkspaceWindowChrome: NSViewRepresentable {
    var isSettings = false
    func makeNSView(context: Context) -> ChromeView { ChromeView(isSettings: isSettings) }
    func updateNSView(_ view: ChromeView, context: Context) { view.apply() }

    final class ChromeView: NSView {
        let isSettings: Bool
        private var becameKey: AnyCancellable?
        init(isSettings: Bool) {
            self.isSettings = isSettings
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            becameKey = window.map { window in
                NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification, object: window)
                    .sink { [weak self] _ in self?.apply() }
            }
            apply()
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        /// The navigation pane is persistent. The system toggle and the Hide Sidebar menu item are already removed; this also stops a
        /// drag on the divider from collapsing the pane (SwiftUI's NavigationSplitView keeps AppKit's default `canCollapse`).
        private func lockNavigationPane(in view: NSView) {
            if let split = view as? NSSplitView, let controller = split.delegate as? NSSplitViewController {
                for item in controller.splitViewItems where item.behavior == .sidebar && item.canCollapse { item.canCollapse = false }
            }
            for subview in view.subviews { lockNavigationPane(in: subview) }
        }

        func apply() {
            guard let window else { return }
            if let content = window.contentView { lockNavigationPane(in: content) }
            window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(DSColor.paper)
            if isSettings {
                window.toolbarStyle = .unifiedCompact
                window.toolbar = nil
                window.titleVisibility = .hidden
                window.titlebarSeparatorStyle = .none
            }
        }
    }
}
