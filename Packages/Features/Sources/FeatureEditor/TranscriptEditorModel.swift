import AppCore
import FeatureSupport
import Foundation
import Observation
import Processing

/// Consecutive same-speaker segments shown as one block in the paragraph view.
public struct TranscriptParagraph: Identifiable, Sendable, Hashable {
    public var segments: [Segment]
    public var id: SegmentID { segments[0].id }
    public var speakerID: SpeakerID? { segments[0].speakerID }
    public var start: TimeInterval { segments[0].start }
    public var languageCode: LanguageCode? { segments[0].languageCode }
}

public enum ParagraphBuilder {
    /// Segments of one speaker no further apart than `gap` seconds form a paragraph.
    public static func make(from segments: [Segment], gap: TimeInterval = 2) -> [TranscriptParagraph] {
        var out: [TranscriptParagraph] = []
        for segment in segments {
            if var last = out.last, last.segments.last?.speakerID == segment.speakerID,
                segment.start - (last.segments.last?.end ?? 0) <= gap, !(last.segments.last?.isIgnored ?? false) || segment.isIgnored
            {
                last.segments.append(segment)
                out[out.count - 1] = last
            } else {
                out.append(TranscriptParagraph(segments: [segment]))
            }
        }
        return out
    }
}

/// A request for the transcript view to scroll to a segment (find results, bookmarks, "return to playhead").
public struct RevealRequest: Equatable, Sendable {
    public var segmentID: SegmentID
    public var token = UUID()
}

/// The transcript editor's state and editing operations (EDIT-AC-06...08, 10, 12...14, 18).
///
/// Edits are applied in memory immediately (so typing is never blocked) and persisted incrementally and serially
/// through `TranscriptRepository` (EDIT-AC-18).
@MainActor @Observable
public final class TranscriptEditorModel {
    public enum LoadState: Equatable {
        case loading, loaded
        case failed(String)
    }

    public let transcriptID: TranscriptID
    public private(set) var loadState: LoadState = .loading
    public private(set) var transcript: Transcript?
    public private(set) var segments: [Segment] = [] { didSet { rebuildDerived() } }
    public private(set) var visibleSegments: [Segment] = []
    public private(set) var paragraphs: [TranscriptParagraph] = []
    /// Paragraph ID for each segment (paragraph view scrolling), empty in segment view.
    public private(set) var paragraphIDBySegment: [SegmentID: SegmentID] = [:]
    public private(set) var showWaveform = true
    public private(set) var listFocusToken = 0
    /// Speaker-coloured regions for the scrubber, rebuilt only when segments change.
    public private(set) var speakerRegions: [SpeakerRegion] = []
    public internal(set) var bookmarks: [TranscriptBookmark] = []
    public internal(set) var highlights: [TextHighlight] = []
    public private(set) var persistenceError: String?
    /// Unseen live-to-offline speaker relabel (DIA-AC-06); `nil` once acknowledged or when nothing changed.
    public internal(set) var reconciliation: ReconciliationReport?
    /// The resolved media file (used to extract a voice embedding).
    public internal(set) var mediaURL: URL?
    public internal(set) var voiceProfileError: String?
    /// Voice profile storage and embedding extraction; `nil` hides the voice profile controls.
    @ObservationIgnored public var voiceProfiles: (any VoiceProfileRepository)?
    @ObservationIgnored public var embeddings: (any SpeakerEmbeddingProvider)?
    /// Re-transcription with a language override (EDIT-AC-09); `nil` hides the action.
    @ObservationIgnored public var retranscriber: (any SegmentRetranscriptionService)?
    /// Translation readiness and pack preparation; `nil` hides the Translate controls.
    @ObservationIgnored public var translationService: (any TranslationPreparing)?
    @ObservationIgnored public var jobQueue: (any JobQueue)?
    @ObservationIgnored public var models: (any ModelManaging)?
    /// How translations are shown (TRN-AC-08) and the language of the shown track.
    public internal(set) var translationChoice = TranslationDisplayChoice()
    /// Segments edited after their translation was made (TRN-AC-10).
    public internal(set) var staleTranslations: Set<SegmentID> = []
    /// Segments being re-transcribed right now.
    public internal(set) var retranscribing: Set<SegmentID> = []
    /// Replaced content kept by re-transcription (LANG-AC-08).
    public internal(set) var revisions: [SegmentRevision] = []
    public internal(set) var languageError: String?
    /// State of the running translate job, shown in the toolbar popover.
    public internal(set) var translationJob: Job?
    public internal(set) var translationStatus: String?
    @ObservationIgnored var translationWatcher: Task<Void, Never>?
    /// The running (or last) re-transcribe / identify-speakers-again job and its outcome message (SCR-013).
    public internal(set) var rerunJob: Job?
    public internal(set) var rerunStatus: String?
    @ObservationIgnored var rerunWatcher: Task<Void, Never>?
    @ObservationIgnored var rerunRestoreReadOnly = false
    /// Set once the user states the transcript language: saving the header then stops adding segment languages back.
    @ObservationIgnored var languagesPinned = false
    /// This Mac's memory tier, for greying out models in the Re-transcribe popover.
    @ObservationIgnored public var hardware: (any HardwareTierProviding)?

