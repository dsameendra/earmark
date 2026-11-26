import AppCore
import FeatureSupport

/// Everything the menu bar status depends on.
public struct MenuBarInputs: Sendable, Equatable {
    public var liveState: LiveSessionState = .idle
    public var detectedMeeting: MeetingApp?
    public var isRecordingMeeting = false
    public var isTranscribingMeeting = false
    public var dictationArmed = false
    public var runningJobs = 0
    public init(
        liveState: LiveSessionState = .idle, detectedMeeting: MeetingApp? = nil, isRecordingMeeting: Bool = false,
        isTranscribingMeeting: Bool = false,
        dictationArmed: Bool = false, runningJobs: Int = 0
    ) {
        self.liveState = liveState
        self.detectedMeeting = detectedMeeting
        self.isRecordingMeeting = isRecordingMeeting
        self.isTranscribingMeeting = isTranscribingMeeting
        self.dictationArmed = dictationArmed
        self.runningJobs = runningJobs
    }
}

/// The single state shown by the menu bar icon and one-line status (MENU-AC-02).
public enum MenuBarStatus: Sendable, Equatable {
    case idle, liveCaptions
    case meetingDetected(MeetingApp)
    case meetingRecording, meetingTranscribing, dictationArmed
    case queueRunning(Int)

    /// Picks the highest-priority state: recording, live, meeting detected, dictation, queue, idle.
    public static func resolve(_ inputs: MenuBarInputs) -> MenuBarStatus {
        if inputs.isRecordingMeeting { return .meetingRecording }
        if inputs.isTranscribingMeeting { return .meetingTranscribing }
        if inputs.liveState == .running || inputs.liveState == .starting { return .liveCaptions }
        if inputs.dictationArmed { return .dictationArmed }
        if let app = inputs.detectedMeeting { return .meetingDetected(app) }
        if inputs.runningJobs > 0 { return .queueRunning(inputs.runningJobs) }
        return .idle
    }

    /// One-line status text.
    public var text: String {
        switch self {
        case .idle: "Idle"
        case .liveCaptions: "Live captions on"
        case .meetingDetected(let app): "\(app.occurrenceName) detected"
        case .meetingRecording: "Recording meeting"
        case .meetingTranscribing: "Transcribing meeting"
        case .dictationArmed: "Dictation armed"
        case .queueRunning(let count): count == 1 ? "Transcribing 1 file" : "Transcribing \(count) files"
        }
    }

    /// SF Symbol for the menu bar icon.
    public var systemImage: String {
        switch self {
        case .idle: "waveform"  // stock-chrome: menu bar glyph, owned by T32
        case .liveCaptions: "captions.bubble.fill"  // stock-chrome: menu bar glyph, owned by T32
        case .meetingDetected: "person.2.wave.2"  // stock-chrome: menu bar glyph, owned by T32
        case .meetingRecording: "record.circle.fill"  // stock-chrome: menu bar glyph, owned by T32
        case .meetingTranscribing: "waveform"  // stock-chrome: live capture status glyph
        case .dictationArmed: "mic.fill"  // stock-chrome: menu bar glyph, owned by T32
        case .queueRunning: "waveform.badge.magnifyingglass"
        }
    }

    /// `true` while audio is being captured, including volatile captions/dictation (persistent indicator, MENU-AC-07).
    public var isRecording: Bool {
        self == .meetingRecording || self == .meetingTranscribing || self == .liveCaptions || self == .dictationArmed
    }
}
