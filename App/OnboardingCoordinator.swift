import AppCore
import AppKit
import FeatureOnboarding
import FeatureSupport
import SwiftUI
import Transcription

/// First-run onboarding wiring (T27). Everything app-side lives here; `EarmarkApp` only adds the window scene,
/// the Help-menu command and the launcher modifier.
enum OnboardingWindow {
    static let id = "onboarding"
}

/// Content of the onboarding window. Owns the flow model; closes the window when the flow is completed or skipped.
struct OnboardingWindowRoot: View {
    @State private var model: OnboardingModel
    @Environment(\.dismissWindow) private var dismissWindow

    init(services: AppServices, router: any EngineRouter) {
        _model = State(initialValue: OnboardingModel(services: services, router: router))
    }

    var body: some View {
        OnboardingView(model: model)
            .onChange(of: model.isFinished) { _, finished in
                if finished { dismissWindow(id: OnboardingWindow.id) }
            }
    }
}

/// Presents the window on first launch and whenever the completion flag is cleared (Settings > General "Show Welcome Again").
private struct OnboardingLauncher: ViewModifier {
    let settings: any SettingsStore
    @Environment(\.openWindow) private var openWindow

    @MainActor private enum Launch { static var checked = false }

    func body(content: Content) -> some View {
        content.task {
            // UI tests and previews run with mock services and must not be interrupted by the welcome window.
            guard !AppEnvironment.usesMocks else { return }
            if !Launch.checked {
                Launch.checked = true
                if await OnboardingModel.shouldPresent(store: settings) { present() }
            }
            for await _ in settings.changes(for: SettingsKey.onboardingCompleted) {
                if await OnboardingModel.shouldPresent(store: settings) { present() }
            }
        }
    }

    private func present() {
        openWindow(id: OnboardingWindow.id)
        NSApplication.shared.activate()
    }
}

extension View {
    /// Shows the onboarding window on first launch and when "Show Welcome Again" is chosen.
    func onboardingLauncher(settings: any SettingsStore) -> some View { modifier(OnboardingLauncher(settings: settings)) }
}

/// Help menu: "Show Welcome Again".
struct OnboardingCommands: Commands {
    let settings: any SettingsStore
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .help) {
            Button("Show Welcome Again") {
                Task {
                    await OnboardingModel.requestWelcomeAgain(store: settings)
                    openWindow(id: OnboardingWindow.id)
                    NSApplication.shared.activate()
                }
            }
        }
    }
}