    public var selection: Set<SegmentID> = []
    public private(set) var editingSegmentID: SegmentID?
    public private(set) var revealRequest: RevealRequest?
    public private(set) var waveform: WaveformPeaks?

    public private(set) var showIgnored = false { didSet { rebuildDerived() } }
    public private(set) var options = ViewOptions() { didSet { if oldValue.layout != options.layout { rebuildDerived() } } }
    public private(set) var globalOptions = ViewOptions()
    public private(set) var transcriptOverride: ViewOptionsOverride?
    public private(set) var isReadOnly = false
    public func setReadOnly(_ value: Bool) { isReadOnly = value }

    /// The playback state shown by this editor. With a ``PlaybackCenter`` this is the shared session's model (so it survives
    /// leaving the editor); without one it is private to this editor and released with it.
    public private(set) var playback = PlaybackModel()
    @ObservationIgnored public private(set) var undoManager: UndoManager
    public private(set) var canUndo = false
    public private(set) var canRedo = false
    public private(set) var undoActionName = ""
    public private(set) var redoActionName = ""
    /// Bumped on every document change so views and the find model can react.
    public private(set) var revision = 0

    @ObservationIgnored let repository: any TranscriptRepository
    @ObservationIgnored let settings: any SettingsStore
    @ObservationIgnored let media: (any MediaRepository)?
    /// Roots that library-relative media paths resolve against; the composition root supplies the real ones.
    @ObservationIgnored var mediaRoots: @Sendable () async -> [URL] = { MediaFiles.defaultRoots }
    @ObservationIgnored let presets: (any PresetRepository)?
    @ObservationIgnored public let playbackCenter: PlaybackCenter?
    @ObservationIgnored private let engineFactory: @MainActor @Sendable (URL) async -> (engine: any PlayerControlling, isVideo: Bool)?
    @ObservationIgnored private var indexByID: [SegmentID: Int] = [:]
    @ObservationIgnored private var dirtyIDs: Set<SegmentID> = []
    @ObservationIgnored private var needsFullWrite = false
    @ObservationIgnored private var needsHeaderWrite = false
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var writeChain: Task<Void, Never> = Task {}
    @ObservationIgnored private var ioChain: Task<Void, Never> = Task {}
    @ObservationIgnored private let persistDelay: Duration

    public init(
        transcriptID: TranscriptID, repository: any TranscriptRepository, settings: any SettingsStore,
        media: (any MediaRepository)? = nil, presets: (any PresetRepository)? = nil, persistDelay: Duration = .milliseconds(250),
        undoManager: UndoManager? = nil, playbackCenter: PlaybackCenter? = nil,
        engineFactory: @escaping @MainActor @Sendable (URL) async -> (engine: any PlayerControlling, isVideo: Bool)? =
            TranscriptEditorModel.avEngine
    ) {
        self.transcriptID = transcriptID
        self.repository = repository
        self.settings = settings
        self.media = media
        self.presets = presets
        self.persistDelay = persistDelay
        self.engineFactory = engineFactory
        self.playbackCenter = playbackCenter
        let manager = undoManager ?? UndoManager()
        manager.groupsByEvent = false
        manager.levelsOfUndo = 200
        self.undoManager = manager
    }

