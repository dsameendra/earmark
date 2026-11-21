import AppCore
import SwiftUI

@main
struct EarmarkApp: App {
    var body: some Scene {
        WindowGroup("Earmark") {
            Text("Earmark")
                .frame(minWidth: 600, minHeight: 400)
        }
        MenuBarExtra("Earmark", systemImage: "waveform") {
            Text("Idle")
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .menuBarExtraStyle(.window)
    }
}
