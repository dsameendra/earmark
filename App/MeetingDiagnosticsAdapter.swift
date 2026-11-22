import AppCore
import FeatureSettings
import Foundation
import Meetings

/// Backs Settings > Meetings > Detection diagnostics with the live detector and the notification prompter.
struct MeetingDiagnosticsAdapter: MeetingDiagnosing {
    let detector: ProbeMeetingDetector
    let prompter: SystemMeetingPrompter

    func snapshot() async -> MeetingDiagnosticsSnapshot {
        let rows = await detector.diagnostics().map { row in
            MeetingAppDiagnostics(
                app: row.app, isRunning: row.activity.isAppRunning, micInput: row.activity.micInput,
                audioOutput: row.activity.audioOutput, deviceMicInUse: row.activity.deviceMicInUse,
                callHelperPresent: row.activity.helperPresent, phase: row.phase, lastSignalAt: row.lastSignalAt,
                lastStartedAt: row.lastStartedAt)
        }
        let processes = await detector.audioProcesses().map { process in
            "\(process.bundleID) (\(process.input ? "in" : "")\(process.input && process.output ? "+" : "")\(process.output ? "out" : ""))"
        }
        let last = prompter.lastPrompt
        return MeetingDiagnosticsSnapshot(
            apps: rows, activeAudioProcesses: processes, lastPromptAt: last?.date, lastPromptApp: last?.app,
            lastPromptChannel: last?.channel)
    }

    func sendTestPrompt() async -> MeetingTestPromptOutcome { await prompter.sendTestPrompt() }
}
