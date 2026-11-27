import AppCore
import FeatureSupport
import FeatureWorkspace
import Foundation
import Testing

private let id = TranscriptID()

@MainActor
private func make(
    intelligence: (any IntelligenceServicing)? = ScriptedIntelligence(), transcript: Transcript? = nil, segments: [Segment] = [],
    files: (any AppCore.AttachmentFileManaging)? = nil
) async -> (AppServices, WorkspaceModel) {
    let header = transcript ?? Transcript(id: id, title: "Weekly sync", source: .meeting, languages: ["en"])
    let repo = InMemoryTranscripts(items: [header], segments: [header.id: segments])
    var services = AppServices.preview()
    services.transcripts = repo
    services.workspace = .inMemory(intelligence: intelligence, files: files)
    let workspace = WorkspaceModel(transcriptID: header.id, services: services)
    return (services, workspace)
}

private func segment(_ text: String, at start: TimeInterval = 0) -> Segment { Segment(start: start, end: start + 4, text: text) }

@MainActor
@Suite("Notes model", .serialized)
struct NotesModelTests {
    @Test func typingIsSavedAfterAPauseAndOnFlush() async throws {
        let (services, workspace) = await make()
        await workspace.notes.load()
        workspace.notes.markdown = "Remember the budget"
        await workspace.notes.flush()
        #expect(try await services.workspace.notes.notes(for: id)?.markdown == "Remember the budget")
    }

    @Test func loadingDoesNotCountAsAnEdit() async throws {
        let (services, workspace) = await make()
        try await services.workspace.notes.save(TranscriptNotes(transcriptID: id, markdown: "saved earlier"))
        await workspace.notes.load()
        #expect(workspace.notes.markdown == "saved earlier")
        #expect(!workspace.notes.showsSummaryNotice)
    }

    @Test func summariseReplacesThePageKeepsAVersionAndCanBeUndone() async throws {
        let (services, workspace) = await make(segments: [segment("We agreed to ship Friday")])
        await workspace.start()
        workspace.notes.markdown = "My own note: ask Elena about staging"
        workspace.notes.summarize()
        #expect(await eventually { !workspace.notes.isSummarizing && workspace.notes.showsSummaryNotice })
        #expect(workspace.notes.markdown.contains("## Summary"))
        #expect(workspace.notes.markdown.contains("ask Elena about staging"))  // the notes were an input
        let versions = try await services.workspace.notes.versions(for: id)
        #expect(versions.first?.reason == .beforeSummary)
        #expect(versions.first?.markdown == "My own note: ask Elena about staging")
        await workspace.notes.undoSummary()
        #expect(workspace.notes.markdown == "My own note: ask Elena about staging")
        #expect(!workspace.notes.showsSummaryNotice)
        #expect(try await services.workspace.notes.versions(for: id).contains { $0.reason == .beforeRestore })
    }

