import AppCore
import DesignSystem
import FeatureSupport
import Foundation
import SwiftUI

// MARK: - Seam (the app target backs this with the detector and the notification prompter)

/// What the detector reads for one meeting app right now. Flags only; no audio and no transcript content.
public struct MeetingAppDiagnostics: Sendable, Equatable, Identifiable {
    public var app: MeetingApp
    public var isRunning: Bool
    public var micInput: Bool
    public var audioOutput: Bool
    public var deviceMicInUse: Bool
    public var callHelperPresent: Bool
    /// Detector phase: idle, candidate, active or ending.
    public var phase: String
    public var lastSignalAt: Date?
    public var lastStartedAt: Date?
    public var id: MeetingApp { app }

    public init(
        app: MeetingApp, isRunning: Bool, micInput: Bool, audioOutput: Bool, deviceMicInUse: Bool, callHelperPresent: Bool,
        phase: String, lastSignalAt: Date? = nil, lastStartedAt: Date? = nil
    ) {
        self.app = app
        self.isRunning = isRunning
        self.micInput = micInput
        self.audioOutput = audioOutput
        self.deviceMicInUse = deviceMicInUse
        self.callHelperPresent = callHelperPresent
        self.phase = phase
        self.lastSignalAt = lastSignalAt
        self.lastStartedAt = lastStartedAt
    }
}

public struct MeetingDiagnosticsSnapshot: Sendable, Equatable {
    public var apps: [MeetingAppDiagnostics]
    /// Bundle IDs of processes with a running audio stream (helps find which process carries a Teams call).
    public var activeAudioProcesses: [String]
    public var lastPromptAt: Date?
    public var lastPromptApp: MeetingApp?
    /// How the last prompt was shown: "notification" or "in-app only".
    public var lastPromptChannel: String?

    public init(
        apps: [MeetingAppDiagnostics] = [], activeAudioProcesses: [String] = [], lastPromptAt: Date? = nil,
        lastPromptApp: MeetingApp? = nil, lastPromptChannel: String? = nil
    ) {
        self.apps = apps
        self.activeAudioProcesses = activeAudioProcesses
        self.lastPromptAt = lastPromptAt
        self.lastPromptApp = lastPromptApp
        self.lastPromptChannel = lastPromptChannel
    }
}

public enum MeetingTestPromptOutcome: Sendable, Equatable {
    /// A notification was posted.
    case delivered
    /// Notifications are off for Earmark; only the in-app message can be shown.
    case notificationsDenied
}

public protocol MeetingDiagnosing: Sendable {
    func snapshot() async -> MeetingDiagnosticsSnapshot
    /// Posts a prompt-style notification with no actions (nothing is recorded), requesting permission first if needed.
    func sendTestPrompt() async -> MeetingTestPromptOutcome
}

// MARK: - Model

@MainActor @Observable
public final class MeetingDiagnosticsModel {
    public private(set) var snapshot = MeetingDiagnosticsSnapshot()
    public private(set) var testOutcome: MeetingTestPromptOutcome?
    @ObservationIgnored private let source: (any MeetingDiagnosing)?

    public init(source: (any MeetingDiagnosing)?) { self.source = source }

    public var isAvailable: Bool { source != nil }

    public func refresh() async {
        guard let source else { return }
        snapshot = await source.snapshot()
    }

    /// Polls while the Settings pane is visible; cancelled with the view's task.
    public func follow(every interval: Duration = .seconds(2)) async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: interval)
        }
    }

    public func sendTestPrompt() async {
        guard let source else { return }
        testOutcome = await source.sendTestPrompt()
        await refresh()
    }

    /// Message shown right below the button after a test.
    public var testMessage: String? {
        switch testOutcome {
        case .delivered?: "Sent. If you saw a notification, meeting prompts will reach you."
        case .notificationsDenied?:
            "Notifications are turned off for Earmark, so meeting prompts will only appear inside Earmark (Meetings screen). "
                + "Turn them on in System Settings > Notifications to get alerts."
        case nil: nil
        }
    }

    // MARK: Presentation helpers (pure)

    public static func signalLine(_ row: MeetingAppDiagnostics) -> String {
        guard row.isRunning else { return "Not running" }
        func flag(_ name: String, _ on: Bool) -> String { "\(name) \(on ? "on" : "off")" }
        var parts = [flag("mic", row.micInput), flag("audio out", row.audioOutput), flag("device mic", row.deviceMicInUse)]
        if row.callHelperPresent { parts.append("call helper present") }
        return "Running: " + parts.joined(separator: ", ")
    }

    public static func phaseLabel(_ phase: String) -> String {
        switch phase {
        case "candidate": "Checking (a call may be starting)"
        case "active": "In a meeting"
        case "ending": "Meeting may be ending"
        default: "No meeting"
        }
    }

    public static func processLine(_ bundleID: String) -> String { bundleID }
}

// MARK: - View

struct MeetingDiagnosticsSection: View {
    let model: MeetingDiagnosticsModel

    var body: some View {
        Section {
            ForEach(model.snapshot.apps) { row in
                VStack(alignment: .leading, spacing: DSSpacing.xs) {
                    Text(row.app.title)
                    Text("\(MeetingDiagnosticsModel.phaseLabel(row.phase)). \(MeetingDiagnosticsModel.signalLine(row))")
                        .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                    if let at = row.lastSignalAt {
                        Text("Last audio signal \(at.formatted(date: .omitted, time: .standard))")
                            .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                    }
                }
                .accessibilityIdentifier("meetings.diagnostics.\(row.app.rawValue)")
            }
            LabeledContent("Last prompt") {
                if let at = model.snapshot.lastPromptAt, let app = model.snapshot.lastPromptApp {
                    Text("\(app.title) at \(at.formatted(date: .omitted, time: .standard)) (\(model.snapshot.lastPromptChannel ?? "shown"))")
                        .foregroundStyle(DSColor.secondaryText)
                } else {
                    Text("None yet").foregroundStyle(DSColor.secondaryText)
                }
            }
            if !model.snapshot.activeAudioProcesses.isEmpty {
                DisclosureGroup("Processes using audio right now") {
                    ForEach(model.snapshot.activeAudioProcesses, id: \.self) { id in
                        Text(MeetingDiagnosticsModel.processLine(id)).font(DSTypography.caption).textSelection(.enabled)
                    }
                }
            }
            Button("Test prompt") { Task { await model.sendTestPrompt() } }
                .accessibilityIdentifier("meetings.diagnostics.testPrompt")
            if let message = model.testMessage {
                Text(message).font(DSTypography.caption)
                    .foregroundStyle(model.testOutcome == .notificationsDenied ? DSColor.danger : DSColor.secondaryText)
                    .accessibilityIdentifier("meetings.diagnostics.testMessage")
            }
        } header: {
            Text("Detection diagnostics")
        } footer: {
            Text(
                "Shows which meeting apps are running and what Earmark reads from them. No audio or transcript content is logged."
            )
        }
        .task { await model.follow() }
    }
}
