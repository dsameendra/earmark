import AppCore
import FeatureMeetings
import FeatureSettings
import FeatureSupport
import Foundation
import Testing
import os

// MARK: - Fakes

final class FakeCapture: MeetingCapturing {
    private let lock = OSAllocatedUnfairLock<[(MeetingApp, MeetingCaptureMode)]>(initialState: [])
    private let stateBus = Broadcaster<MeetingCaptureState>()
    private let lineBus = Broadcaster<[CaptionLine]>()
    let failure: AppError?
    let transcriptID: TranscriptID? = TranscriptID()
    init(failure: AppError? = nil) { self.failure = failure }
    var starts: [(MeetingApp, MeetingCaptureMode)] { lock.withLock { $0 } }

    func start(app: MeetingApp, mode: MeetingCaptureMode) async throws {
        if let failure { throw failure }
        lock.withLock { $0.append((app, mode)) }
        stateBus.send(.capturing(app, mode: mode, since: Date()))
    }
    func stop() async -> TranscriptID? {
        stateBus.send(.idle)
        return transcriptID
    }
    func state() -> AsyncStream<MeetingCaptureState> { stateBus.stream(initial: .idle) }
    func lines() -> AsyncStream<[CaptionLine]> { lineBus.stream(initial: []) }
    func emit(_ lines: [CaptionLine]) { lineBus.send(lines) }
    func emit(_ state: MeetingCaptureState) { stateBus.send(state) }
}

final class FakePrompter: MeetingPromptPresenting {
    private struct Log {
        var presented: [MeetingPrompt] = []
        var withdrawn: [MeetingApp] = []
        var reminders: [MeetingApp] = []
    }
    private let log = OSAllocatedUnfairLock(initialState: Log())
    private let bus = Broadcaster<MeetingPromptResponse>()
    var presented: [MeetingPrompt] { log.withLock { $0.presented } }
    var withdrawn: [MeetingApp] { log.withLock { $0.withdrawn } }
    var reminders: [MeetingApp] { log.withLock { $0.reminders } }

    func present(_ prompt: MeetingPrompt) async { log.withLock { $0.presented.append(prompt) } }
    func withdraw(app: MeetingApp) async { log.withLock { $0.withdrawn.append(app) } }
    func remindConsent(app: MeetingApp) async { log.withLock { $0.reminders.append(app) } }
    func responses() -> AsyncStream<MeetingPromptResponse> { bus.stream() }
    func respond(_ response: MeetingPromptResponse) { bus.send(response) }
}

final class BroadcastDetector: MeetingDetector {
    let bus = Broadcaster<MeetingEvent>()
    func events() -> AsyncStream<MeetingEvent> { bus.stream() }
}

@MainActor
private func make(
    store: InMemorySettingsStore = InMemorySettingsStore(), capture: FakeCapture? = FakeCapture(),
    prompter: FakePrompter? = FakePrompter(), detector: (any MeetingDetector)? = nil, meetings: [Meeting] = [],
    transcripts: [Transcript] = []
) -> (MeetingsModel, FakeCapture?, FakePrompter?, InMemorySettingsStore) {
    var services = AppServices.preview(transcripts: transcripts, meetings: meetings)
    services.settings = store
    services.meetingCapture = capture
    services.meetingPrompts = prompter
    if let detector { services.meetingDetector = detector }
    return (MeetingsModel(services: services), capture, prompter, store)
}

private func started(_ app: MeetingApp = .zoom) -> MeetingEvent { .started(app, at: Date(timeIntervalSince1970: 1_700_000_000)) }
private func ended(_ app: MeetingApp = .zoom) -> MeetingEvent { .ended(app, at: Date(timeIntervalSince1970: 1_700_003_600)) }

@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

// MARK: - Prompt policy (pure)

@Suite struct MeetingPromptPolicyTests {
    @Test func defaultPolicyAsksFirst() {  // MTG-AC-03
        for app in MeetingApp.allCases {
            let policy = MeetingPolicy(app: app)
            #expect(policy.behavior == .askFirst)
            #expect(MeetingPromptPolicy.decide(policy: policy, hour: 12) == .prompt)
        }
    }

    @Test func doNothingNeverPrompts() {
        #expect(MeetingPromptPolicy.decide(policy: MeetingPolicy(app: .zoom, behavior: .doNothing), hour: 12) == .none)
    }

