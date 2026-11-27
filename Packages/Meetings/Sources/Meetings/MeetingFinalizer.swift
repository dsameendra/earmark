import AppCore
import Foundation

public enum FinalizationStage: String, Sendable, Equatable {
    case preparing, transcribingMic, transcribingRemote, diarizing, matchingVoices, saving, done
}

public struct FinalizationProgress: Sendable, Equatable {
    public var stage: FinalizationStage
    public var fraction: Double
}

public enum FinalizationWarning: Sendable, Equatable {
    case modelUnavailable(reason: String)
    case retranscriptionFailed(track: RecordingTrack.Role, reason: String)
    /// Both tracks failed offline; the live transcript was kept.
    case usedLiveTranscript
    case diarizationFailed(reason: String)
    case voiceMatchingFailed(reason: String)
}

public enum FinalizationError: Error, Equatable, Sendable {
    case noAudio
    case transcriptionFailed(String)
    case meetingNotFound(MeetingID)
    case missingRecordingDirectory
}

public struct VoiceSuggestion: Sendable, Equatable {
    public var speakerID: SpeakerID
    public var profileID: VoiceProfileID
    public var name: String
    public var distance: Double
}

public struct FinalizationConfig: Sendable {
    public var languageMode: LanguageMode
    /// Best available model for offline re-transcription (resolve via the engine router at the call site); `nil` = auto.
    public var modelID: ModelID?
    public var vocabulary: [String]
    public var diarization: DiarizationOptions
    public var dedupeEcho: Bool
    public var userSpeakerName: String
    public var minSpeechForVoiceMatch: TimeInterval
    public init(
        languageMode: LanguageMode = .default, modelID: ModelID? = nil, vocabulary: [String] = [],
        diarization: DiarizationOptions = DiarizationOptions(), dedupeEcho: Bool = true, userSpeakerName: String = "You",
        minSpeechForVoiceMatch: TimeInterval = 2
    ) {
        self.languageMode = languageMode
        self.modelID = modelID
        self.vocabulary = vocabulary
        self.diarization = diarization
        self.dedupeEcho = dedupeEcho
        self.userSpeakerName = userSpeakerName
        self.minSpeechForVoiceMatch = minSpeechForVoiceMatch
    }
}

/// What the live pass produced, so the offline pass can keep the user's speaker names and edits stable.
public struct LiveContext: Sendable {
    public var transcriptID: TranscriptID?
    public var liveTurns: [SpeakerTurn]
    /// Live diarization slot to the (possibly user-renamed) speaker.
    public var liveSpeakers: [Int: Speaker]
    public var youSpeaker: Speaker?
    public init(
        transcriptID: TranscriptID? = nil, liveTurns: [SpeakerTurn] = [], liveSpeakers: [Int: Speaker] = [:], youSpeaker: Speaker? = nil
    ) {
        self.transcriptID = transcriptID
        self.liveTurns = liveTurns
        self.liveSpeakers = liveSpeakers
        self.youSpeaker = youSpeaker
    }
}

public struct FinalizationInput: Sendable {
    public var meeting: Meeting
    /// Folder holding the track files (`Recording` track paths are resolved by file name inside it).
    public var recordingDirectory: URL
    public var recording: Recording
    public var live: LiveContext?
    public var bookmarks: [RecordingManifest.Bookmark]
    public init(
        meeting: Meeting, recordingDirectory: URL, recording: Recording, live: LiveContext? = nil,
        bookmarks: [RecordingManifest.Bookmark] = []
    ) {
        self.meeting = meeting
        self.recordingDirectory = recordingDirectory
        self.recording = recording
        self.live = live
        self.bookmarks = bookmarks
    }
}

public struct FinalizationResult: Sendable {
    public var meeting: Meeting
    public var transcriptID: TranscriptID
    public var warnings: [FinalizationWarning]
    public var voiceSuggestions: [VoiceSuggestion]
    public var droppedEchoSegments: Int
}