    @Test func summariseCanLeaveTheNotesAndFilesOut() async throws {
        struct Recording: IntelligenceServicing {
            let seen: Box
            func availability() async -> IntelligenceAvailability { .available }
            func supports(language: LanguageCode?) async -> Bool { true }
            func summarize(_ request: SummaryRequest) -> AsyncThrowingStream<SummaryEvent, any Error> {
                seen.value = request
                return AsyncThrowingStream { $0.yield(.finished(markdown: "## Summary")); $0.finish() }
            }
            func summarize(attachment: AppCore.Attachment) -> AsyncThrowingStream<SummaryEvent, any Error> { AsyncThrowingStream { $0.finish() } }
            func answer(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, any Error> { AsyncThrowingStream { $0.finish() } }
        }
        final class Box: @unchecked Sendable { var value: SummaryRequest? }
        let box = Box()
        let (_, workspace) = await make(intelligence: Recording(seen: box), segments: [segment("hello")])
        await workspace.start()
        workspace.notes.markdown = "private"
        workspace.notes.includeNotes = false
        workspace.notes.includeFiles = false
        workspace.notes.style = .lecture
        workspace.notes.summarize()
        #expect(await eventually { box.value != nil })
        #expect(box.value?.includeNotes == false && box.value?.includeFiles == false && box.value?.style == .lecture)
    }

    @Test func aFailureIsExplainedAndKeepsThePage() async throws {
        let (_, workspace) = await make(intelligence: ScriptedIntelligence(state: .unavailable(.notEnabled)), segments: [segment("hello")])
        await workspace.start()
        workspace.notes.markdown = "keep me"
        // The button is disabled with the reason; calling summarize anyway must not touch the page.
        #expect(workspace.summarizeUnavailableReason()?.contains("Apple Intelligence") == true)
        #expect(workspace.notes.markdown == "keep me")
    }

    @Test func restoringAVersionKeepsTheCurrentPageAsAVersionToo() async throws {
        let (services, workspace) = await make()
        await workspace.notes.load()
        workspace.notes.markdown = "first"
        await workspace.notes.saveCheckpoint()
        workspace.notes.markdown = "second"
        let version = try #require(await services.workspace.notes.versions(for: id).first)
        await workspace.notes.restore(version)
        #expect(workspace.notes.markdown == "first")
        let reasons = try await services.workspace.notes.versions(for: id).map(\.reason)
        #expect(reasons.contains(.beforeRestore))
    }

    @Test func timestampsFormatForMinutesAndHours() {
        #expect(NotesModel.timestamp(772) == "[12:52]")
        #expect(NotesModel.timestamp(3723) == "[1:02:03]")
    }
}

@MainActor
@Suite("Workspace gating", .serialized)
struct WorkspaceGatingTests {
    @Test func summariseExplainsItselfWhileTheMeetingIsLiveButChatStaysAvailable() async throws {
        struct LiveSession: LiveSessionControlling {
            let current: TranscriptID
            func start(_ config: LiveSessionConfig) async throws {}
            func stop() async -> TranscriptID? { nil }
            func state() -> AsyncStream<LiveSessionState> { AsyncStream { $0.finish() } }
            func lines() -> AsyncStream<[CaptionLine]> { AsyncStream { $0.finish() } }
            func activeTranscriptID() async -> TranscriptID? { current }
        }
        var (services, _) = await make(segments: [segment("hello")])
        services.live = LiveSession(current: id)
        let workspace = WorkspaceModel(transcriptID: id, services: services)
        await workspace.start()
        #expect(workspace.isLive)
        #expect(workspace.summarizeUnavailableReason() == "Available when the meeting ends and the full transcript is ready.")
        #expect(workspace.chatUnavailableReason() == nil)
        workspace.tab = .notes
        workspace.notes.markdown = "notes during the meeting"  // writing is always possible
        #expect(workspace.notes.markdown == "notes during the meeting")
    }

    @Test func unsupportedLanguageAndMissingIntelligenceAreExplained() async {
        let sinhala = Transcript(id: id, title: "සම්මුඛ", source: .file, languages: ["si"])
        let (_, a) = await make(transcript: sinhala, segments: [segment("x")])
        await a.start()
        #expect(a.chatUnavailableReason()?.contains("Sinhala") == true)
        let (_, b) = await make(intelligence: nil, segments: [segment("x")])
        await b.start()
        #expect(b.chatUnavailableReason() != nil)
    }

    @Test func emptyThingsCannotBeSummarised() async {
        let (_, workspace) = await make()
        await workspace.start()
        #expect(workspace.summarizeUnavailableReason() == "There is nothing to summarise yet.")
    }

