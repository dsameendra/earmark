import AppCore
import FeatureSupport
import Foundation
import Observation

/// Everything the redesigned transcript page adds: tabs, notes, chat, files, the slide stage and whether summaries are possible.
@MainActor @Observable
public final class WorkspaceModel {
    public enum Tab: String, CaseIterable, Identifiable, Sendable {
        case transcript, notes, chat, files
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .transcript: "Transcript"
            case .notes: "Notes"
            case .chat: "Chat"
            case .files: "Files"
            }
        }
    }

    public enum Stage: String, Sendable { case video, slides }

    public var tab: Tab = .transcript
    public var stage: Stage = .video
    public let notes: NotesModel
    public let chat: ChatModel
    public let files: FilesModel

    public private(set) var availability: IntelligenceAvailability = .unavailable(.osTooOld)
    public private(set) var languageSupported = true
    /// The transcript is still being written by a running meeting or live session.
    public private(set) var isLive = false
    public private(set) var source: TranscriptSource = .file
    public private(set) var language: LanguageCode?
    public private(set) var hasSegments = false
    public private(set) var isFinalizing = false

    // Slides
    public private(set) var deck: Attachment?
    public var page = 0
    public private(set) var links: [SlideLink] = []
    public var followsPlayback = true

    public let transcriptID: TranscriptID
    @ObservationIgnored let services: AppServices
    @ObservationIgnored public var currentTime: @MainActor () -> TimeInterval? = { nil }
    @ObservationIgnored public var seek: @MainActor (TimeInterval) -> Void = { _ in }
    /// Called when this live draft has been replaced by the meeting's final transcript (open that one instead).
    @ObservationIgnored public var onSuperseded: @MainActor (TranscriptID) -> Void = { _ in }
    @ObservationIgnored private var trackedJobs: Set<JobID> = []
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    public init(transcriptID: TranscriptID, services: AppServices) {
        self.transcriptID = transcriptID
        self.services = services
        notes = NotesModel(transcriptID: transcriptID, services: services)
        chat = ChatModel(transcriptID: transcriptID, services: services)
        files = FilesModel(transcriptID: transcriptID, services: services)
        chat.notesProvider = { [notes] in notes.markdown }
    }

    // MARK: Lifecycle

    public func start() async {
        let events = services.workspace.events.stream()
        let liveStates = services.live.state()
        let jobEvents = services.jobQueue.events()
        for job in await services.jobQueue.jobs() { handle(job: job) }
        async let notesLoad: Void = notes.load()
        async let chatLoad: Void = chat.load()
        async let filesLoad: Void = files.load()
        _ = await (notesLoad, chatLoad, filesLoad)
        await refreshTranscript()
        await refreshDeck()
        await notes.suggestStyle(for: source)
        let liveWatcher = Task { [weak self] in for await _ in liveStates { await self?.refreshLive() } }
        let eventWatcher = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                if case .attachmentsChanged(let id) = event, id == transcriptID {
                    await files.load()
                    await refreshDeck()
                }
            }
        }
        let jobWatcher = Task { [weak self] in
            for await event in jobEvents {
                guard let self else { return }
                if case .updated(let job) = event { handle(job: job) }
            }
        }
        tasks = [liveWatcher, eventWatcher, jobWatcher]
        await refreshLive()
    }

    public func stop() async {
        tasks.forEach { $0.cancel() }
        tasks = []
        await notes.flush()
        chat.stop()
    }

    public func refreshTranscript() async {
        guard let transcript = try? await services.transcripts.transcript(transcriptID) else { return }
        source = transcript.source
        language = transcript.languages.sorted { $0.rawValue < $1.rawValue }.first
        hasSegments = ((try? await services.transcripts.segments(for: transcriptID))?.isEmpty == false)
        if let intelligence = services.workspace.intelligence {
            availability = await intelligence.availability()
            languageSupported = await intelligence.supports(language: language)
        }
    }

    /// A meeting's finalisation job runs on the live draft; when it completes the final transcript replaces the draft.
    private func handle(job: Job) {
        guard job.kind == .finalizeMeeting else { return }
        let ongoing = job.state == .pending || job.state == .running || job.state == .paused
        if job.transcriptID == transcriptID, ongoing {
            trackedJobs.insert(job.id)
            isFinalizing = true
        } else if trackedJobs.contains(job.id) {
            if job.state == .completed, let final = job.transcriptID, final != transcriptID {
                isFinalizing = false
                trackedJobs.remove(job.id)
                onSuperseded(final)
            } else if !ongoing {
                isFinalizing = false
                trackedJobs.remove(job.id)
            }
        }
    }

    private func refreshLive() async {
        let active = await services.live.activeTranscriptID()
        isLive = active == transcriptID
        await refreshTranscript()
    }

    // MARK: Summarise gating

    public var hasIntelligence: Bool { services.workspace.intelligence != nil }

    /// Why Summarise and Chat cannot be used right now, or nil when they can. Chat is allowed during a live meeting; Summarise
    /// waits for the full transcript.
    public func chatUnavailableReason() -> String? {
        guard hasIntelligence else { return "Summaries and chat are not available in this build." }
        if case .unavailable(let reason) = availability { return IntelligenceCopy.explain(reason) }
        if !languageSupported { return IntelligenceCopy.languageNotSupported(language?.rawValue ?? "") }
        return nil
    }

    public func summarizeUnavailableReason() -> String? {
        if let reason = chatUnavailableReason() { return reason }
        if isLive { return "Available when the meeting ends and the full transcript is ready." }
        if isFinalizing { return "The full transcript is still being prepared. Summarise will be available when it is ready." }
        if !hasSegments && notes.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.attachments.isEmpty {
            return "There is nothing to summarise yet."
        }
        return nil
    }

    public func setFinalizing(_ value: Bool) { isFinalizing = value }

    // MARK: Slides

    public var showsSlides: Bool { stage == .slides && deck != nil }

    public func refreshDeck() async {
        let decks = files.slideDecks
        let current = decks.first { $0.id == deck?.id } ?? decks.first
        deck = current
        if let current {
            links = (try? await services.workspace.attachments.links(for: current.id)) ?? []
            if page >= current.pageCount { page = max(0, current.pageCount - 1) }
        } else {
            links = []
            page = 0
            if stage == .slides { stage = .video }
        }
    }

    public func select(deck newDeck: Attachment) async {
        deck = newDeck
        page = 0
        links = (try? await services.workspace.attachments.links(for: newDeck.id)) ?? []
    }

    public func showSlides() { if deck != nil { stage = .slides } }
    public func showVideo() { stage = .video }

    public func goTo(page newPage: Int) {
        guard let deck else { return }
        page = min(max(0, newPage), max(0, deck.pageCount - 1))
    }

    public func next() { goTo(page: page + 1) }
    public func previous() { goTo(page: page - 1) }

    /// "Slide changes here": the current slide is up from the current playback time.
    public func linkCurrentSlide() async {
        guard let deck, let time = currentTime() else { return }
        var updated = links.filter { abs($0.time - time) > 0.5 }
        updated.append(SlideLink(attachmentID: deck.id, page: page, time: time))
        updated.sort { $0.time < $1.time }
        try? await services.workspace.attachments.replaceLinks(updated, for: deck.id)
        links = updated
    }

    public func clearLinks() async {
        guard let deck else { return }
        try? await services.workspace.attachments.replaceLinks([], for: deck.id)
        links = []
    }

    /// Moves the stage to the slide that was up at `time` (playback following the deck). Without links the deck is a plain viewer.
    public func follow(time: TimeInterval) {
        guard followsPlayback, stage == .slides, !links.isEmpty else { return }
        guard let link = links.last(where: { $0.time <= time }) ?? links.first else { return }
        if link.page != page { goTo(page: link.page) }
    }

    /// The slide that was up at `time`, for the transcript's "slide N" label.
    public func slide(at time: TimeInterval) -> Int? {
        guard !links.isEmpty else { return nil }
        return (links.last { $0.time <= time } ?? links.first)?.page
    }

    /// A chat or note source was clicked: jump to the moment, the slide or the file.
    public func open(_ source: ChatSource) {
        switch source.kind {
        case .transcript:
            tab = .transcript
            if let time = source.time { seek(time) }
        case .page:
            if let id = source.attachmentID, let attachment = files.attachments.first(where: { $0.id == id }) {
                if attachment.role == .slides {
                    deck = attachment
                    page = source.page ?? 0
                    stage = .slides
                } else {
                    tab = .files
                }
            }
        case .notes, .summary:
            tab = .notes
        }
    }
}
