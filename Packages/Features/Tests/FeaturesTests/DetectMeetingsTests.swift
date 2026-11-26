import AppCore
import FeatureMeetings
import FeatureSupport
import Foundation
import Testing
import os

final class FakeScanner: MeetingScanning {
    private let current = OSAllocatedUnfairLock(initialState: MeetingScanResult())
    private let bus = Broadcaster<MeetingScanResult>()
    let subscriptions = SubscriptionCount()
    let scans = OSAllocatedUnfairLock(initialState: 0)
    init(_ result: MeetingScanResult = MeetingScanResult()) { current.withLock { $0 = result } }
    func set(_ result: MeetingScanResult) { current.withLock { $0 = result } }
    func publish(_ result: MeetingScanResult) {
        set(result)
        bus.send(result)
    }
    func scan() async -> MeetingScanResult {
        scans.withLock { $0 += 1 }
        return current.withLock { $0 }
    }
    func results() -> AsyncStream<MeetingScanResult> {
        subscriptions.hit()
        return bus.stream()
    }
}

private let zoomCall = LiveMeetingCandidate(id: "zoom", app: .zoom, label: "Zoom", detail: "Call audio is running")
private let meetCall = LiveMeetingCandidate(
    id: "meet.com.google.Chrome", app: .meet, label: "Google Meet in Chrome", detail: "Microphone in use and a Meet window is open",
    targetBundleID: "com.google.Chrome")

@MainActor
private func make(scanner: FakeScanner?, capture: FakeCapture = FakeCapture()) -> (MeetingsModel, FakeCapture) {
    var services = AppServices.preview()
    services.meetingCapture = capture
    services.meetingScanner = scanner
    return (MeetingsModel(services: services), capture)
}

@MainActor
@Suite("Detect meetings", .serialized)
struct DetectMeetingsTests {
    @Test func listsLiveCallsAndKeepsThemLive() async {
        let scanner = FakeScanner(MeetingScanResult(candidates: [zoomCall]))
        let (model, _) = make(scanner: scanner)
        model.start()
        #expect(await eventually { model.available.map(\.id) == ["zoom"] && scanner.subscriptions.value > 0 })
        scanner.publish(MeetingScanResult(candidates: [zoomCall, meetCall]))
        #expect(await eventually { model.available.count == 2 })
        scanner.publish(MeetingScanResult(candidates: []))
        #expect(await eventually { model.available.isEmpty })
        model.stopFollowing()
    }

    @Test func detectRescansAndReportsWhatItFound() async {
        let scanner = FakeScanner(MeetingScanResult(candidates: [meetCall]))
        let (model, _) = make(scanner: scanner)
        await model.detect()
        #expect(model.available == [meetCall])
        #expect(!model.detectFoundNothing)
        #expect(!model.isDetecting)
        #expect(scanner.scans.withLock { $0 } == 1)
    }

    @Test func nothingFoundKeepsTheNotesAndCanBeDismissed() async {
        let notes = ["Zoom: not running", "Chrome: open, microphone not in use"]
        let scanner = FakeScanner(MeetingScanResult(notes: notes))
        let (model, _) = make(scanner: scanner)
        await model.detect()
        #expect(model.available.isEmpty)
        #expect(model.detectFoundNothing)
        #expect(model.scanNotes == notes)
        model.dismissDetectResult()
        #expect(!model.detectFoundNothing)
    }

    @Test func accessibilityHintIsCarriedFromTheScan() async {
        let scanner = FakeScanner(MeetingScanResult(candidates: [LiveMeetingCandidate(id: "browser.x", app: .browser, label: "Browser call in Chrome", detail: "Microphone in use")], needsAccessibilityForMeet: true))
        let (model, _) = make(scanner: scanner)
        await model.detect()
        #expect(model.needsAccessibilityForMeet)
    }

    @Test func choosingAListedCallStartsItWithItsSource() async throws {
        let (model, capture) = make(scanner: FakeScanner(MeetingScanResult(candidates: [meetCall])))
        await model.startCapture(meetCall, mode: .transcribeOnly)
        #expect(capture.starts.map(\.0) == [.meet])
        #expect(capture.targets == ["com.google.Chrome"])
    }

    @Test func aListedCallIgnoresAnEarlierDoNothingPolicy() async {
        let (model, capture) = make(scanner: FakeScanner())
        await model.setBehavior(.doNothing, for: .zoom)
        await model.startCapture(zoomCall, mode: .transcribeOnly)
        #expect(capture.starts.map(\.0) == [.zoom])
    }

    @Test func detectWithoutAScannerIsHarmless() async {
        let (model, _) = make(scanner: nil)
        await model.detect()
        #expect(model.available.isEmpty)
        #expect(!model.isDetecting)
    }

    @Test func aSecondCallWhileCapturingIsNotStarted() async {
        let (model, capture) = make(scanner: FakeScanner())
        await model.startCapture(zoomCall, mode: .transcribeOnly)
        capture.emit(.capturing(.zoom, mode: .transcribeOnly, since: Date()))
        model.start()
        #expect(await eventually { model.captureState.isActive })
        await model.startCapture(meetCall, mode: .transcribeOnly)
        #expect(capture.starts.count == 1)
        model.stopFollowing()
    }
}
