import AppKit
import DesignSystem
import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(spacing: DSSpacing.lg) {
            Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("earmark").font(DSTypography.title1)
            Text("Listen once. Keep what matters.").font(DSTypography.transcript).italic()
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0")")
                .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
            Text("Speech stays on this Mac. Model weights are downloaded separately and retain their own licences.")
                .font(DSTypography.body).multilineTextAlignment(.center)
            if let url = Bundle.main.url(forResource: "NativeRuntimeLicences", withExtension: "txt") {
                Button("Native runtime licences") { NSWorkspace.shared.open(url) }
            }
        }
        .padding(DSSpacing.xxl).frame(width: 440).background(DSColor.contentBackground)
    }
}

struct AboutCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {}  // About lives in the Help menu
        CommandGroup(before: .help) {
            Button("About Earmark") { openWindow(id: "about") }
        }
    }
}
