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
            MenuBarGlyphView(model: environment.menuBar)
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

/// Menu bar label using the Earmark ear glyph. Idle is a template image (the system tints it for the
/// menu bar); recording composes the same glyph with the recording-red dot (never Ember) into an image
/// that redraws for the current appearance. Behaviour matches `MenuBarIconView`: pulse while recording
/// unless Reduce Motion is on (MENU-AC-07).
private struct MenuBarGlyphView: View {
    let model: MenuBarModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var dimmed = false

    var body: some View {
        let recording = model.status.isRecording
        let pulsing = recording && !reduceMotion
        Group {
            if recording {
                Image(nsImage: MenuBarGlyph.recording)
            } else {
                Image("MenuBarIdle")
            }
        }
        .opacity(pulsing && dimmed ? 0.55 : 1)
        .animation(pulsing ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: dimmed)
        .onChange(of: pulsing, initial: true) { _, isPulsing in dimmed = isPulsing }
        .accessibilityLabel("Earmark")
        .accessibilityValue(model.status.text)
    }
}

@MainActor
private enum MenuBarGlyph {
    /// Template ear tinted with the current label colour plus the non-template red dot asset.
    static let recording: NSImage = {
        let glyph = NSImage(named: "MenuBarIdle")
        let dot = NSImage(named: "MenuBarRecordingDot")
        let size = glyph?.size ?? NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            if let glyph {
                glyph.draw(in: rect)
                NSColor.labelColor.setFill()
                rect.fill(using: .sourceIn)
            }
            dot?.draw(in: rect)
            return true
        }
        image.isTemplate = false
        return image
    }()
}