public struct FinalizerDependencies: Sendable {
    public var engine: any TranscriptionEngine
    public var diarizer: (any Diarizer)?
    public var embeddings: (any SpeakerEmbeddingProvider)?
    public var matcher: any VoiceProfileMatching
    public var transcripts: any TranscriptRepository
    public var meetings: any MeetingRepository
    public var media: any MediaRepository
    public var voiceProfiles: (any VoiceProfileRepository)?
    public var models: (any ModelManaging)?
    /// Notes, files and chat a user added to the live draft move to the final transcript (SCR-019).
    public var workspace: (any NotesRepository)?
    public init(
        engine: any TranscriptionEngine, diarizer: (any Diarizer)? = nil, embeddings: (any SpeakerEmbeddingProvider)? = nil,
        matcher: any VoiceProfileMatching = DistanceVoiceProfileMatcher(), transcripts: any TranscriptRepository,
        meetings: any MeetingRepository, media: any MediaRepository, voiceProfiles: (any VoiceProfileRepository)? = nil,
        models: (any ModelManaging)? = nil, workspace: (any NotesRepository)? = nil
    ) {
        self.workspace = workspace
        self.engine = engine
        self.diarizer = diarizer
        self.embeddings = embeddings
        self.matcher = matcher
        self.transcripts = transcripts
        self.meetings = meetings
        self.media = media
        self.voiceProfiles = voiceProfiles
        self.models = models
    }
}

