import AppCore
import FeatureSupport
import Foundation
@preconcurrency import UserNotifications

/// Delivers "meeting detected" prompts as user notifications with actions (MTG-AC-04): Record, Transcribe only,
/// Ignore this meeting, Always transcribe and Never ask for this app. Responses flow back through `responses()` to
/// `MeetingsModel`, which owns every decision; this type only talks to `UserNotifications`.
///
/// If notification permission is denied nothing is posted and the inline banner in Meetings is the fallback.
final class SystemMeetingPrompter: NSObject, MeetingPromptPresenting, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let bus = Broadcaster<MeetingPromptResponse>()
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

    func present(_ prompt: MeetingPrompt) async {
        guard await authorized() else { return }
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
        content.title = "Recording \(app.badgeTitle) meeting"
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
