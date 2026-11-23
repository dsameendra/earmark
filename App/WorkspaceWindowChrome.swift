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
        private var updates: AnyCancellable?
        private var toolbarObserver: NSKeyValueObservation?
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
            // SwiftUI rebuilds window toolbars (when a window is reopened or its content changes) and brings the system
            // sidebar toggle back with them, so the removal is re-applied on every window update, not just once.
            updates = window.map { window in
                NotificationCenter.default.publisher(for: NSWindow.didUpdateNotification, object: window)
                    .sink { [weak self] _ in self?.keepNavigationPanePersistent() }
            }
            toolbarObserver = window?.observe(\.toolbar, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.apply() }
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

        private static let toggleLabels: Set<String> = ["toggle sidebar", "hide sidebar", "show sidebar"]

        /// Hides every system sidebar toggle: toolbar items matched by identifier, label or tooltip, and any titlebar view whose
        /// accessibility label says "Hide/Show/Toggle Sidebar" (the toggle is not always an `NSButton`).
        private func hideSidebarToggles(in window: NSWindow) {
            func isToggleText(_ text: String?) -> Bool { text.map { Self.toggleLabels.contains($0.lowercased()) } ?? false }
            for item in window.toolbar?.items ?? [] {
                let id = item.itemIdentifier.rawValue.lowercased()
                let matches =
                    item.itemIdentifier == .toggleSidebar || (id.contains("sidebar") && id.contains("toggle"))
                    || isToggleText(item.label) || isToggleText(item.paletteLabel) || isToggleText(item.toolTip)
                if matches {
                    if !item.isHidden { item.isHidden = true }
                    if let view = item.view, !view.isHidden { view.isHidden = true }
                }
            }
            func scan(_ view: NSView) {
                if isToggleText(view.accessibilityLabel()) || ((view as? NSControl) != nil && isToggleText(view.toolTip)) {
                    if !view.isHidden { view.isHidden = true }
                    // The toolbar draws this control inside a glass capsule/circle container that would stay on screen empty:
                    // hide every small ancestor (one toolbar control, not the toolbar or the window).
                    var ancestor = view.superview
                    while let current = ancestor, current.frame.width <= 64, current.frame.height <= 80 {
                        if !current.isHidden { current.isHidden = true }
                        ancestor = current.superview
                    }
                }
                for subview in view.subviews { scan(subview) }
            }
            if let frame = window.contentView?.superview { scan(frame) }
        }

        /// Cheap, idempotent: runs on every window update.
        private func keepNavigationPanePersistent() {
            guard let window else { return }
            if isSettings, window.toolbar != nil { window.toolbar = nil }
            hideSidebarToggles(in: window)
        }

        func apply() {
            guard let window else { return }
            if let content = window.contentView { lockNavigationPane(in: content) }
            hideSidebarToggles(in: window)
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
