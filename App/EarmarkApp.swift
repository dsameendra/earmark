import AppKit
import DesignSystem
import FeatureEditor
import FeatureMenuBar
import FeatureSettings
import FeatureShell
import SwiftUI

/// Keeps the app alive as a menu bar item after the main window closes (NAV-AC-16, MENU-AC-01).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { UITestConfiguration.applyAppearance() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct EarmarkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment = AppEnvironment()

    var body: some Scene {
        Window("Earmark", id: MainWindow.id) {
            if let message = environment.startupFailure {
                LibraryRecoveryView(message: message) { environment = AppEnvironment() }
            } else {
                ShellView(model: environment.shell)
                    .background(WorkspaceWindowChrome())
                    .environment(\.accessibilityPolicyOverride, UITestConfiguration.accessibilityPolicy)
                    .background(UITestWindowPlacement())
                    .onboardingLauncher(settings: environment.services.settings)
                    .background { if let packs = environment.translationPacks { TranslationPackHost(installer: packs) } }
                    .tint(DSColor.accent)
            }
        }
        .defaultSize(width: UITestConfiguration.width, height: UITestConfiguration.height)
        .defaultLaunchBehavior(.presented)
        .windowToolbarStyle(.unifiedCompact)
        .restorationBehavior(AppEnvironment.usesMocks ? .disabled : .automatic)
        .windowResizability(.contentMinSize)
        .commands {
            ShellCommands(model: environment.shell)
            PlayerZoomCommands()
            OnboardingCommands(settings: environment.services.settings)
            UpdateCommands(updates: environment.updates)
            AboutCommands()
        }

        Window("", id: OnboardingWindow.id) {
            if let message = environment.startupFailure {
                LibraryRecoveryView(message: message) { environment = AppEnvironment() }
            } else {
                OnboardingWindowRoot(services: environment.services, router: environment.engineRouter)
                    .environment(\.accessibilityPolicyOverride, UITestConfiguration.accessibilityPolicy)
                    .background(WelcomeWindowPresentation())
                    .background(UITestWindowPlacement()).tint(DSColor.accent)
            }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .windowManagerRole(.associated)
        .commandsRemoved()
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .defaultPosition(.center)
        .defaultSize(width: 900, height: 620)

        Window("About Earmark", id: "about") { AboutView() }
            .windowResizability(.contentSize)
            .defaultPosition(.center)

        Settings {
            if let message = environment.startupFailure {
                LibraryRecoveryView(message: message) { environment = AppEnvironment() }
            } else {
                SettingsRootView(dependencies: environment.settingsDependencies)
                    .background(WorkspaceWindowChrome(isSettings: true))
                    .environment(\.accessibilityPolicyOverride, UITestConfiguration.accessibilityPolicy)
                    .background(UITestWindowPlacement())
                    .onboardingLauncher(settings: environment.services.settings)
                    .tint(DSColor.accent)
            }
        }
        .windowToolbarStyle(.unifiedCompact)

        MenuBarExtra {
            if environment.startupFailure != nil {
                LibraryUnavailableMenu()
            } else {
                MenuBarHost(environment: environment).tint(DSColor.accent)
                    .environment(\.accessibilityPolicyOverride, UITestConfiguration.accessibilityPolicy)
            }
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
                openMeetings: {
                    showMainWindow()
                    environment.shell.select(.meetings)
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
        .animation(DSMotion.pulse(AccessibilityPolicy(reduceMotion: !pulsing)) ?? DSMotion.exit.animation(), value: dimmed)
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

/// A persistent-library failure is visible and blocks editing until the real library can be reopened.
private struct LibraryRecoveryView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            Text("Your library needs attention").font(DSTypography.title1)
            Text(message).foregroundStyle(DSColor.secondaryText).textSelection(.enabled)
            HStack {
                Button("Show library folder") {
                    if let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                        NSWorkspace.shared.open(root.appendingPathComponent("Earmark", isDirectory: true))
                    }
                }
                Button("Try again", action: retry).buttonStyle(EmberButtonStyle())
            }
        }
        .padding(DSSpacing.xxl).frame(minWidth: 660, minHeight: 360)
        .background(DSColor.contentBackground)
        .accessibilityIdentifier("startup.libraryRecovery")
    }
}

private struct LibraryUnavailableMenu: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            Text("Library unavailable").font(DSTypography.headline)
            Button("Open recovery") {
                openWindow(id: MainWindow.id)
                NSApplication.shared.activate()
            }
            Button("Quit Earmark") { NSApplication.shared.terminate(nil) }
        }.padding(DSSpacing.lg)
    }
}
