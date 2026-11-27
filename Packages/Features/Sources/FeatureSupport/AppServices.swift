import AppCore
import Foundation

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
    /// Media assets (relink, library-owned media). Optional until the composition root provides it.
    public var media: (any MediaRepository)?
    /// Directories that library-relative media paths resolve against, in priority order (see ``MediaFiles``).
    public var mediaRoots: @Sendable () async -> [URL]
    /// Export presets (batch auto-export picker). Optional until the composition root provides it.
    public var presets: (any PresetRepository)?
    /// Pause, meter, overlay and preset controls for live captions; `nil` where unavailable (previews, mocks).
    public var liveExtras: (any LiveSessionExtras)?
    /// Menu bar dictation toggle; `nil` where dictation is unavailable.
    public var dictation: DictationMenuControl?
    /// Meeting capture (record / transcribe a detected meeting); `nil` until the Meetings runtime (T23) is wired.
    public var meetingCapture: (any MeetingCapturing)?
    /// Live call scanning for the Meetings page ("Detect meetings"); `nil` where unavailable.
    public var meetingScanner: (any MeetingScanning)?
    /// Notification prompts for detected meetings; `nil` where unavailable (the inline banner is the fallback).
    public var meetingPrompts: (any MeetingPromptPresenting)?
    /// Voice profile storage; `nil` hides the voice profile controls.
    public var voiceProfiles: (any VoiceProfileRepository)?
    /// Embedding extraction for "Save voice profile"; `nil` disables saving from the Editor.
    public var speakerEmbeddings: (any SpeakerEmbeddingProvider)?
    /// Segment re-transcription with a language override (EDIT-AC-09); `nil` hides the action.
    public var segmentRetranscriber: (any SegmentRetranscriptionService)?
    /// Translation readiness and language-pack preparation; `nil` hides the Translate controls.
    public var translation: (any TranslationPreparing)?
    /// Folders, pins, notes, attachments, summaries and chat (SCR-018 to SCR-021).
    public var workspace: WorkspaceServices = .inMemory()

    public init(
        jobQueue: any JobQueue, transcripts: any TranscriptRepository, meetings: any MeetingRepository, models: any ModelManaging,
        live: any LiveSessionControlling, meetingDetector: any MeetingDetector, hardware: any HardwareTierProviding,
        permissions: any PermissionsServicing, audioDevices: any AudioDeviceProviding, settings: any SettingsStore,
        media: (any MediaRepository)? = nil, presets: (any PresetRepository)? = nil,
        liveExtras: (any LiveSessionExtras)? = nil, dictation: DictationMenuControl? = nil,
        meetingCapture: (any MeetingCapturing)? = nil, meetingScanner: (any MeetingScanning)? = nil, meetingPrompts: (any MeetingPromptPresenting)? = nil,
        voiceProfiles: (any VoiceProfileRepository)? = nil, speakerEmbeddings: (any SpeakerEmbeddingProvider)? = nil,
        segmentRetranscriber: (any SegmentRetranscriptionService)? = nil, translation: (any TranslationPreparing)? = nil,
        mediaRoots: @escaping @Sendable () async -> [URL] = { MediaFiles.defaultRoots }
    ) {
        self.mediaRoots = mediaRoots
        self.segmentRetranscriber = segmentRetranscriber
        self.translation = translation
        self.meetingCapture = meetingCapture
        self.meetingScanner = meetingScanner
        self.meetingPrompts = meetingPrompts
        self.voiceProfiles = voiceProfiles
        self.speakerEmbeddings = speakerEmbeddings
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
        self.liveExtras = liveExtras
        self.dictation = dictation
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
