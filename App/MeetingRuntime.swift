import AppCore
import EarmarkIntelligence
import AppKit
import AudioCapture
import Diarization
import FeatureSupport
import Foundation
import Jobs
import LiveCaptions
import Meetings
import ModelStore
import Persistence
import Transcription
import os

/// The meeting runtime of the composition root (T23 + T24 wiring).
///
/// Ownership of decisions stays with `MeetingsModel` (detection banner, prompt policy, notification responses, consent gate):
/// it subscribes to the detector and calls ``MeetingCaptureAdapter`` to start and stop. So `MeetingSessionController` is used
/// as the capture engine only (`startSession`/`stopSession`/`addBookmark`) and its own detector listener is not started,
/// otherwise every detection would act twice.
struct MeetingRuntime: Sendable {
    let detector: ProbeMeetingDetector
    let controller: MeetingSessionController
    let capture: MeetingCaptureAdapter
    let recordingsRoot: @Sendable () async -> URL
}

enum MeetingRuntimeFactory {
    /// - Parameter live: the orchestrator the session transcribes through (the same one the Live screen uses).
    static func make(
        database: AppDatabase, settings: any SettingsStore, permissions: any PermissionsServicing, jobs: any JobQueue,
        live: LiveSessionOrchestrator, prompts: (any MeetingPromptPresenting)?
    ) -> MeetingRuntime {
        let policies = MeetingPolicyStore(store: settings)
        let targets = MeetingCaptureTargets()
        // The end grace follows each app's policy (default 15 s), read when a meeting goes quiet.
        let detector = ProbeMeetingDetector(
            probe: CoreAudioMeetingProbe(context: AccessibilityMeetingContext()),
            config: MeetingDetectorConfig(endGrace: { app in await policies.policy(for: app).autoStopGraceSeconds }))
        let root: @Sendable () async -> URL = { await recordingsRoot(settings: settings) }
        let controller = MeetingSessionController(
            detector: detector, policies: policies, consent: MeetingConsentStore(store: settings),
            sources: SystemMeetingSources(permissions: permissions, settings: settings, targets: targets),
            // Video is opt-in (policy `recordVideo`): the recorder only starts it when the session asks for it, which is
            // when the policy allows it; Screen Recording permission is requested at that first start, never at launch.
            makeRecorder: { session in MeetingRecorder(session: session, video: ScreenCaptureVideoRecorder()) },
            recordingsRoot: root, meetings: database.meetings, jobs: jobs, live: live, transcripts: database.transcripts)
        let capture = MeetingCaptureAdapter(
            controller: controller, policies: policies, meetings: database.meetings, live: live, prompts: prompts, targets: targets)
        return MeetingRuntime(detector: detector, controller: controller, capture: capture, recordingsRoot: root)
    }

    /// `meetings.storageLocation`, else `<library location or Application Support/Earmark>/Meetings`.
    static func recordingsRoot(settings: any SettingsStore) async -> URL {
        let fm = FileManager.default
        if let custom = await settings.value(for: SettingsKey.meetingStorageLocation, as: String.self), !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        let library = await settings.value(for: SettingsKey.libraryLocation, as: String.self)
        let base =
            (library?.isEmpty == false ? URL(fileURLWithPath: library!, isDirectory: true) : nil)
            ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Earmark", isDirectory: true)
            ?? fm.temporaryDirectory.appendingPathComponent("Earmark", isDirectory: true)
        return base.appendingPathComponent("Meetings", isDirectory: true)
    }