    @Test func automaticBehavioursStartWithoutPrompt() {  // MTG-AC-05
        #expect(MeetingPromptPolicy.decide(policy: MeetingPolicy(app: .zoom, behavior: .autoTranscribe), hour: 12) == .auto(record: false))
        #expect(
            MeetingPromptPolicy.decide(policy: MeetingPolicy(app: .teams, behavior: .autoTranscribeAndRecord), hour: 12)
                == .auto(record: true))
    }

    @Test func quietHoursFallBackToPromptNotSilence() {  // MTG-AC-06
        let policy = MeetingPolicy(app: .zoom, behavior: .autoTranscribeAndRecord, quietHours: 22...24)
        #expect(MeetingPromptPolicy.decide(policy: policy, hour: 22) == .prompt)
        #expect(MeetingPromptPolicy.decide(policy: policy, hour: 23.5) == .prompt)
        #expect(MeetingPromptPolicy.decide(policy: policy, hour: 21.99) == .auto(record: true))
        #expect(MeetingPromptPolicy.decide(policy: policy, hour: 0) == .auto(record: true))
    }

    @Test func quietHoursUpperBoundIsExclusive() {
        let policy = MeetingPolicy(app: .zoom, behavior: .autoTranscribe, quietHours: 9...17)
        #expect(MeetingPromptPolicy.decide(policy: policy, hour: 9) == .prompt)
        #expect(MeetingPromptPolicy.decide(policy: policy, hour: 16.99) == .prompt)
        #expect(MeetingPromptPolicy.decide(policy: policy, hour: 17) == .auto(record: false))
    }

    @Test func keywordExclusionFallsBackToPrompt() {  // MTG-AC-06
        let policy = MeetingPolicy(app: .teams, behavior: .autoTranscribe, excludedKeywords: ["1:1", "Therapy", " "])
        #expect(MeetingPromptPolicy.decide(policy: policy, hour: 12, title: "Weekly 1:1 with Sam") == .prompt)
        #expect(MeetingPromptPolicy.decide(policy: policy, hour: 12, title: "therapy session") == .prompt)
        #expect(MeetingPromptPolicy.decide(policy: policy, hour: 12, title: "Design review") == .auto(record: false))
        #expect(MeetingPromptPolicy.decide(policy: policy, hour: 12, title: nil) == .auto(record: false))
    }

    @Test func askFirstIgnoresExclusions() {
        let policy = MeetingPolicy(app: .zoom, behavior: .askFirst, quietHours: 0...24, excludedKeywords: ["x"])
        #expect(MeetingPromptPolicy.decide(policy: policy, hour: 3, title: "x") == .prompt)
    }

    @Test func notificationActionsMapToPolicyChanges() {
        #expect(MeetingPromptPolicy.behavior(after: .alwaysForApp) == .autoTranscribe)  // never auto-record
        #expect(MeetingPromptPolicy.behavior(after: .neverForApp) == .doNothing)
        #expect(MeetingPromptPolicy.behavior(after: .record) == nil)
        #expect(MeetingPromptPolicy.behavior(after: .transcribeOnly) == nil)
        #expect(MeetingPromptPolicy.behavior(after: .ignoreThisMeeting) == nil)
    }

    @Test func actionIdentifiersAreUniqueAndRoundTrip() {  // MTG-AC-04
        let ids = MeetingPromptAction.allCases.map(\.identifier)
        #expect(Set(ids).count == ids.count)
        for action in MeetingPromptAction.allCases { #expect(MeetingPromptAction(identifier: action.identifier) == action) }
        #expect(MeetingPromptAction(identifier: "com.apple.UNNotificationDefaultActionIdentifier") == nil)
        #expect(MeetingPromptAction.record.title(for: .zoom) == "Record")
        #expect(MeetingPromptAction.transcribeOnly.title(for: .zoom) == "Transcribe only")
        #expect(MeetingPromptAction.ignoreThisMeeting.title(for: .zoom) == "Ignore this meeting")
        #expect(MeetingPromptAction.alwaysForApp.title(for: .teams).contains("Teams"))
        #expect(MeetingPrompt(app: .zoom, startedAt: Date()).title == "Zoom meeting detected")
        #expect(MeetingPrompt.identifier(for: .zoom) != MeetingPrompt.identifier(for: .teams))
    }

    @Test func hourOfDateUsesFractionalLocalTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = Date(timeIntervalSince1970: 22 * 3600 + 30 * 60)
        #expect(MeetingPromptPolicy.hour(of: date, calendar: calendar) == 22.5)
    }
}

