import AppCore
import DesignSystem
import Foundation

// Seams between the UI and the meeting runtime (T23). AppCore is frozen and the `Recorder` protocol needs raw audio
// streams the UI cannot produce, so the UI talks to this small capture seam; the composition root fills it in.

extension MeetingApp {
    /// Full product name ("Zoom", "Microsoft Teams").
    public var title: String {
        switch self {
        case .zoom: "Zoom"
        case .teams: "Microsoft Teams"
        }
    }
    /// Short badge text.
    public var badgeTitle: String {
        switch self {
        case .zoom: "Zoom"
        case .teams: "Teams"
        }
    }
    /// Symbol name for rows and banners (rule A3).
    public var symbol: DSSymbol { .meetings }
    public var systemImage: String { symbol.systemImageName }
}

extension MeetingBehavior {
    public var title: String {
        switch self {
        case .doNothing: "Do nothing"
        case .askFirst: "Ask first"
        case .autoTranscribe: "Auto-transcribe"
        case .autoTranscribeAndRecord: "Auto-transcribe + record"
        }
    }
}

/// What a started meeting capture does. Recording always includes transcription.
public enum MeetingCaptureMode: String, Codable, Sendable, Hashable {
    case transcribeOnly, transcribeAndRecord
    public var recordsAudio: Bool { self == .transcribeAndRecord }
}

public enum MeetingCaptureState: Sendable, Equatable {
    case idle, starting
    case capturing(MeetingApp, mode: MeetingCaptureMode, since: Date)
    case stopping
    case failed(String)

    public var isActive: Bool {
        switch self {
        case .starting, .capturing, .stopping: true
        case .idle, .failed: false
        }
    }
}

/// Starts and stops a meeting capture: dual-track audio (mic = "You", remote diarized), live transcript, optional
/// recording, and the finalization pass on stop. Implemented by the Meetings runtime (T23).
public protocol MeetingCapturing: Sendable {
    func start(app: MeetingApp, mode: MeetingCaptureMode) async throws
    /// Stops capture and returns the transcript being finalized, if any.
    func stop() async -> TranscriptID?
    func state() -> AsyncStream<MeetingCaptureState>
    /// Live caption lines with speaker labels (mic is "You", remote speakers are provisional slots).
    func lines() -> AsyncStream<[CaptionLine]>
}

// MARK: - Notification prompts

/// Actions offered on the "meeting detected" notification (MTG-AC-04).
public enum MeetingPromptAction: String, CaseIterable, Codable, Sendable {
    case record, transcribeOnly, ignoreThisMeeting, alwaysForApp, neverForApp

    /// UNNotificationAction identifier.
    public var identifier: String { "earmark.meeting.action.\(rawValue)" }

    public init?(identifier: String) {
        guard let match = Self.allCases.first(where: { $0.identifier == identifier }) else { return nil }
        self = match
    }

    public func title(for app: MeetingApp) -> String {
        switch self {
        case .record: "Record"
        case .transcribeOnly: "Transcribe only"
        case .ignoreThisMeeting: "Ignore this meeting"
        case .alwaysForApp: "Always transcribe \(app.badgeTitle)"
        case .neverForApp: "Never ask for \(app.badgeTitle)"
        }
    }

    /// Whether the action should bring the app forward (it may need to show the consent notice).
    public var opensApp: Bool { self == .record }
}

/// The notification content for one detected meeting.
public struct MeetingPrompt: Sendable, Equatable {
    public var app: MeetingApp
    public var startedAt: Date
    public init(app: MeetingApp, startedAt: Date) {
        self.app = app
        self.startedAt = startedAt
    }
    /// One identifier per meeting so `.ended` can withdraw it.
    public var identifier: String { Self.identifier(for: app) }
    public static func identifier(for app: MeetingApp) -> String { "earmark.meeting.detected.\(app.rawValue)" }
    public static let categoryPrefix = "earmark.meeting.detected"
    public var title: String { "\(app.badgeTitle) meeting detected" }
    public var body: String { "Transcribe? Record? Nothing is recorded until you choose." }
}

/// A user response to a prompt; `action == nil` means the notification itself was clicked.
public struct MeetingPromptResponse: Sendable, Equatable {
    public var app: MeetingApp
    public var action: MeetingPromptAction?
    public init(app: MeetingApp, action: MeetingPromptAction?) {
        self.app = app
        self.action = action
    }
}

/// Delivers prompts (the app target backs this with `UserNotifications`).
public protocol MeetingPromptPresenting: Sendable {
    func present(_ prompt: MeetingPrompt) async
    func withdraw(app: MeetingApp) async
    /// One-time reminder that the user must tell participants (auto-record path, MTG-AC-05).
    func remindConsent(app: MeetingApp) async
    func responses() -> AsyncStream<MeetingPromptResponse>
}

// MARK: - Speaker reconciliation (DIA-AC-06)

/// Written by the finalization pass when offline diarization relabelled segments that the live pass had labelled; read
/// by the Editor to flag the relabel once.
public struct ReconciliationReport: Codable, Sendable, Equatable {
    public var relabeledSegmentIDs: [SegmentID]
    public var totalSegments: Int
    /// Set once the user has seen (or dismissed) the indicator, so it never shows again.
    public var acknowledged: Bool

    public init(relabeledSegmentIDs: [SegmentID], totalSegments: Int, acknowledged: Bool = false) {
        self.relabeledSegmentIDs = relabeledSegmentIDs
        self.totalSegments = totalSegments
        self.acknowledged = acknowledged
    }

    public var relabeledFraction: Double { totalSegments == 0 ? 0 : Double(relabeledSegmentIDs.count) / Double(totalSegments) }
    public var isEmpty: Bool { relabeledSegmentIDs.isEmpty }

    /// Compares live-labelled segments with the final ones (matched by segment ID).
    public static func make(live: [Segment], final: [Segment]) -> ReconciliationReport {
        let liveByID = Dictionary(live.map { ($0.id, $0.speakerID) }, uniquingKeysWith: { first, _ in first })
        let changed = final.filter { segment in
            guard let before = liveByID[segment.id] else { return false }
            return before != segment.speakerID
        }
        return ReconciliationReport(relabeledSegmentIDs: changed.map(\.id), totalSegments: final.count)
    }
}
