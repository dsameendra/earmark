import AppCore
import AppKit
import Dictation
import FeatureSupport
import Foundation
import SwiftUI
import UserNotifications

/// Posts dictation notices (device fallback, translation failure, refusal reasons) as user notifications. Authorization is
/// requested lazily like `SystemJobNotifier`; if the user declined, notices are skipped (the HUD still shows errors).
struct SystemDictationNotifier: DictationNotifying {
    func notify(_ notice: DictationNotice) async {
        let center = UNUserNotificationCenter.current()
        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert])
            status = await center.notificationSettings().authorizationStatus
        }
        guard status == .authorized || status == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = "Dictation"
        content.body = notice.message
        do {
            try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        } catch {
            AppLog.logger("notifications").error("Could not post dictation notice: \(String(describing: error), privacy: .public)")
        }
    }
}

/// Shows the Accessibility onboarding sheet (DICT-AC-06) in its own small window. The controller detects the grant live
/// and calls `dismissAccessibilityOnboarding()`.
@MainActor
final class AccessibilityOnboardingPresenter: DictationOnboardingPresenting {
    private var window: NSWindow?

    func presentAccessibilityOnboarding(settingsURL: URL) async {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = AccessibilityOnboardingView(
            openSettings: { NSWorkspace.shared.open(settingsURL) },
            dismiss: { [weak self] in Task { await self?.dismissAccessibilityOnboarding() } })
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable]
        window.title = "Dictation"
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func dismissAccessibilityOnboarding() async {
        window?.close()
        window = nil
    }
}

extension DictationMenuControl {
    /// Menu bar toggle over the controller. Push-to-talk needs a release to finish, toggle mode a second press.
    static func make(controller: DictationController, settings: any SettingsStore) -> DictationMenuControl {
        DictationMenuControl(
            isListening: {
                let states = controller.states()
                return AsyncStream { continuation in
                    let task = Task {
                        for await state in states {
                            if case .listening = state { continuation.yield(true) } else { continuation.yield(false) }
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            },
            toggle: {
                var active = false
                for await state in controller.states() {
                    if case .listening = state { active = true }
                    break
                }
                let mode = await DictationSettings.load(from: settings).mode
                await controller.handle(active && mode == .pushToTalk ? .released : .pressed)
            })
    }
}