    public convenience init(transcriptID: TranscriptID, services: AppServices, playbackCenter: PlaybackCenter? = nil) {
        self.init(
            transcriptID: transcriptID, repository: services.transcripts, settings: services.settings, media: services.media,
            presets: services.presets, playbackCenter: playbackCenter)
        voiceProfiles = services.voiceProfiles
        embeddings = services.speakerEmbeddings
        retranscriber = services.segmentRetranscriber
        translationService = services.translation
        jobQueue = services.jobQueue
        mediaRoots = services.mediaRoots
        models = services.models
        hardware = services.hardware
    }

    /// Default player factory: `AVPlayer` for any playable file.
    public static let avEngine: @MainActor @Sendable (URL) async -> (engine: any PlayerControlling, isVideo: Bool)? = { url in
        let engine = AVPlayerEngine(url: url)
        guard await engine.waitUntilReady() else { return nil }
        return (engine, await engine.hasVideo())
    }

    /// Runs `work` after all previously enqueued settings/bookmark writes, preserving order.
    func enqueueIO(_ work: @escaping @Sendable () async -> Void) {
        let previous = ioChain
        ioChain = Task {
            await previous.value
            await work()
        }
    }

    func saveSetting<T: Codable & Sendable>(_ value: T, for key: String) {
        let settings = settings
        enqueueIO { await settings.set(value, for: key) }
    }

    func setPersistenceError(_ message: String) { persistenceError = message }

    /// Replaces the in-memory header with one re-read from storage (after a re-run job changed it).
    func adoptHeader(_ header: Transcript) { transcript = header }

    /// Changes the transcript header and schedules it to be saved.
    func updateHeader(_ change: (inout Transcript) -> Void) {
        guard var current = transcript else { return }
        change(&current)
        transcript = current
        needsHeaderWrite = true
        schedulePersist()
    }

    // MARK: Loading

