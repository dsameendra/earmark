import AppCore
import AppKit
import FeatureSettings
import FeatureSupport
import Foundation
import os
@preconcurrency import UserNotifications

/// Delivers "meeting detected" prompts as user notifications with actions (MTG-AC-04): Record, Transcribe only,
/// Ignore this meeting, Always transcribe and Never ask for this app. Responses flow back through `responses()` to
/// `MeetingsModel`, which owns every decision; this type only talks to `UserNotifications`.
///
/// If notification permission is denied nothing is posted and the inline banner in Meetings is the fallback; the Dock icon
/// also bounces once so the user notices the in-app prompt.
final class SystemMeetingPrompter: NSObject, MeetingPromptPresenting, UNUserNotificationCenterDelegate, Sendable {
    struct LastPrompt: Sendable {
        var date: Date
        var app: MeetingApp
        var channel: String
    }

    private let bus = Broadcaster<MeetingPromptResponse>()
    private let lastPromptState = OSAllocatedUnfairLock<LastPrompt?>(initialState: nil)
    private let log = AppLog.logger("meetings.prompts")
    var lastPrompt: LastPrompt? { lastPromptState.withLock { $0 } }
    private static let consentIdentifier = "earmark.meeting.consent"

    /// Registers the notification categories and becomes the centre's delegate. Call once at launch.
    func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let categories = MeetingApp.allCases.map { app in
            let actions = MeetingPromptAction.allCases.map { action in
                UNNotificationAction(
                    identifier: action.identifier, title: action.title(for: app),
                    options: action.opensApp ? [.foreground] : [])
            }
            return UNNotificationCategory(
                identifier: Self.category(for: app), actions: actions, intentIdentifiers: [], options: [])
        }
        // No other feature registers notification categories today; merge here if one ever does.
        center.setNotificationCategories(Set(categories))
    }

    private static func category(for app: MeetingApp) -> String { "\(MeetingPrompt.categoryPrefix).\(app.rawValue)" }

    /// Asks for notification permission once, while the user is in Earmark (launch with meeting detection on), not
    /// in the middle of a call when the system dialog would appear behind Zoom or Teams.
    func requestAuthorizationIfNeeded() async {
        _ = await authorized()
    }

    /// Posts an action-less, prompt-style notification so the user can confirm alerts reach them. Starts no capture.
    func sendTestPrompt() async -> MeetingTestPromptOutcome {
        guard await authorized() else {
            record(app: .zoom, channel: "in-app only (test)")
            await requestAttention()
            return .notificationsDenied
        }
        let content = UNMutableNotificationContent()
        content.title = "Meeting prompt test"
        content.body = "This is how Earmark asks before it transcribes or records a meeting. Nothing was detected."
        content.sound = .default
        await add(UNNotificationRequest(identifier: "earmark.meeting.test", content: content, trigger: nil))
        record(app: .zoom, channel: "notification (test)")
        return .delivered
    }

    private func record(app: MeetingApp, channel: String) {
        lastPromptState.withLock { $0 = LastPrompt(date: Date(), app: app, channel: channel) }
        log.info("meeting prompt: \(app.rawValue, privacy: .public) via \(channel, privacy: .public)")
    }

    private func requestAttention() async {
        await MainActor.run { _ = NSApplication.shared.requestUserAttention(.informationalRequest) }
    }

    func present(_ prompt: MeetingPrompt) async {
        guard await authorized() else {
            record(app: prompt.app, channel: "in-app only")
            await requestAttention()
            return
        }
        record(app: prompt.app, channel: "notification")
        let content = UNMutableNotificationContent()
        content.title = prompt.title
        content.body = prompt.body
        content.categoryIdentifier = Self.category(for: prompt.app)
        content.threadIdentifier = prompt.identifier
        content.userInfo = ["app": prompt.app.rawValue]
        content.sound = .default
        await add(UNNotificationRequest(identifier: prompt.identifier, content: content, trigger: nil))
    }

    func withdraw(app: MeetingApp) async {
        let center = UNUserNotificationCenter.current()
        let id = MeetingPrompt.identifier(for: app)
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    func remindConsent(app: MeetingApp) async {
        guard await authorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = "Recording \(app.occurrenceName)"
        content.body = "You are responsible for telling participants before you record."
        await add(UNNotificationRequest(identifier: Self.consentIdentifier, content: content, trigger: nil))
    }

    func responses() -> AsyncStream<MeetingPromptResponse> { bus.stream() }

    // MARK: UNUserNotificationCenterDelegate

    /// Show prompts and reminders even while Earmark is the frontmost app.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        let actionIdentifier = response.actionIdentifier
        let app = (content.userInfo["app"] as? String).flatMap(MeetingApp.init(rawValue:))
        if content.categoryIdentifier.hasPrefix(MeetingPrompt.categoryPrefix), let app {
            switch actionIdentifier {
            case UNNotificationDefaultActionIdentifier: bus.send(MeetingPromptResponse(app: app, action: nil))
            case UNNotificationDismissActionIdentifier: break
            default:
                if let action = MeetingPromptAction(identifier: actionIdentifier) {
                    bus.send(MeetingPromptResponse(app: app, action: action))
                }
            }
        }
        completionHandler()
    }

    // MARK: Helpers

    private func authorized() async -> Bool {
        let center = UNUserNotificationCenter.current()
        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            status = await center.notificationSettings().authorizationStatus
        }
        return status == .authorized || status == .provisional
    }

    private func add(_ request: UNNotificationRequest) async {
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            AppLog.logger("notifications").error("Could not post meeting notification: \(String(describing: error), privacy: .public)")
        }
    }
}