/// The post-meeting pass (MTG-AC-15). Order: persist the recording on the meeting, ensure the best model, offline
/// re-transcription of the mic track then the remote track, offline diarization of the remote track, live-to-offline
/// speaker reconciliation, voice-profile matching, cross-track echo de-duplication, save. Only a failure of every
/// transcription path or of persistence fails the job; a failing diarizer, matcher or one track degrades with a warning.
public actor MeetingFinalizer {
    private let deps: FinalizerDependencies
    private let config: FinalizationConfig
    private let jobBroadcaster = Broadcaster<JobEvent>()
    private let progressBroadcaster = Broadcaster<FinalizationProgress>()
    private let log = AppLog.logger("meetings.finalizer")
    private var job = Job(kind: .finalizeMeeting)

    private static let palette = ["#FF9F0A", "#30D158", "#BF5AF2", "#FF453A", "#64D2FF", "#FFD60A"]
    private static let youColor = "#0A84FF"

    public init(dependencies: FinalizerDependencies, config: FinalizationConfig = FinalizationConfig()) {
        self.deps = dependencies
        self.config = config
    }

    /// `JobQueue`-compatible progress: `.updated(Job)` snapshots of a `.finalizeMeeting` job.
    public nonisolated func jobEvents() -> AsyncStream<JobEvent> { jobBroadcaster.stream() }
    public nonisolated func progress() -> AsyncStream<FinalizationProgress> { progressBroadcaster.stream() }

    /// A `.finalizeMeeting` job whose `input` is the recording folder (it holds `meeting.json`).
    public static func makeJob(directory: URL, liveTranscriptID: TranscriptID?, settings: JobSettings = JobSettings(diarize: true)) -> Job {
        Job(kind: .finalizeMeeting, input: directory, transcriptID: liveTranscriptID, settings: settings, priority: 10)
    }

    /// Runs a queued job: rebuilds the input from the recording folder's manifest and the meeting repository.
    public func run(job queued: Job) async throws -> FinalizationResult {
        guard let directory = queued.input else { throw FinalizationError.missingRecordingDirectory }
        var manifest = try RecordingManifest.read(from: directory)
        if manifest.state != .finalized {
            let outcome = RecordingFinisher.finish(directory: directory, manifest: manifest)
            manifest = outcome.manifest
        }
        let stored = try await deps.meetings.meetings().first { $0.id == manifest.meetingID }
        let recording = Recording(
            tracks: manifest.tracks.map { RecordingTrack(role: $0.role, relativePath: ($0.relativePath as NSString).lastPathComponent) },
            duration: manifest.duration)
        let meeting = stored ?? Meeting(id: manifest.meetingID, app: manifest.app, startedAt: manifest.startedAt, recording: recording)
        let published = stored?.recording ?? recording
        return try await finalize(
            FinalizationInput(
                meeting: meeting, recordingDirectory: directory, recording: published,
                live: LiveContext(transcriptID: queued.transcriptID), bookmarks: manifest.bookmarks),
            jobID: queued.id)
    }

    public func finalize(_ input: FinalizationInput, jobID: JobID = JobID()) async throws -> FinalizationResult {
        job = Job(
            id: jobID, kind: .finalizeMeeting, state: .running, input: input.recordingDirectory, transcriptID: input.live?.transcriptID,
            settings: JobSettings(languageMode: config.languageMode, modelID: config.modelID, diarize: true), engine: deps.engine.id)
        report(.preparing, 0)
        do {
            let result = try await perform(input)
            job.state = .completed
            job.progress = 1
            job.transcriptID = result.transcriptID
            report(.done, 1)
            return result
        } catch {
            let cancelled = error is CancellationError || (error as? AppError) == .cancelled
            job.state = cancelled ? .cancelled : .failed
            job.failureReason = cancelled ? nil : String(describing: error)
            jobBroadcaster.send(.updated(job))
            log.error(
                "finalization \(cancelled ? "cancelled" : "failed", privacy: .public): \(String(describing: error), privacy: .public)")
            if cancelled { throw AppError.cancelled }
            throw error
        }
    }

    // MARK: Pipeline

    private func perform(_ input: FinalizationInput) async throws -> FinalizationResult {
        var warnings: [FinalizationWarning] = []
        var meeting = input.meeting
        meeting.endedAt = meeting.endedAt ?? meeting.startedAt.addingTimeInterval(input.recording.duration)
        meeting.recording = input.recording
        // 0. The recording is safe on the meeting before any slow step, so a failure later never loses it.
        try await deps.meetings.save(meeting)

        let fm = FileManager.default
        func file(_ role: RecordingTrack.Role) -> URL? {
            guard let track = input.recording.tracks.first(where: { $0.role == role }) else { return nil }
            let url = input.recordingDirectory.appendingPathComponent((track.relativePath as NSString).lastPathComponent)
            return fm.fileExists(atPath: url.path) ? url : nil
        }
        let micURL = file(.mic)
        let remoteURL = file(.remote)
        let mixURL = file(.mix)
        // With a mix-only library (separate tracks disabled) the mix is transcribed as the remote lane.
        let remoteSource = remoteURL ?? (micURL == nil ? mixURL : nil)
        guard micURL != nil || remoteSource != nil else { throw FinalizationError.noAudio }
        try Task.checkCancellation()

        // 1. Best model.
        let modelID = try await prepareModel(&warnings)
        try Task.checkCancellation()

        // 2. Offline re-transcription, mic then remote. Auto-detect on a short clip can pick the wrong language (English
        // speech came back in Devanagari), so a language the live pass already settled on is kept.
        var liveLanguages: [LanguageCode?] = []
        if let liveID = input.live?.transcriptID, let live = try? await deps.transcripts.segments(for: liveID) {
            liveLanguages = live.filter { !$0.isIgnored }.map(\.languageCode)
        }
        let languageMode = Self.resolvedLanguageMode(config.languageMode, liveLanguages: liveLanguages)
        var micSegments: [Segment]?
        var remoteSegments: [Segment]?
        if let micURL {
            do { micSegments = try await transcribe(micURL, model: modelID, mode: languageMode, stage: .transcribingMic, from: 0.05, to: 0.30) } catch {
                if error is CancellationError { throw error }
                warnings.append(.retranscriptionFailed(track: .mic, reason: String(describing: error)))
            }
        }
        if let remoteSource {
            do {
                remoteSegments = try await transcribe(remoteSource, model: modelID, mode: languageMode, stage: .transcribingRemote, from: 0.30, to: 0.70)
            } catch {
                if error is CancellationError { throw error }
                warnings.append(.retranscriptionFailed(track: .remote, reason: String(describing: error)))
            }
        }
        var liveFallback: [Segment]?
        if micSegments == nil, remoteSegments == nil {
            guard let liveID = input.live?.transcriptID, let live = try? await deps.transcripts.segments(for: liveID), !live.isEmpty else {
                throw FinalizationError.transcriptionFailed(
                    warnings.compactMap { if case .retranscriptionFailed(_, let r) = $0 { r } else { nil } }.joined(separator: "; "))
            }
            liveFallback = live
            warnings.append(.usedLiveTranscript)
        }
        try Task.checkCancellation()

        // 3. Offline diarization of the remote track.
        var turns: [SpeakerTurn] = []
        var offlineTurns = false
        if let remoteSource, remoteSegments != nil, let diarizer = deps.diarizer {
            report(.diarizing, 0.70)
            do {
                turns = try await diarizer.diarize(file: remoteSource, options: config.diarization)
                offlineTurns = true
            } catch {
                if error is CancellationError { throw error }
                warnings.append(.diarizationFailed(reason: String(describing: error)))
            }
        }
        if !offlineTurns, let live = input.live, !live.liveTurns.isEmpty { turns = live.liveTurns }
        try Task.checkCancellation()

        // 4. Reconcile live slots with the offline pass and build the speakers.
        let reconciled = offlineTurns ? SpeakerReconciler.mapLiveSlots(live: input.live?.liveTurns ?? [], offline: turns) : [:]
        var slotSpeakers = buildSpeakers(
            turns: turns, live: input.live,
            liveToSlot: offlineTurns ? reconciled : Dictionary(uniqueKeysWithValues: Set(turns.map(\.slot)).map { ($0, $0) }))

        // 5. Voice profiles for speakers nobody has named yet.
        var suggestions: [VoiceSuggestion] = []
        if offlineTurns, let remoteSource {
            report(.matchingVoices, 0.85)
            do {
                suggestions = try await matchVoices(turns: turns, remoteURL: remoteSource, slotSpeakers: &slotSpeakers)
            } catch {
                if error is CancellationError { throw error }
                warnings.append(.voiceMatchingFailed(reason: String(describing: error)))
            }
        }
        try Task.checkCancellation()

        // 6. Assemble: label by track, drop echo, order by time.
        let you = input.live?.youSpeaker ?? Speaker(name: config.userSpeakerName, colorHex: Self.youColor)
        var assembly = assemble(
            mic: micSegments, remote: remoteSegments, liveFallback: liveFallback, turns: turns, slotSpeakers: &slotSpeakers, you: you)
        if liveFallback != nil, let liveID = input.live?.transcriptID {
            assembly.speakers = (try? await deps.transcripts.transcript(liveID))?.speakers ?? []
        }

        // 7. Save: media, transcript header, segments, bookmarks, then link the meeting.
        report(.saving, 0.92)
        let finalID = try await persist(&meeting, input: input, assembly: assembly)
        return FinalizationResult(
            meeting: meeting, transcriptID: finalID, warnings: warnings, voiceSuggestions: suggestions,
            droppedEchoSegments: assembly.droppedEcho)
    }

    private struct Assembly {
        var segments: [Segment]
        var speakers: [Speaker]
        var droppedEcho: Int
    }

    private func assemble(
        mic micSegments: [Segment]?, remote remoteSegments: [Segment]?, liveFallback: [Segment]?, turns: [SpeakerTurn],
        slotSpeakers: inout [Int: SlotSpeaker], you: Speaker
    ) -> Assembly {
        if let liveFallback { return Assembly(segments: liveFallback, speakers: [], droppedEcho: 0) }
        var mic = (micSegments ?? []).map { segment -> Segment in
            var s = segment
            s.speakerID = you.id
            return s
        }
        let remote = remoteSegments ?? []
        var dropped = 0
        if config.dedupeEcho, !mic.isEmpty, !remote.isEmpty {
            let result = EchoDeduper.dedupe(mic: mic, remote: remote)
            mic = result.kept
            dropped = result.dropped.count
        }
        let fallbackSlot = slotSpeakers.keys.min()
        var labelled: [Segment] = []
        for segment in remote {
            var s = segment
            let slot = SpeakerAssigner.slot(for: s.range, turns: turns) ?? fallbackSlot ?? 0
            if slotSpeakers[slot] == nil { slotSpeakers[slot] = defaultSpeaker(slot: slot, ordinal: slotSpeakers.count) }
            s.speakerID = slotSpeakers[slot]?.speaker.id
            labelled.append(s)
        }
        let segments = (mic + labelled).sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        let usedIDs = Set(segments.compactMap(\.speakerID))
        var speakers: [Speaker] = mic.isEmpty ? [] : [you]
        speakers += slotSpeakers.sorted { $0.key < $1.key }.map(\.value.speaker).filter { usedIDs.contains($0.id) }
        return Assembly(segments: segments, speakers: speakers, droppedEcho: dropped)
    }

    private func persist(_ meeting: inout Meeting, input: FinalizationInput, assembly: Assembly) async throws -> TranscriptID {
        let finalID = Self.finalTranscriptID(meeting: meeting, live: input.live)
        let assetTrack = [RecordingTrack.Role.mix, .remote, .mic].lazy
            .compactMap { role in input.recording.tracks.first { $0.role == role } }.first
        var assetID: MediaAssetID?
        if let assetTrack {
            let asset = MediaAsset(
                kind: .audio, libraryRelativePath: assetTrack.relativePath, duration: input.recording.duration, isOwnedByLibrary: true)
            try await deps.media.save(asset)
            assetID = asset.id
        }
        let languages = Set(assembly.segments.compactMap(\.languageCode))
        let transcript = Transcript(
            id: finalID, title: Self.title(for: meeting), source: .meeting, duration: input.recording.duration,
            languages: languages.isEmpty ? Self.languages(of: config.languageMode) : languages, speakers: assembly.speakers,
            mediaAssetID: assetID, meetingID: meeting.id,
            revisionOf: input.live?.transcriptID.flatMap { $0 == finalID ? nil : $0 }, createdAt: meeting.startedAt, modifiedAt: Date())
        try await deps.transcripts.save(transcript)
        try await deps.transcripts.replaceSegments(assembly.segments, for: finalID)
        // Notes, slides and chat written during the meeting belong to the final transcript now; the live draft is hidden.
        if let draft = input.live?.transcriptID, draft != finalID { try? await deps.workspace?.moveWorkspace(from: draft, to: finalID) }
        for bookmark in input.bookmarks {
            try await deps.transcripts.save(TranscriptBookmark(transcriptID: finalID, time: bookmark.time, note: bookmark.note))
        }
        meeting.transcriptID = finalID
        try await deps.meetings.save(meeting)
        return finalID
    }

    // MARK: Pieces

    /// Ensures and loads the configured model; on failure falls back to automatic selection (`nil`) with a warning.
    private func prepareModel(_ warnings: inout [FinalizationWarning]) async throws -> ModelID? {
        guard let model = config.modelID else { return nil }
        do {
            if let models = deps.models {
                for try await event in models.ensureAvailable(model) {
                    if case .progress(let fraction, _, _) = event { report(.preparing, 0.05 * fraction) }
                }
            }
            try await deps.engine.prepare(model: model)
            return model
        } catch {
            if error is CancellationError { throw error }
            warnings.append(.modelUnavailable(reason: String(describing: error)))
            return nil
        }
    }

    private func matchVoices(
        turns: [SpeakerTurn], remoteURL: URL, slotSpeakers: inout [Int: SlotSpeaker]
    ) async throws -> [VoiceSuggestion] {
        guard let embeddings = deps.embeddings, let profilesRepo = deps.voiceProfiles else { return [] }
        let profiles = try await profilesRepo.profiles()
        guard !profiles.isEmpty else { return [] }
        let evidence = try await slotEvidence(
            turns: turns, remoteURL: remoteURL, embeddings: embeddings, skipping: slotSpeakers.filter { $0.value.carried })
        var suggestions: [VoiceSuggestion] = []
        for match in deps.matcher.match(evidence, profiles: profiles) {
            guard var entry = slotSpeakers[match.slot] else { continue }
            if match.isAuto {
                entry.speaker.name = match.name
                entry.speaker.voiceProfileID = match.profileID
                slotSpeakers[match.slot] = entry
            } else {
                suggestions.append(
                    VoiceSuggestion(speakerID: entry.speaker.id, profileID: match.profileID, name: match.name, distance: match.distance))
            }
        }
        return suggestions
    }

    private func transcribe(_ url: URL, model: ModelID?, mode: LanguageMode, stage: FinalizationStage, from: Double, to: Double) async throws -> [Segment] {
        var segments: [Segment] = []
        let options = TranscriptionOptions(
            languageMode: mode, useCase: .file, modelID: model, vocabulary: config.vocabulary, wordTimestamps: true)
        report(stage, from)
        for try await event in deps.engine.transcribe(file: url, options: options) {
            switch event {
            case .final(let segment): segments.append(segment)
            case .progress(let fraction, _): report(stage, from + (to - from) * min(max(fraction, 0), 1))
            case .partial, .languageDetected: break
            }
        }
        return segments
    }

    private struct SlotSpeaker {
        var speaker: Speaker
        var carried: Bool
    }

    private func defaultSpeaker(slot: Int, ordinal: Int) -> SlotSpeaker {
        SlotSpeaker(
            speaker: Speaker(name: "Speaker \(ordinal + 1)", colorHex: Self.palette[ordinal % Self.palette.count]), carried: false)
    }

    /// "Speaker N" by order of first appearance; a user-renamed live speaker keeps its identity on the matching offline slot.
    private func buildSpeakers(turns: [SpeakerTurn], live: LiveContext?, liveToSlot: [Int: Int]) -> [Int: SlotSpeaker] {
        var firstSeen: [Int: TimeInterval] = [:]
        for turn in turns { firstSeen[turn.slot] = min(firstSeen[turn.slot] ?? .infinity, turn.range.start) }
        let ordered = firstSeen.sorted { ($0.value, $0.key) < ($1.value, $1.key) }.map(\.key)
        var out: [Int: SlotSpeaker] = [:]
        for (ordinal, slot) in ordered.enumerated() { out[slot] = defaultSpeaker(slot: slot, ordinal: ordinal) }
        if let live {
            for (liveSlot, offlineSlot) in liveToSlot.sorted(by: { $0.key < $1.key }) {
                guard let speaker = live.liveSpeakers[liveSlot], out[offlineSlot]?.carried == false, Self.isUserNamed(speaker) else {
                    continue
                }
                out[offlineSlot] = SlotSpeaker(speaker: speaker, carried: true)
            }
        }
        return out
    }

    private func slotEvidence(
        turns: [SpeakerTurn], remoteURL: URL, embeddings: any SpeakerEmbeddingProvider, skipping carried: [Int: SlotSpeaker]
    ) async throws -> [SpeakerSlotEvidence] {
        var seconds: [Int: TimeInterval] = [:]
        var longest: [Int: TimeRange] = [:]
        for turn in turns {
            seconds[turn.slot, default: 0] += turn.range.duration
            if turn.range.duration > (longest[turn.slot]?.duration ?? 0) { longest[turn.slot] = turn.range }
        }
        var out: [SpeakerSlotEvidence] = []
        for (slot, total) in seconds.sorted(by: { $0.key < $1.key }) where carried[slot] == nil && total >= config.minSpeechForVoiceMatch {
            guard var range = longest[slot] else { continue }
            range.end = min(range.end, range.start + 30)
            out.append(
                SpeakerSlotEvidence(
                    slot: slot, embedding: try await embeddings.embedding(file: remoteURL, range: range), speechSeconds: total))
        }
        return out
    }

    static func isUserNamed(_ speaker: Speaker) -> Bool {
        speaker.voiceProfileID != nil || speaker.name.range(of: #"^Speaker \d+$"#, options: .regularExpression) == nil
    }

    /// A retry reuses the transcript a previous run linked to the meeting; otherwise a new revision of the live one.
    static func finalTranscriptID(meeting: Meeting, live: LiveContext?) -> TranscriptID {
        if let existing = meeting.transcriptID, existing != live?.transcriptID { return existing }
        return TranscriptID()
    }

    /// With auto-detect, a live pass that heard exactly one language fixes the offline pass to it. Any other setting, or a live
    /// pass that heard several languages or none, is left as the user set it.
    static func resolvedLanguageMode(_ mode: LanguageMode, liveLanguages: [LanguageCode?]) -> LanguageMode {
        guard case .autoDetect = mode else { return mode }
        let heard = Set(liveLanguages.compactMap { $0 })
        guard heard.count == 1, let only = heard.first else { return mode }
        return .single(only)
    }

    static func languages(of mode: LanguageMode) -> Set<LanguageCode> {
        switch mode {
        case .single(let language): [language]
        case .multilingual(let set): set
        case .autoDetect: []
        }
    }

    public static func title(for meeting: Meeting) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "\(titleName(for: meeting.app)), \(formatter.string(from: meeting.startedAt))"
    }

    /// "Zoom meeting", "Discord meeting", "Google Meet", "Browser call": the service, without repeating "meeting" for names
    /// that already say what they are.
    static func titleName(for app: MeetingApp) -> String {
        let name = ProbeMeetingDetector.name(of: app)
        switch app {
        case .zoom, .teams, .discord: return "\(name) meeting"
        case .meet, .browser: return name
        }
    }

    private func report(_ stage: FinalizationStage, _ fraction: Double) {
        job.progress = min(max(fraction, 0), 1)
        jobBroadcaster.send(.updated(job))
        progressBroadcaster.send(FinalizationProgress(stage: stage, fraction: job.progress))
    }
}