    public func load() async {
        do {
            guard let transcript = try await repository.transcript(transcriptID) else {
                loadState = .failed("This transcript no longer exists.")
                return
            }
            self.transcript = transcript
            let loaded = try await repository.segments(for: transcriptID)
            segments = loaded.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
            bookmarks = try await repository.bookmarks(for: transcriptID).filter { $0.deletedAt == nil }.sorted { $0.time < $1.time }
            highlights = await settings.value(for: EditorSettingsKey.highlights(transcriptID), as: [TextHighlight].self) ?? []
            await loadOptions()
            await loadReconciliation()
            await loadLanguageState()
            loadState = .loaded
            await loadMedia(for: transcript)
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    /// Re-reads the segments after something outside the editor changed them (a translate job, re-transcription).
    func reloadSegmentsFromRepository() async {
        guard let loaded = try? await repository.segments(for: transcriptID) else { return }
        segments = loaded.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
        revision += 1
    }

    private func loadOptions() async {
        globalOptions = await settings.value(for: EditorSettingsKey.globalViewOptions, as: ViewOptions.self) ?? ViewOptions()
        transcriptOverride = await settings.value(
            for: EditorSettingsKey.viewOptionsOverride(transcriptID), as: ViewOptionsOverride.self)
        options = transcriptOverride?.applied(to: globalOptions) ?? globalOptions
        showIgnored = await settings.value(for: EditorSettingsKey.showIgnored, as: Bool.self) ?? false
        if let speed = await settings.value(for: EditorSettingsKey.playbackSpeed, as: Double.self) { playback.setSpeed(speed) }
        showWaveform = await settings.value(for: EditorSettingsKey.showWaveform, as: Bool.self) ?? true
    }

    private func loadMedia(for transcript: Transcript, overrideURL: URL? = nil) async {
        var resolved = overrideURL
        if resolved == nil, let assetID = transcript.mediaAssetID, let media, let asset = try? await media.asset(assetID),
            asset.deletedAt == nil
        {
            resolved = MediaLocator.url(for: asset, roots: await mediaRoots())
        }
        mediaURL = resolved
        guard let url = resolved else {
            playbackCenter?.stop(transcriptID: transcriptID)
            playback.markMissing()
            return
        }
        if let playbackCenter {
            let reusing = playbackCenter.session(for: transcriptID)?.mediaURL == url
            let session = await playbackCenter.open(
                transcriptID: transcriptID, title: transcript.title, mediaURL: url, speed: playback.speed, factory: engineFactory)
            guard let session else {
                playback.markMissing()
                return
            }
            if Task.isCancelled && !reusing {
                // The editor was dismissed while the player loaded: do not leave an orphan session behind.
                playbackCenter.stop(transcriptID: transcriptID)
                return
            }
            session.playback.isDetached = false
            playback = session.playback
        } else {
            guard let made = await engineFactory(url) else {
                playback.markMissing()
                return
            }
            playback.attach(made.engine, isVideo: made.isVideo)
        }
        playback.setTimeline(WordTimeline(segments: segments))
        if let peaks = await WaveformPeaks.compute(url: url) { waveform = peaks }
    }

    /// The editor is going away. Edits are flushed by the caller; the shared player keeps playing (the mini-player owns it),
    /// a private one stops. Either way the karaoke timeline no longer points at this model.
    public func leaveEditor() {
        playback.isDetached = false
        playback.detachTimeline()
        if playbackCenter == nil { playback.stop() }
        translationWatcher?.cancel()
    }

    isolated deinit {
        debounce?.cancel()
        translationWatcher?.cancel()
        if playbackCenter == nil { playback.stop() }
    }

    // MARK: Derived state

    private func rebuildDerived() {
        visibleSegments = showIgnored ? segments : segments.filter { !$0.isIgnored }
        paragraphs = options.layout == .paragraphs ? ParagraphBuilder.make(from: visibleSegments) : []
        paragraphIDBySegment = Dictionary(
            paragraphs.flatMap { paragraph in paragraph.segments.map { ($0.id, paragraph.id) } }, uniquingKeysWith: { first, _ in first })
        indexByID = Dictionary(uniqueKeysWithValues: segments.enumerated().map { ($1.id, $0) })
        speakerRegions = SpeakerRegions.make(from: segments)
        playback.setTimeline(WordTimeline(segments: segments))
    }

    public func segment(_ id: SegmentID) -> Segment? { indexByID[id].map { segments[$0] } }
    public func speaker(_ id: SpeakerID?) -> Speaker? { id.flatMap { id in transcript?.speakers.first { $0.id == id } } }
    public var speakers: [Speaker] { transcript?.speakers ?? [] }

    /// Languages offered when changing a segment's language.
    public var languageChoices: [LanguageCode] {
        var set = Set(transcript?.languages ?? [])
        for segment in segments { if let code = segment.languageCode { set.insert(code) } }
        set.formUnion([.english, .sinhala, "ta"])
        return set.sorted()
    }

    public var isEmpty: Bool { segments.isEmpty }
    public var hiddenIgnoredCount: Int { segments.count - visibleSegments.count }

    public func setShowIgnored(_ value: Bool) {
        showIgnored = value
        saveSetting(value, for: EditorSettingsKey.showIgnored)
    }

    public func setShowWaveform(_ value: Bool) {
        showWaveform = value
        saveSetting(value, for: EditorSettingsKey.showWaveform)
    }

    public func setPlaybackSpeed(_ speed: Double) {
        playback.setSpeed(speed)
        let value = playback.speed
        saveSetting(value, for: EditorSettingsKey.playbackSpeed)
    }

    /// Points the transcript at a replacement media file (EDIT-AC-19 "Relink").
    public func relink(to url: URL) async {
        guard let media, var current = transcript else { return }
        let bookmark = try? url.bookmarkData(options: [.withSecurityScope])
        var asset = MediaAsset(kind: .audio, bookmark: bookmark)
        if let id = current.mediaAssetID, let existing = try? await media.asset(id) { asset = existing }
        asset.bookmark = bookmark
        asset.libraryRelativePath = nil
        asset.deletedAt = nil
        do {
            try await media.save(asset)
            if current.mediaAssetID != asset.id {
                current.mediaAssetID = asset.id
                transcript = current
                try await repository.save(current)
            }
        } catch {
            persistenceError = error.localizedDescription
            return
        }
        await loadMedia(for: current, overrideURL: url)
    }

    /// Asks the view to give the transcript keyboard focus (so Space/J/K/L keep working after clicks and edits).
    public func requestListFocus() { listFocusToken &+= 1 }

    public func reveal(_ id: SegmentID) { revealRequest = RevealRequest(segmentID: id) }

    // MARK: View options (EDIT-AC-14)

    public var customizesThisTranscript: Bool { transcriptOverride != nil }

    /// Changes the options. With "customize for this transcript" on, only this transcript's override changes; otherwise
    /// the global default does.
    public func updateOptions(_ mutate: (inout ViewOptions) -> Void) {
        var next = options
        mutate(&next)
        next.fontSize = min(max(next.fontSize, ViewOptions.fontSizeRange.lowerBound), ViewOptions.fontSizeRange.upperBound)
        next.lineSpacing = min(max(next.lineSpacing, ViewOptions.lineSpacingRange.lowerBound), ViewOptions.lineSpacingRange.upperBound)
        options = next
        if transcriptOverride != nil {
            let override = ViewOptionsOverride.difference(from: globalOptions, to: next)
            transcriptOverride = override
            let key = EditorSettingsKey.viewOptionsOverride(transcriptID)
            saveSetting(override, for: key)
        } else {
            globalOptions = next
            saveSetting(next, for: EditorSettingsKey.globalViewOptions)
        }
    }

    /// Turns the per-transcript override on (starting from the current look) or off (back to the global defaults).
    public func setCustomizesThisTranscript(_ on: Bool) {
        let key = EditorSettingsKey.viewOptionsOverride(transcriptID)
        if on {
            guard transcriptOverride == nil else { return }
            let empty = ViewOptionsOverride()
            transcriptOverride = empty
            saveSetting(empty, for: key)
        } else {
            guard transcriptOverride != nil else { return }
            transcriptOverride = nil
            options = globalOptions
            let cleared: ViewOptionsOverride? = nil
            saveSetting(cleared, for: key)
        }
    }

    // MARK: Undo-able edit pipeline (EDIT-AC-12)

    /// Applies `delta`, registers its inverse with the undo manager and schedules persistence.
    public func perform(_ delta: EditDelta) {
        guard !delta.isEmpty, !isReadOnly else { return }
        undoManager.beginUndoGrouping()
        apply(delta)
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.perform(delta.inverted) }
        }
        undoManager.setActionName(delta.name)
        undoManager.endUndoGrouping()
        refreshUndoState()
    }