// MARK: - Live speaker display

@Suite struct LiveSpeakerDisplayTests {
    @Test func micIsYouAndNotProvisional() {  // MTG-AC-13
        let display = LiveSpeakerDisplay(line: CaptionLine(text: "hi", speakerLabel: "You", isVolatile: false))
        #expect(display.kind == .you && display.name == "You" && !display.isProvisional && display.slot == 0)
    }

    @Test func remoteSlotsAreProvisionalSpeakerN() {  // DIA-AC-03
        let display = LiveSpeakerDisplay(line: CaptionLine(text: "hi", speakerSlot: 1, isVolatile: true))
        #expect(display.kind == .remote && display.name == "Speaker 2" && display.isProvisional && display.slot == 2)
    }

    @Test func slotsBeyondTheLimitShowMoreSpeakers() {  // DIA-AC-04
        let at = LiveSpeakerDisplay(line: CaptionLine(text: "x", speakerSlot: maxLiveSpeakers - 1, isVolatile: false))
        #expect(at.kind == .remote)
        let over = LiveSpeakerDisplay(line: CaptionLine(text: "x", speakerSlot: maxLiveSpeakers, isVolatile: false))
        #expect(over.kind == .overflow && over.name == "More speakers" && over.isProvisional)
    }

    @Test func linesWithoutSpeakerInfoShowNoChip() {
        #expect(!LiveSpeakerDisplay(line: CaptionLine(text: "x", isVolatile: true)).isVisible)
    }
}

// MARK: - Consent

@Suite @MainActor struct MeetingConsentTests {
    @Test func noticeIsPendingUntilAcknowledgedThenNeverAgain() async {  // MTG-AC-11
        let store = InMemorySettingsStore()
        let first = MeetingConsentModel(store: store)
        await first.load()
        #expect(first.isPending)
        await first.acknowledge()
        #expect(!first.isPending)
        let second = MeetingConsentModel(store: store)  // a new model, e.g. next launch
        await second.load()
        #expect(!second.isPending)
    }

    @Test func settingsToggleAndNoticeShareOneFlag() async {
        let store = InMemorySettingsStore()
        let settings = MeetingsSettingsModel(store: store)
        await settings.load()
        #expect(settings.consentNotice.value)  // default: still to be shown
        let consent = MeetingConsentModel(store: store)
        await consent.acknowledge()
        let reloaded = MeetingsSettingsModel(store: store)
        await reloaded.load()
        #expect(!reloaded.consentNotice.value)
    }

    @Test func recordShowsNoticeFirstThenStartsOnceAcknowledged() async {
        let (model, capture, _, _) = make()
        await model.consent.load()
        await model.startCapture(.zoom, mode: .transcribeAndRecord)
        #expect(capture?.starts.isEmpty == true)
        #expect(model.pendingRecording == PendingRecording(app: .zoom, mode: .transcribeAndRecord))
        await model.confirmConsent()
        #expect(model.pendingRecording == nil)
        #expect(capture?.starts.count == 1 && capture?.starts.first?.1 == .transcribeAndRecord)
    }

    @Test func cancellingTheNoticeStartsNothingAndKeepsItPending() async {
        let (model, capture, _, _) = make()
        await model.startCapture(.zoom, mode: .transcribeAndRecord)
        model.cancelConsent()
        #expect(model.pendingRecording == nil && capture?.starts.isEmpty == true && model.consent.isPending)
    }

    @Test func noticeIsShownOnceAcrossModelInstances() async {
        let store = InMemorySettingsStore()
        let (first, firstCapture, _, _) = make(store: store)
        await first.startCapture(.zoom, mode: .transcribeAndRecord)
        await first.confirmConsent()
        #expect(firstCapture?.starts.count == 1)

        let (second, secondCapture, _, _) = make(store: store)
        await second.startCapture(.teams, mode: .transcribeAndRecord)
        #expect(second.pendingRecording == nil)  // no second notice
        #expect(secondCapture?.starts.count == 1)
    }

    @Test func transcribeOnlyNeverNeedsConsent() async {
        let (model, capture, _, _) = make()
        await model.startCapture(.zoom, mode: .transcribeOnly)
        #expect(model.pendingRecording == nil)
        #expect(capture?.starts.first?.1 == .transcribeOnly)
        #expect(model.consent.isPending)  // untouched
    }

