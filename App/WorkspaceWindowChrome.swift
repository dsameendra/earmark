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

        func apply() {
            guard let window else { return }
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