    private func apply(_ delta: EditDelta) {
        var next = segments
        delta.apply(to: &next)
        segments = next
        if let change = delta.speakers { transcript?.speakers = change.after }
        if delta.isStructural { needsFullWrite = true } else { dirtyIDs.formUnion(delta.touchedIDs) }
        needsHeaderWrite = true
        revision += 1
        schedulePersist()
    }

    func refreshUndoState() {
        canUndo = undoManager.canUndo
        canRedo = undoManager.canRedo
        undoActionName = undoManager.undoActionName
        redoActionName = undoManager.redoActionName
    }

    public func undo() {
        guard undoManager.canUndo else { return }
        undoManager.undo()
        refreshUndoState()
        revision += 1
    }

    public func redo() {
        guard undoManager.canRedo else { return }
        undoManager.redo()
        refreshUndoState()
        revision += 1
    }

    // MARK: Text, speaker, language, flags

    public func beginEditing(_ id: SegmentID) {
        guard !isReadOnly, segment(id) != nil else { return }
        editingSegmentID = id
        selection = [id]
    }

    public func cancelEditing() { editingSegmentID = nil }

    /// Commits an inline edit: unchanged words keep their timings (EDIT-AC-06).
    public func commitEditing(text: String) {
        guard let id = editingSegmentID else { return }
        editingSegmentID = nil
        editText(id, to: text)
    }

    public func editText(_ id: SegmentID, to text: String) {
        guard let old = segment(id) else { return }
        var new = SegmentOps.editText(old, to: text)
        guard new != old else { return }
        if old.text != new.text { new.isUserEdited = true }  // SCR-013: a re-transcribe keeps this segment
        if old.text != new.text, !old.translations.isEmpty { staleTranslations.insert(id) }  // TRN-AC-10
        perform(EditDelta(name: "Edit Text", replaced: [.init(before: old, after: new)]))
    }

    public func setSpeaker(_ speakerID: SpeakerID?, for ids: Set<SegmentID>) {
        let changes = segments.filter { ids.contains($0.id) && $0.speakerID != speakerID }.map { old -> EditDelta.Replacement in
            var new = old
            new.speakerID = speakerID
            new.isUserEdited = true
            return .init(before: old, after: new)
        }
        perform(EditDelta(name: "Change Speaker", replaced: changes))
    }

