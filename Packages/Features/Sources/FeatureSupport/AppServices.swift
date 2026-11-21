import AppCore

/// The dependency bundle the app shell hands to feature models (built by the composition root in `App/`).
public struct AppServices: Sendable {
    public var jobQueue: any JobQueue
    public var transcripts: any TranscriptRepository
    public var meetings: any MeetingRepository
    public var models: any ModelManaging
    public var live: any LiveSessionControlling
    public var meetingDetector: any MeetingDetector
    public var hardware: any HardwareTierProviding
    public var permissions: any PermissionsServicing
    public var audioDevices: any AudioDeviceProviding
    public var settings: any SettingsStore
    /// Media assets for the editor's player; nil means the player shows the media-missing state.
    public var media: (any MediaRepository)?
    /// Export presets for the editor's export sheet; nil hides the presets section.
    public var presets: (any PresetRepository)?

    public init(
        jobQueue: any JobQueue, transcripts: any TranscriptRepository, meetings: any MeetingRepository, models: any ModelManaging,
        live: any LiveSessionControlling, meetingDetector: any MeetingDetector, hardware: any HardwareTierProviding,
        permissions: any PermissionsServicing, audioDevices: any AudioDeviceProviding, settings: any SettingsStore,
        media: (any MediaRepository)? = nil, presets: (any PresetRepository)? = nil
    ) {
        self.jobQueue = jobQueue
        self.transcripts = transcripts
        self.meetings = meetings
        self.models = models
        self.live = live
        self.meetingDetector = meetingDetector
        self.hardware = hardware
        self.permissions = permissions
        self.audioDevices = audioDevices
        self.settings = settings
        self.media = media
        self.presets = presets
    }

    /// Fully in-memory services for previews and tests.
    public static func preview(transcripts: [Transcript] = [], jobs: [Job] = [], meetings: [Meeting] = []) -> AppServices {
        AppServices(
            jobQueue: PlaceholderJobQueue(seed: jobs), transcripts: InMemoryTranscripts(items: transcripts),
            meetings: InMemoryMeetings(items: meetings), models: StaticModels(), live: PlaceholderLiveSession(),
            meetingDetector: PlaceholderMeetingDetector(), hardware: PlaceholderHardware(), permissions: PlaceholderPermissions(),
            audioDevices: PlaceholderAudioDevices(), settings: InMemorySettingsStore())
    }
}