    @Test func aRunningFinalisationBlocksSummariseThenHandsOverToTheFinalTranscript() async throws {
        let queue = PlaceholderJobQueue()
        var (services, _) = await make(segments: [segment("hello")])
        services.jobQueue = queue
        let workspace = WorkspaceModel(transcriptID: id, services: services)
        let final = TranscriptID()
        var opened: TranscriptID?
        workspace.onSuperseded = { opened = $0 }
        var job = Job(kind: .finalizeMeeting, state: .running, transcriptID: id)
        _ = try await queue.enqueue(job)
        await workspace.start()
        #expect(await eventually { workspace.isFinalizing })
        #expect(workspace.summarizeUnavailableReason()?.contains("still being prepared") == true)
        job.state = .completed
        job.transcriptID = final
        _ = try await queue.enqueue(job)
        #expect(await eventually { opened == final })
        #expect(!workspace.isFinalizing)
    }
}

@MainActor
@Suite("Chat model", .serialized)
struct ChatModelTests {
    @Test func askingStreamsAnAnswerWithSourcesAndSavesTheConversation() async throws {
        let (services, workspace) = await make(segments: [segment("The release moved to September 26", at: 20)])
        await workspace.start()
        workspace.chat.draft = "When did the release move?"
        workspace.chat.send()
        #expect(await eventually { !workspace.chat.isAnswering && workspace.chat.messages.count == 2 })
        #expect(workspace.chat.messages.map(\.role) == [.user, .assistant])
        #expect(workspace.chat.messages[1].sources.first?.label == "00:20")
        #expect(workspace.chat.draft.isEmpty)
        #expect(try await services.workspace.chat.messages(for: id).count == 2)
        await workspace.chat.clear()
        #expect(workspace.chat.messages.isEmpty)
        #expect(try await services.workspace.chat.messages(for: id).isEmpty)
    }

    @Test func conversationsAreNotSavedWhenHistoryIsOff() async throws {
        let (services, workspace) = await make(segments: [segment("x")])
        await services.settings.set(false, for: SettingsKey.intelligenceKeepChat)
        await workspace.start()
        workspace.chat.ask("What happened?")
        #expect(await eventually { workspace.chat.messages.count == 2 })
        #expect(try await services.workspace.chat.messages(for: id).isEmpty)
    }

    @Test func theScopeTravelsWithTheQuestion() async throws {
        let (_, workspace) = await make(segments: [segment("x")])
        await workspace.start()
        workspace.chat.scope = .summaryAndNotes
        workspace.chat.ask("What was decided?")
        #expect(await eventually { workspace.chat.messages.count == 2 })
        #expect(workspace.chat.messages.allSatisfy { $0.scope == .summaryAndNotes })
    }

    @Test func suggestionsFitMeetingsAndLectures() {
        #expect(ChatModel.suggestions(for: .meeting, hasFiles: false).contains("What were the action items?"))
        #expect(ChatModel.suggestions(for: .file, hasFiles: true).contains("Quiz me on this lecture"))
    }
}

@MainActor
@Suite("Files and slides", .serialized)
struct FilesAndSlidesTests {
    private struct FakeFiles: AppCore.AttachmentFileManaging {
        let repo: any AppCore.AttachmentRepository
        func attach(_ urls: [URL], role: AppCore.Attachment.Role, to transcript: TranscriptID) async throws -> [AppCore.Attachment] {
            var made: [AppCore.Attachment] = []
            for url in urls {
                if url.pathExtension == "pptx" { throw AppError.other("Export it as a PDF first") }
                let a = AppCore.Attachment(transcriptID: transcript, role: role, kind: .pdf, title: url.deletingPathExtension().lastPathComponent, relativePath: url.lastPathComponent, pageCount: 12)
                try await repo.save(a)
                made.append(a)
            }
            return made
        }
        func location(of attachment: AppCore.Attachment) async -> URL { URL(fileURLWithPath: "/tmp/\(attachment.relativePath)") }
        func remove(_ attachment: AppCore.Attachment) async throws { try await repo.softDelete(attachment.id) }
    }

    private func setUp() async -> (AppServices, WorkspaceModel) {
        var (services, _) = await make(segments: [segment("hello")])
        let files = FakeFiles(repo: services.workspace.attachments)
        services.workspace.files = files
        return (services, WorkspaceModel(transcriptID: id, services: services))
    }