    public func setLanguage(_ code: LanguageCode?, for ids: Set<SegmentID>) {
        // Confirming the guessed language also changes the segment: the user's choice is certain.
        let changes = segments.filter {
            ids.contains($0.id) && ($0.languageCode != code || (code != nil && $0.languageConfidence != 1))
        }.map { old -> EditDelta.Replacement in
            var new = old
            new.languageCode = code
            // The user chose it, so it is certain (LANG-AC-06 flags only guessed languages).
            new.languageConfidence = code == nil ? nil : 1
            new.isUserEdited = true
            return .init(before: old, after: new)
        }
        perform(EditDelta(name: "Change Language", replaced: changes))
    }

    /// "Stop ignoring" / "Ignore" (IGN-AC-07).
    public func setIgnored(_ ignored: Bool, for ids: Set<SegmentID>) {
        let changes = segments.filter { ids.contains($0.id) && $0.isIgnored != ignored }.map { old -> EditDelta.Replacement in
            var new = old
            new.isIgnored = ignored
            new.ignoreFlagIsManual = true  // IGN-AC-05: a re-derive after a rule change must keep the user's choice
            return .init(before: old, after: new)
        }
        perform(EditDelta(name: ignored ? "Ignore Segment" : "Stop Ignoring", replaced: changes))
    }

    // MARK: Split / merge (EDIT-AC-07)

    @discardableResult
    public func split(_ id: SegmentID, beforeWord index: Int) -> Bool {
        guard let position = indexByID[id], let (first, second) = SegmentOps.split(segments[position], beforeWord: index) else {
            return false
        }
        perform(
            EditDelta(
                name: "Split Segment", replaced: [.init(before: segments[position], after: first)],
                inserted: [.init(index: position + 1, segment: second)]))
        return true
    }

    /// Merges the segment with its neighbour in the full (not just visible) order.
    @discardableResult
    public func merge(_ id: SegmentID, withNext: Bool) -> Bool {
        guard let position = indexByID[id] else { return false }
        let otherPosition = withNext ? position + 1 : position - 1
        guard segments.indices.contains(otherPosition) else { return false }
        let firstIndex = min(position, otherPosition)
        let first = segments[firstIndex]
        let second = segments[firstIndex + 1]
        let merged = SegmentOps.merge(first, second)
        perform(
            EditDelta(
                name: "Merge Segments", replaced: [.init(before: first, after: merged)],
                removed: [.init(index: firstIndex + 1, segment: second)]))
        return true
    }

    // MARK: Find & replace integration (FR-AC-05, 06)

    /// Applies a Replace / Replace All change set as one undo step.
    public func apply(changeSet: ChangeSet, name: String) {
        perform(EditDelta(name: name, changeSet: changeSet))
    }

    // MARK: Persistence (EDIT-AC-18)

    private func schedulePersist() {
        debounce?.cancel()
        debounce = Task { [weak self, persistDelay] in
            try? await Task.sleep(for: persistDelay)
            guard !Task.isCancelled else { return }
            self?.enqueueWrite()
        }
    }

    /// Writes everything pending and waits for it; called when the view disappears and by tests.
    public func flush() async {
        debounce?.cancel()
        enqueueWrite()
        await writeChain.value
        await ioChain.value
    }

    private func enqueueWrite() {
        guard !dirtyIDs.isEmpty || needsFullWrite || needsHeaderWrite else { return }
        let full = needsFullWrite
        let ids = dirtyIDs
        var header: Transcript?
        if needsHeaderWrite, var current = transcript {
            current.modifiedAt = Date()
            if !languagesPinned { current.languages.formUnion(Set(segments.compactMap(\.languageCode))) }
            transcript = current
            header = current
        }
        dirtyIDs = []
        needsFullWrite = false
        needsHeaderWrite = false
        let snapshot = full ? segments : segments.filter { ids.contains($0.id) }
        let repository = repository
        let id = transcriptID
        let previous = writeChain
        writeChain = Task { [weak self] in
            await previous.value
            do {
                if full {
                    try await repository.replaceSegments(snapshot, for: id)
                } else if !snapshot.isEmpty {
                    try await repository.upsertSegments(snapshot, for: id)
                }
                if let header { try await repository.save(header) }
            } catch {
                self?.persistenceError = error.localizedDescription
            }
        }
    }
}