    @Test func automaticRecordingRemindsOnceWithoutBlocking() async {  // MTG-AC-05
        let store = InMemorySettingsStore()
        await store.set(MeetingPolicy(app: .zoom, behavior: .autoTranscribeAndRecord), for: SettingsKey.meetingPolicy("zoom"))
        let (model, capture, prompter, _) = make(store: store)
        model.start()
        defer { model.stopFollowing() }
        try? await Task.sleep(for: .milliseconds(100))
        await model.handle(started(.zoom))
        #expect(capture?.starts.count == 1 && capture?.starts.first?.1 == .transcribeAndRecord)
        #expect(prompter?.reminders == [.zoom])
        #expect(prompter?.presented.isEmpty == true)  // started without prompting
        #expect(model.consentReminder == .zoom)
        // Next automatic meeting: no second reminder.
        #expect(await waitUntil { model.isRecording })
        await model.stopCapture()
        await model.handle(ended(.zoom))
        await model.handle(started(.zoom))
        #expect(capture?.starts.count == 2)
        #expect(prompter?.reminders == [.zoom])
    }
}

// MARK: - Detection and notification responses

@Suite @MainActor struct MeetingDetectionTests {
    @Test func askFirstShowsBannerAndNotificationOnce() async {  // MTG-AC-04
        let (model, capture, prompter, _) = make()
        await model.handle(started(.zoom))
        #expect(model.bannerDetections.map(\.app) == [.zoom])
        #expect(prompter?.presented.map(\.app) == [.zoom])
        await model.handle(started(.zoom))  // repeated started must not double-notify
        #expect(prompter?.presented.count == 1)
        #expect(capture?.starts.isEmpty == true)
    }

    @Test func doNothingShowsNoPromptAndNoBanner() async {
        let store = InMemorySettingsStore()
        await store.set(MeetingPolicy(app: .zoom, behavior: .doNothing), for: SettingsKey.meetingPolicy("zoom"))
        let (model, capture, prompter, _) = make(store: store)
        await model.handle(started(.zoom))
        #expect(model.bannerDetections.isEmpty && prompter?.presented.isEmpty == true && capture?.starts.isEmpty == true)
    }

    @Test func autoTranscribeStartsWithoutPrompting() async {
        let store = InMemorySettingsStore()
        await store.set(MeetingPolicy(app: .teams, behavior: .autoTranscribe), for: SettingsKey.meetingPolicy("teams"))
        let (model, capture, prompter, _) = make(store: store)
        await model.handle(started(.teams))
        #expect(capture?.starts.first?.0 == .teams && capture?.starts.first?.1 == .transcribeOnly)
        #expect(prompter?.presented.isEmpty == true)
    }

    @Test func autoRecordInQuietHoursFallsBackToAsking() async {  // MTG-AC-06
        let store = InMemorySettingsStore()
        await store.set(
            MeetingPolicy(app: .zoom, behavior: .autoTranscribeAndRecord, quietHours: 0...24), for: SettingsKey.meetingPolicy("zoom"))
        let (model, capture, prompter, _) = make(store: store)
        await model.handle(started(.zoom))
        #expect(capture?.starts.isEmpty == true)
        #expect(prompter?.presented.count == 1)
        #expect(model.bannerDetections.count == 1)
    }

    @Test func endingOneAppKeepsTheOthersDetection() async {
        let (model, _, prompter, _) = make()
        await model.handle(started(.zoom))
        await model.handle(started(.teams))
        await model.handle(ended(.teams))
        #expect(model.bannerDetections.map(\.app) == [.zoom])
        #expect(prompter?.withdrawn == [.teams])
    }

    @Test func endingWithdrawsTheNotificationAndClearsIgnoreSoTheNextMeetingPromptsAgain() async {
        let (model, _, prompter, _) = make()
        await model.handle(started(.zoom))
        await model.handle(MeetingPromptResponse(app: .zoom, action: .ignoreThisMeeting))
        #expect(model.bannerDetections.isEmpty)
        await model.handle(started(.zoom))  // same meeting reported again: still ignored
        #expect(prompter?.presented.count == 1)
        await model.handle(ended(.zoom))
        await model.handle(started(.zoom))  // a new meeting
        #expect(prompter?.presented.count == 2)
        #expect(model.bannerDetections.count == 1)
    }

    @Test func recordActionStartsRecordingAfterConsent() async {
        let (model, capture, _, _) = make()
        await model.handle(started(.zoom))
        await model.handle(MeetingPromptResponse(app: .zoom, action: .record))
        #expect(model.pendingRecording?.app == .zoom && capture?.starts.isEmpty == true)
        await model.confirmConsent()
        #expect(capture?.starts.first?.1 == .transcribeAndRecord)
    }

