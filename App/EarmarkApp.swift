import AppKit
import DesignSystem
import FeatureMenuBar
import FeatureSettings
import FeatureShell
import SwiftUI

/// Keeps the app alive as a menu bar item after the main window closes (NAV-AC-16, MENU-AC-01).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct EarmarkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment = AppEnvironment()

    var body: some Scene {
        Window("Earmark", id: MainWindow.id) {
            ShellView(model: environment.shell)
                .onboardingLauncher(settings: environment.services.settings)
                .background { if let packs = environment.translationPacks { TranslationPackHost(installer: packs) } }
                .tint(DSColor.accent)
        }
        .defaultSize(width: 1000, height: 640)
        .commands {
            ShellCommands(model: environment.shell)
            OnboardingCommands(settings: environment.services.settings)
        }

        Window("Welcome to Earmark", id: OnboardingWindow.id) {
            OnboardingWindowRoot(services: environment.services, router: environment.engineRouter)
                .tint(DSColor.accent)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            SettingsRootView(dependencies: environment.settingsDependencies)
                .onboardingLauncher(settings: environment.services.settings)
                .tint(DSColor.accent)
        }

        MenuBarExtra {
            MenuBarHost(environment: environment)
                .tint(DSColor.accent)
        } label: {
            MenuBarIconView(model: environment.menuBar)
        }
        .menuBarExtraStyle(.window)
    }
}

enum MainWindow {
    static let id = "main"
}

/// Menu bar popover content wired to window opening and shell navigation.
private struct MenuBarHost: View {
    let environment: AppEnvironment
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        MenuBarContentView(
            model: environment.menuBar,
            actions: MenuBarActions(
                transcribeFile: {
                    showMainWindow()
                    environment.shell.presentImporter()
                },
                openQueue: {
                    showMainWindow()
                    environment.shell.select(.queue)
                },
                openLibrary: {
                    showMainWindow()
                    environment.shell.select(.library)
                },
                openMainWindow: showMainWindow,
                openSettings: {
                    NSApplication.shared.activate()
                    openSettings()
                },
                quit: { NSApplication.shared.terminate(nil) }))
    }

    private func showMainWindow() {
        openWindow(id: MainWindow.id)
        NSApplication.shared.activate()
    }
}
