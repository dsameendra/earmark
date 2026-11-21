import AppCore
import Foundation
import Jobs
import UserNotifications

/// Posts a user notification when a transcription job or batch finishes (FILE-AC-11). The Jobs package only knows the
/// `JobNotifier` protocol; this is the one place that talks to `UNUserNotificationCenter`.
///
/// Authorization is requested lazily the first time something finishes, so the prompt appears in a meaningful moment.
/// If the user declined, notifications are silently skipped.
struct SystemJobNotifier: JobNotifier {
    func jobCompleted(_ info: JobCompletionInfo) async {
        var body = info.transcriptTitle ?? info.job.input?.lastPathComponent ?? "Your file"
        if let exported = info.exportedTo { body += " (exported to \(exported.lastPathComponent))" }
        await post(id: info.job.id.description, title: "Transcription finished", body: body)
    }

    func jobFailed(_ job: Job) async {
        let name = job.input?.lastPathComponent ?? "A file"
        await post(id: job.id.description, title: "Transcription failed", body: "\(name): \(job.failureReason ?? "Unknown error")")
    }

    func batchFinished(_ summary: JobBatchSummary) async {
        var parts = ["\(summary.completed) of \(summary.total) transcribed"]
        if summary.failed > 0 { parts.append("\(summary.failed) failed") }
        if summary.cancelled > 0 { parts.append("\(summary.cancelled) cancelled") }
        await post(
            id: summary.jobIDs.first.map { "batch-\($0.description)" } ?? UUID().uuidString, title: "Batch finished",
            body: parts.joined(separator: ", "))
    }

    private func post(id: String, title: String, body: String) async {
        let center = UNUserNotificationCenter.current()
        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            status = await center.notificationSettings().authorizationStatus
        }
        guard status == .authorized || status == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        do {
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        } catch {
            AppLog.logger("notifications").error("Could not post notification: \(String(describing: error), privacy: .public)")
        }
    }
}
