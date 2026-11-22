import AppKit
import Foundation
import SwiftUI

/// Process-local visual QA overrides. Production launches always follow the system appearance and normal window restoration.
@MainActor
enum UITestConfiguration {
    static func value(_ name: String) -> String? {
        guard AppEnvironment.usesMocks,
            let index = ProcessInfo.processInfo.arguments.firstIndex(of: name),
            ProcessInfo.processInfo.arguments.indices.contains(index + 1)
        else { return nil }
        return ProcessInfo.processInfo.arguments[index + 1]
    }
    static var width: Double { value("-EarmarkTestWidth").flatMap(Double.init) ?? 1280 }
    static var height: Double { value("-EarmarkTestHeight").flatMap(Double.init) ?? 800 }

    static func applyAppearance() {
        guard let appearance = value("-EarmarkTestAppearance") else { return }
        NSApplication.shared.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
    }
}

/// Keeps QA windows on the primary display so XCTest screenshots do not capture a different monitor.
struct UITestWindowPlacement: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { PlacementView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class PlacementView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard UITestConfiguration.value("-EarmarkTestWidth") != nil, let window, let screen = NSScreen.screens.first else { return }
            // SwiftUI applies its initial/restored frame after attaching the hosting view.
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                let visible = screen.visibleFrame
                window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2, y: visible.midY - window.frame.height / 2))
                window.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate()
            }
        }
    }
}