    @Test func addingADeckMakesItAvailableAsTheStage() async throws {
        let (_, workspace) = await setUp()
        await workspace.start()
        #expect(workspace.deck == nil && !workspace.showsSlides)
        await workspace.files.add([URL(fileURLWithPath: "/x/Lecture9.pdf")], role: .slides)
        await workspace.refreshDeck()
        #expect(workspace.deck?.title == "Lecture9")
        workspace.showSlides()
        #expect(workspace.showsSlides)
        workspace.goTo(page: 99)
        #expect(workspace.page == 11)
        workspace.previous()
        #expect(workspace.page == 10)
    }

    @Test func aPresentationFileGetsAPlainExplanation() async throws {
        let (_, workspace) = await setUp()
        await workspace.start()
        await workspace.files.add([URL(fileURLWithPath: "/x/deck.pptx")], role: .slides)
        #expect(workspace.files.errorMessage?.contains("PDF") == true)
        #expect(workspace.files.attachments.isEmpty)
    }

    @Test func slideTimingsLetPlaybackFollowTheDeck() async throws {
        let (services, workspace) = await setUp()
        await workspace.start()
        await workspace.files.add([URL(fileURLWithPath: "/x/Deck.pdf")], role: .slides)
        await workspace.refreshDeck()
        workspace.showSlides()
        var now: TimeInterval = 10
        workspace.currentTime = { now }
        workspace.goTo(page: 0)
        await workspace.linkCurrentSlide()
        now = 60
        workspace.goTo(page: 3)
        await workspace.linkCurrentSlide()
        #expect(try await services.workspace.attachments.links(for: workspace.deck!.id).map(\.page) == [0, 3])
        workspace.goTo(page: 7)
        workspace.follow(time: 30)
        #expect(workspace.page == 0)
        workspace.follow(time: 75)
        #expect(workspace.page == 3)
        #expect(workspace.slide(at: 20) == 0)
        workspace.followsPlayback = false
        workspace.follow(time: 5)
        #expect(workspace.page == 3)
        await workspace.clearLinks()
        #expect(workspace.links.isEmpty)
    }

    @Test func fileTogglesAndRemovalFeedSummariesAndChat() async throws {
        let (services, workspace) = await setUp()
        await workspace.start()
        await workspace.files.add([URL(fileURLWithPath: "/x/Syllabus.pdf")], role: .reference)
        let file = try #require(workspace.files.attachments.first)
        await workspace.files.setUsedInContext(file, false)
        #expect(workspace.files.attachments.first?.usedInContext == false)
        await workspace.files.summarize(file)
        #expect(workspace.files.attachments.first?.summary?.contains("Key point") == true)
        await workspace.files.remove(file)
        #expect(workspace.files.attachments.isEmpty)
        #expect(try await services.workspace.attachments.attachments(for: id).isEmpty)
    }

    @Test func aChatSourceOpensTheSlideTheTimeOrTheFile() async throws {
        let (_, workspace) = await setUp()
        await workspace.start()
        await workspace.files.add([URL(fileURLWithPath: "/x/Deck.pdf")], role: .slides)
        await workspace.files.add([URL(fileURLWithPath: "/x/Syllabus.pdf")], role: .reference)
        await workspace.refreshDeck()
        let deck = try #require(workspace.files.slideDecks.first)
        let reference = try #require(workspace.files.attachments.first { $0.role == .reference })
        var seeked: TimeInterval?
        workspace.seek = { seeked = $0 }
        workspace.tab = .chat
        workspace.open(ChatSource(kind: .transcript, label: "12:52", time: 772))
        #expect(workspace.tab == .transcript && seeked == 772)
        workspace.open(ChatSource(kind: .page, label: "Slide 5", attachmentID: deck.id, page: 4))
        #expect(workspace.showsSlides && workspace.page == 4)
        workspace.open(ChatSource(kind: .page, label: "Syllabus p.1", attachmentID: reference.id, page: 0))
        #expect(workspace.tab == .files)
        workspace.open(ChatSource(kind: .notes, label: "Notes"))
        #expect(workspace.tab == .notes)
    }
}