    @Test func transcribeOnlyActionStartsTranscribeOnly() async {
        let (model, capture, prompter, _) = make()
        await model.handle(started(.teams))
        await model.handle(MeetingPromptResponse(app: .teams, action: .transcribeOnly))
        #expect(capture?.starts.first?.0 == .teams && capture?.starts.first?.1 == .transcribeOnly)
        #expect(prompter?.withdrawn.contains(.teams) == true)
        #expect(model.bannerDetections.isEmpty)
    }

    @Test func ignoreThisMeetingDoesNotChangePolicy() async {
        let (model, capture, _, store) = make()
        await model.handle(started(.zoom))
        await model.handle(MeetingPromptResponse(app: .zoom, action: .ignoreThisMeeting))
        #expect(capture?.starts.isEmpty == true)
        #expect(await store.value(for: SettingsKey.meetingPolicy("zoom"), as: MeetingPolicy.self) == nil)
    }

    @Test func alwaysActionSetsAutoTranscribeNotAutoRecord() async {
        let (model, capture, _, store) = make()
        await model.handle(started(.zoom))
        await model.handle(MeetingPromptResponse(app: .zoom, action: .alwaysForApp))
        let stored = await store.value(for: SettingsKey.meetingPolicy("zoom"), as: MeetingPolicy.self)
        #expect(stored?.behavior == .autoTranscribe)
        #expect(capture?.starts.first?.1 == .transcribeOnly)
    }

    @Test func neverActionWritesPolicyThatSettingsSees() async {
        let (model, capture, _, store) = make()
        await model.handle(started(.teams))
        await model.handle(MeetingPromptResponse(app: .teams, action: .neverForApp))
        #expect(capture?.starts.isEmpty == true && model.bannerDetections.isEmpty)
        let settings = MeetingsSettingsModel(store: store)
        await settings.load()
        #expect(settings.policy(for: .teams).behavior == .doNothing)
        #expect(settings.policy(for: .zoom).behavior == .askFirst)
        // The next Teams meeting is silent.
        await model.handle(ended(.teams))
        await model.handle(started(.teams))
        #expect(model.bannerDetections.isEmpty)
    }

    @Test func tappingTheNotificationBringsMeetingsForward() async {
        let (model, _, _, _) = make()
        var navigated = 0
        model.navigate = { navigated += 1 }
        await model.handle(MeetingPromptResponse(app: .zoom, action: nil))
        #expect(navigated == 1)
    }

    @Test func toggleAutoRecordFlipsPolicyAndShowsState() async {  // MTG-AC-17
        let (model, _, _, _) = make()
        await model.toggleAutoRecord(for: .zoom)
        #expect(model.policy(for: .zoom).behavior == .autoTranscribeAndRecord)
        await model.toggleAutoRecord(for: .zoom)
        #expect(model.policy(for: .zoom).behavior == .askFirst)
    }
}

// MARK: - Capture control

@Suite @MainActor struct MeetingCaptureTests {
    @Test func captureStateAndLinesAreFollowedWhileRunning() async {
        let detector = BroadcastDetector()
        let (model, capture, _, _) = make(detector: detector)
        model.start()
        defer { model.stopFollowing() }
        try? await Task.sleep(for: .milliseconds(100))
        detector.bus.send(started(.zoom))
        #expect(await waitUntil { model.detections[.zoom] != nil })
        await model.startCapture(.zoom, mode: .transcribeOnly)
        #expect(await waitUntil { model.currentMeeting?.phase != .detected && model.captureState.isActive })
        capture?.emit([CaptionLine(text: "hello", speakerLabel: "You", isVolatile: false)])
        #expect(await waitUntil { model.lines.count == 1 })
        #expect(model.bannerDetections.isEmpty)
    }

    @Test func promptResponsesAreHandledWithoutTheViewBeingOnScreen() async {
        let detector = BroadcastDetector()
        let (model, capture, prompter, _) = make(detector: detector)
        model.start()
        defer { model.stopFollowing() }
        try? await Task.sleep(for: .milliseconds(100))
        detector.bus.send(started(.zoom))
        #expect(await waitUntil { prompter?.presented.count == 1 })
        prompter?.respond(MeetingPromptResponse(app: .zoom, action: .transcribeOnly))
        #expect(await waitUntil { capture?.starts.count == 1 })
    }