    /// MTG-AC-12: finishes recordings a crash or quit left half-written, then queues one finalization job for each (unless
    /// the queue already holds one for that folder).
    ///
    /// Folders of the active (or starting) session and folders a pending or running finalization job already owns are
    /// skipped, so recovery cannot repair files a live recorder is writing or race `MeetingFinalizer` on `mix.m4a`.
    static func recover(root: URL, meetings: any MeetingRepository, jobs: any JobQueue, controller: MeetingSessionController) async {
        let recovered = await RecordingRecovery.recover(
            in: root, meetings: meetings,
            skipping: { directory in
                let target = directory.standardizedFileURL
                if await controller.activeRecordingDirectories.contains(where: { $0.standardizedFileURL == target }) { return true }
                return await jobs.jobs().contains {
                    $0.kind == .finalizeMeeting && [.pending, .running, .paused].contains($0.state) && $0.input?.standardizedFileURL == target
                }
            })
        guard !recovered.isEmpty else { return }
        let existing = await jobs.jobs().filter { $0.kind == .finalizeMeeting && $0.state != .cancelled }.compactMap(\.input)
        for item in recovered where !existing.contains(item.directory) {
            do {
                _ = try await jobs.enqueue(MeetingFinalizer.makeJob(directory: item.directory, liveTranscriptID: item.meeting.transcriptID))
            } catch {
                AppLog.logger("meetings.recovery").error("Could not queue finalization: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// MTG-AC-11: Settings' "show the notice" switch is flipped by the UI when the user acknowledges it; record when.
    static func followConsent(settings: any SettingsStore) {
        let store = MeetingConsentStore(store: settings)
        Task {
            for await _ in settings.changes(for: SettingsKey.meetingConsentNotice) {
                if await !store.needsNotice(), await store.acknowledgedAt() == nil { await store.recordAcknowledged() }
            }
        }
    }
}

// MARK: - Audio sources

/// Mic ("You") and the meeting app's own audio (a per-app Core Audio tap) for a session; sources are single use.
struct SystemMeetingSources: MeetingAudioSourceProviding {
    let permissions: any PermissionsServicing
    let settings: any SettingsStore
    /// The browser the user chose for a Meet or browser call (set just before the session starts).
    let targets: MeetingCaptureTargets

    /// The Meetings microphone override, else the global device, kept while it is unplugged: capture then falls back to the
    /// system default on its own and returns to the chosen device when it reappears.
    func preferredMicDeviceUID() async -> String? {
        await MicrophonePreference.deviceUID(for: .meetings, store: settings)
    }

    func micSource(deviceUID: String?) -> any AudioSource {
        MicrophoneSource(deviceUID: deviceUID, permissions: permissions)
    }

    func makeMicSource() async -> any AudioSource {
        MicrophoneSource(
            deviceUID: await preferredMicDeviceUID(), voiceProcessing: await MicrophonePreference.voiceProcessing(store: settings),
            permissions: permissions)
    }

    func remoteSource(for app: MeetingApp) -> any AudioSource {
        SystemAudioSource(target: .app(bundleID: Self.bundleID(for: app, chosen: targets.target(for: app))), permissions: permissions)
    }

    /// What to capture for `app`: the source the user picked, else the running app matching the product (Zoom, new or classic
    /// Teams, Discord stable/PTB/Canary), else for browser calls the browser using the microphone now.
    static func bundleID(for app: MeetingApp, chosen: String? = nil) -> String {
        if let chosen { return chosen }
        if app == .meet || app == .browser {
            return CoreAudioMeetingProbe.browserUsingMicrophone()?.captureBundleID ?? "com.google.Chrome"
        }
        let signature = MeetingAppSignature.defaults.first { $0.app == app }
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        if let match = running.first(where: { id in signature?.matches(id) == true && !Self.isHelper(id) }) { return match }
        switch app {
        case .zoom: return "us.zoom.xos"
        case .teams: return "com.microsoft.teams2"
        case .discord: return "com.hnc.Discord"
        case .meet, .browser: return "com.google.Chrome"
        }
    }

    private static func isHelper(_ id: String) -> Bool {
        id.contains("CptHost") || id.contains("caphost") || id.lowercased().contains(".helper")
    }
}

/// The source a user picked from Detect meetings, remembered until the session has started.
final class MeetingCaptureTargets: Sendable {
    private let values = OSAllocatedUnfairLock<[MeetingApp: String]>(initialState: [:])
    func set(_ bundleID: String?, for app: MeetingApp) { values.withLock { $0[app] = bundleID } }
    func target(for app: MeetingApp) -> String? { values.withLock { $0[app] } }
}

// MARK: - Capture adapter for the Meetings UI

/// Adapts `MeetingSessionController` to the UI's `MeetingCapturing` seam: start/stop, capture state, live lines, plus the
/// bookmark hotkey. Failures the controller reports as events (microphone, remote audio, recorder) become the thrown error
/// of `start` or a state the UI shows.
final class MeetingCaptureAdapter: MeetingCapturing, Sendable {
    private let targets: MeetingCaptureTargets
    private let controller: MeetingSessionController
    private let policies: MeetingPolicyStore
    private let meetings: any MeetingRepository
    private let live: LiveSessionOrchestrator
    private let prompts: (any MeetingPromptPresenting)?
    private let states = FeatureSupport.Broadcaster<MeetingCaptureState>()
    private let lastFailure = OSAllocatedUnfairLock<String?>(initialState: nil)
    private let current = OSAllocatedUnfairLock<MeetingCaptureState>(initialState: .idle)
    private let log = AppLog.logger("meetings.capture")

    init(
        controller: MeetingSessionController, policies: MeetingPolicyStore, meetings: any MeetingRepository,
        live: LiveSessionOrchestrator, prompts: (any MeetingPromptPresenting)?, targets: MeetingCaptureTargets
    ) {
        self.targets = targets
        self.controller = controller
        self.policies = policies
        self.meetings = meetings
        self.live = live
        self.prompts = prompts
        let events = controller.events()
        Task { [weak self] in
            for await event in events { await self?.handle(event) }
        }
    }

    // MARK: MeetingCapturing

    func start(app: MeetingApp, mode: MeetingCaptureMode) async throws {
        try await start(app: app, mode: mode, targetBundleID: nil)
    }

    func start(app: MeetingApp, mode: MeetingCaptureMode, targetBundleID: String?) async throws {
        targets.set(targetBundleID, for: app)
        lastFailure.withLock { $0 = nil }
        publish(.starting)
        let video = mode.recordsAudio ? await policies.policy(for: app).recordVideo : false
        await controller.startSession(app: app, transcribe: true, record: mode.recordsAudio, video: video)
        guard await controller.currentSession != nil else {
            let reason = lastFailure.withLock { $0 } ?? "The capture could not start. Check the microphone and audio permissions."
            publish(.failed(reason))
            throw AppError.other(reason)
        }
    }

    func stop() async -> TranscriptID? {
        publish(.stopping)
        let meetingID = await controller.currentSession?.meetingID
        await controller.stopSession()
        publish(.idle)
        guard let meetingID else { return nil }
        return try? await meetings.meetings().first { $0.id == meetingID }?.transcriptID
    }

    func state() -> AsyncStream<MeetingCaptureState> { states.stream(initial: current.withLock { $0 }) }
    func lines() -> AsyncStream<[CaptionLine]> { live.lines() }

    /// `HotkeyAction.bookmarkMoment` (MTG-AC-14): a bookmark at the current time of the running capture.
    func addBookmark(note: String = "") async { await controller.addBookmark(note: note) }

    // MARK: Controller events

    private func publish(_ state: MeetingCaptureState) {
        current.withLock { $0 = state }
        states.send(state)
    }

    private func handle(_ event: MeetingSessionEvent) async {
        switch event {
        case .sessionStarted(let info):
            publish(
                .capturing(info.app, mode: info.recording ? .transcribeAndRecord : .transcribeOnly, since: info.startedAt))
        case .sessionEnded: publish(.idle)
        case .consentNoticeRequired:
            // `MeetingsModel` owns the consent gate (blocking notice for a manual Record, one-time reminder for an automatic
            // one), so the controller's event is only logged here.
            log.info("recording started before the consent notice was acknowledged")
        case .recordingFailed(let reason), .failed(let reason):
            lastFailure.withLock { $0 = reason }
            log.error("meeting capture problem: \(reason, privacy: .public)")
        case .remoteAudioUnavailable(let reason):
            // Mic-only still works; the Meetings screen shows the capture as running, the log keeps the reason.
            log.error("remote audio unavailable: \(reason, privacy: .public)")
        default: break
        }
    }
}

// MARK: - Voice profile matching

/// `VoiceProfileMatching` over the Diarization package's calibrated matcher (auto-apply at 0.25, suggestion at 0.35).
struct DiarizationVoiceMatcher: VoiceProfileMatching {
    var matcher = VoiceProfileMatcher()

    func match(_ evidence: [SpeakerSlotEvidence], profiles: [VoiceProfile]) -> [VoiceProfileMatch] {
        let clusters = evidence.map { SpeakerCluster(slot: $0.slot, embedding: $0.embedding, speechSeconds: $0.speechSeconds) }
        let names = Dictionary(profiles.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return matcher.matches(clusters: clusters, profiles: profiles).map {
            VoiceProfileMatch(
                slot: $0.slot, profileID: $0.profile, name: names[$0.profile] ?? "", distance: $0.distance, isAuto: $0.confidence == .auto)
        }
    }
}

// MARK: - Finalization job

/// The `.finalizeMeeting` job handler (MTG-AC-15): rebuilds the input from the recording folder and runs
/// `MeetingFinalizer`, choosing the engine for the user's language setting like a file job does.
struct MeetingFinalization: Sendable {
    let database: AppDatabase
    let models: any ModelManaging
    let hardware: any HardwareTierProviding
    let settings: any SettingsStore
    let whisper: WhisperKitEngine
    let engines: [EngineID: any TranscriptionEngine]
    let diarizer: any Diarizer
    let embeddings: any SpeakerEmbeddingProvider
    let router: any EngineRouter

    var handler: JobHandler {
        { context in
            let (engine, config) = try await prepare()
            let finalizer = MeetingFinalizer(
                dependencies: FinalizerDependencies(
                    engine: engine, diarizer: diarizer, embeddings: embeddings, matcher: DiarizationVoiceMatcher(),
                    transcripts: database.transcripts, meetings: database.meetings, media: database.media,
                    voiceProfiles: database.voiceProfiles, models: models, workspace: database.notes),
                config: config)
            let progress = finalizer.progress()
            let follower = Task {
                for await step in progress { await context.progress(step.fraction) }
            }
            defer { follower.cancel() }
            let result = try await finalizer.run(job: context.job)
            let draft = result.meeting.transcriptID
            Task { await autoSummarize(result.transcriptID, draft: draft) }
            return JobHandlerResult(
                transcriptID: result.transcriptID, title: MeetingFinalizer.title(for: result.meeting))
        }
    }

    /// "Summarise automatically when a meeting finishes" (off by default): writes the summary into the notes, keeping whatever
    /// was on the page as a version. Quietly does nothing when Apple Intelligence or the language is not available.
    private func autoSummarize(_ id: TranscriptID, draft: TranscriptID?) async {
        guard await settings.value(for: SettingsKey.intelligenceAutoSummarize, as: Bool.self) == true else { return }
        let service = IntelligenceService(transcripts: database.transcripts, attachments: database.attachments)
        guard await service.availability().isAvailable else { return }
        let existing = try? await database.notes.notes(for: id)
        let includeNotes = await settings.value(for: SettingsKey.intelligenceIncludeNotes, as: Bool.self) ?? true
        let includeFiles = await settings.value(for: SettingsKey.intelligenceIncludeFiles, as: Bool.self) ?? true
        let request = SummaryRequest(
            transcriptID: id, style: .meeting, notesMarkdown: existing?.markdown ?? "", includeNotes: includeNotes, includeFiles: includeFiles)
        do {
            for try await event in service.summarize(request) {
                guard case .finished(let markdown) = event else { continue }
                if let existing, !existing.markdown.isEmpty {
                    try await database.notes.save(NotesVersion(transcriptID: id, markdown: existing.markdown, reason: .beforeSummary))
                }
                try await database.notes.save(
                    TranscriptNotes(transcriptID: id, markdown: markdown, updatedAt: Date(), summarizedAt: Date(), summaryStyle: .meeting))
            }
        } catch {
            AppLog.logger("meetings.autosummary").error("Automatic summary skipped: \(String(describing: error), privacy: .public)")
        }
    }

    private func prepare() async throws -> (any TranscriptionEngine, FinalizationConfig) {
        let mode = await settings.value(for: SettingsKey.languageMode, as: LanguageMode.self) ?? .default
        let explicit = await PreferredModel.explicitID(for: .file, settings: settings)
        let request = RoutingRequest(
            languageMode: mode, useCase: .file, tier: hardware.profile.tier, installedModels: await models.installedModels(),
            explicitModel: explicit)
        let plan = try await router.preparedPlan(for: request)
        let vocabulary = await settings.value(for: SettingsKey.customVocabulary, as: [String].self) ?? []
        guard let first = plan.assignments.first else { throw AppError.other("No engine is available to transcribe the meeting.") }
        var config = FinalizationConfig(languageMode: mode, modelID: first.model, vocabulary: vocabulary)
        if Set(plan.assignments.map(\.engine)).count > 1, case .multilingual(let set) = mode {
            // Per-language engines (for example English on Whisper and Sinhala on Qwen): one multilingual engine routes them.
            let resolver = LanguageEngineResolver.make(
                router: router, basePlan: plan, useCase: .file, tier: hardware.profile.tier, explicitModel: explicit,
                installed: { [models] in await models.installedModels() }, engines: engines)
            config.modelID = nil
            let identifier = WhisperLanguageIdentifier(engine: whisper, model: RoutingTargets.whisperSmall)
            return (MultilingualEngine(languages: set, resolver: resolver, identifier: identifier), config)
        }
        guard let engine = engines[first.engine] else {
            throw AppError.engineFailure(first.engine, reason: "Engine is not available in this build.")
        }
        return (engine, config)
    }
}