    @Test func stopCaptureReturnsTheTranscriptAndClears() async {
        let (model, capture, _, _) = make()
        model.start()
        defer { model.stopFollowing() }
        try? await Task.sleep(for: .milliseconds(100))
        await model.startCapture(.zoom, mode: .transcribeOnly)
        #expect(await waitUntil { if case .capturing = model.captureState { true } else { false } })
        await model.stopCapture()
        #expect(model.finishedTranscriptID == capture?.transcriptID)
        #expect(model.captureState == .idle)
    }

    @Test func failureToStartIsReportedInline() async {
        let capture = FakeCapture(failure: .cancelled)
        let (model, _, _, _) = make(capture: capture)
        await model.startCapture(.zoom, mode: .transcribeOnly)
        #expect(model.actionError != nil)
        if case .failed = model.captureState {} else { Issue.record("expected failed state") }
        model.dismissError()
        #expect(model.actionError == nil && model.captureState == .idle)
    }

    @Test func onlyOneCaptureAtATime() async {
        let (model, capture, _, _) = make()
        await model.startCapture(.zoom, mode: .transcribeOnly)
        await model.startCapture(.teams, mode: .transcribeOnly)
        #expect(capture?.starts.count == 1)
    }

    @Test func recordingWithoutTheRecorderExplainsInsteadOfFailingSilently() async {
        let store = InMemorySettingsStore()
        await store.set(false, for: SettingsKey.meetingConsentNotice)
        let (model, _, _, _) = make(store: store, capture: nil)
        await model.startCapture(.zoom, mode: .transcribeAndRecord)
        #expect(model.actionError != nil && model.captureState == .idle)
    }

    @Test func transcribeOnlyFallsBackToLiveSessionWhenNoRecorderIsWired() async {
        let (model, _, _, _) = make(capture: nil)
        await model.startCapture(.zoom, mode: .transcribeOnly)
        if case .capturing(.zoom, .transcribeOnly, _) = model.captureState {} else { Issue.record("expected capturing") }
        await model.stopCapture()
        #expect(model.captureState == .idle)
    }
}

// MARK: - List

@Suite @MainActor struct MeetingsListTests {
    @Test func rowsCombineMeetingTranscriptAndRecording() async {  // MTG-AC-18
        let speakers = [Speaker(name: "You", colorHex: "#000000"), Speaker(name: "Speaker 1", colorHex: "#111111")]
        let transcript = Transcript(title: "Weekly product sync", source: .meeting, speakers: speakers)
        let recorded = Meeting(
            app: .zoom, startedAt: Date(timeIntervalSince1970: 2_000), endedAt: Date(timeIntervalSince1970: 2_600),
            transcriptID: transcript.id,
            recording: Recording(
                tracks: [
                    RecordingTrack(role: .mic, relativePath: "m.m4a"), RecordingTrack(role: .remote, relativePath: "r.m4a"),
                    RecordingTrack(role: .video, relativePath: "v.mov"),
                ], duration: 540))
        let plain = Meeting(app: .teams, startedAt: Date(timeIntervalSince1970: 1_000), endedAt: Date(timeIntervalSince1970: 1_300))
        let (model, _, _, _) = make(meetings: [plain, recorded], transcripts: [transcript])
        await model.load()
        #expect(model.rows.map(\.meeting.app) == [.zoom, .teams])  // newest first
        let first = model.rows[0]
        #expect(first.title == "Weekly product sync" && first.speakerCount == 2)
        #expect(first.capturesDescription == "Mic + system audio, video" && first.isRecorded && first.duration == 540)
        let second = model.rows[1]
        #expect(second.title == "Teams meeting" && second.capturesDescription == "Transcript only" && second.duration == 300)
        #expect(!model.isLoading)
    }

    @Test func policyChipsReflectStoredBehaviour() async {
        let store = InMemorySettingsStore()
        await store.set(MeetingPolicy(app: .teams, behavior: .autoTranscribeAndRecord), for: SettingsKey.meetingPolicy("teams"))
        let (model, _, _, _) = make(store: store)
        await model.load()
        #expect(model.policy(for: .zoom).behavior == .askFirst)
        #expect(model.policy(for: .teams).behavior == .autoTranscribeAndRecord)
        #expect(MeetingBehavior.askFirst.title == "Ask first" && MeetingApp.teams.title == "Microsoft Teams")
    }
}
