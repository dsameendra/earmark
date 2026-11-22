import AppCore
import AppKit
import Foundation
import Testing

@testable import Meetings

@Suite("Meeting detector", .timeLimit(.minutes(1)))
struct DetectorTests {
    private func make(
        grace: @escaping @Sendable (MeetingApp) async -> TimeInterval = { _ in 15 }
    ) async -> (ProbeMeetingDetector, FakeProbe, ManualClock, Collector<MeetingEvent>) {
        let probe = FakeProbe()
        let clock = ManualClock()
        let detector = ProbeMeetingDetector(probe: probe, clock: clock, config: MeetingDetectorConfig(startDebounce: 3, endGrace: grace))
        let collector = Collector(detector.events())
        await detector.start()
        return (detector, probe, clock, collector)
    }

    // MTG-AC-01
    @Test("emits started once after the debounce")
    func startsAfterDebounce() async {
        let (detector, probe, clock, events) = await make()
        defer { withExtendedLifetime(detector) {} }
        probe.set(.zoom, .inCall)
        await clock.waitForSleepers(1)
        clock.advance(by: 2.9)
        #expect(await events.settled().isEmpty)
        clock.advance(by: 0.2)
        await events.waitFor(count: 1)
        let items = await events.settled()
        #expect(items.count == 1)
        guard case .started(let app, _)? = items.first else {
            Issue.record("expected started")
            return
        }
        #expect(app == .zoom)
    }

    @Test("started carries the time the call began, not the confirmation time")
    func startTimestamp() async {
        let (detector, probe, clock, events) = await make()
        defer { withExtendedLifetime(detector) {} }
        let begin = clock.now()
        probe.set(.teams, .inCall)
        await clock.waitForSleepers(1)
        clock.advance(by: 3)
        await events.waitFor(count: 1)
        #expect(events.items.first == .started(.teams, at: begin))
    }

    @Test("signal dropping before the debounce expires cancels the start")
    func flappingBeforeDebounce() async {
        let (detector, probe, clock, events) = await make()
        defer { withExtendedLifetime(detector) {} }
        probe.set(.zoom, .inCall)
        await clock.waitForSleepers(1)
        clock.advance(by: 2)
        probe.set(.zoom, .runningIdle)
        await clock.waitForSleepers(0)
        clock.advance(by: 30)
        #expect(await events.settled().isEmpty)
    }

    @Test("output only (no mic) does not start a meeting")
    func outputOnlyDoesNotStart() async {
        let (detector, probe, clock, events) = await make()
        defer { withExtendedLifetime(detector) {} }
        probe.set(.zoom, .muted)
        try? await Task.sleep(for: .milliseconds(40))
        #expect(clock.sleeperCount == 0)
        clock.advance(by: 60)
        #expect(await events.settled().isEmpty)
    }

    @Test("a running but idle app emits nothing")
    func runningIdle() async {
        let (detector, probe, clock, events) = await make()
        defer { withExtendedLifetime(detector) {} }
        probe.set(.zoom, .runningIdle)
        clock.advance(by: 100)
        #expect(await events.settled().isEmpty)
    }

    // MTG-AC-02
    @Test("emits ended only after the grace period without activity")
    func endsAfterGrace() async {
        let (detector, probe, clock, events) = await make()
        defer { withExtendedLifetime(detector) {} }
        probe.set(.zoom, .inCall)
        await clock.waitForSleepers(1)
        clock.advance(by: 3)
        await events.waitFor(count: 1)
        let inactiveAt = clock.now()
        probe.set(.zoom, .runningIdle)
        await clock.waitForSleepers(1)
        clock.advance(by: 14)
        #expect(await events.settled().count == 1)
        clock.advance(by: 1)
        await events.waitFor(count: 2)
        let items = await events.settled()
        #expect(items.count == 2)
        #expect(items.last == .ended(.zoom, at: inactiveAt))
    }

    @Test("muting (mic released, audio continues) neither ends nor re-emits")
    func muteDoesNotFlap() async {
        let (detector, probe, clock, events) = await make()
        defer { withExtendedLifetime(detector) {} }
        probe.set(.zoom, .inCall)
        await clock.waitForSleepers(1)
        clock.advance(by: 3)
        await events.waitFor(count: 1)
        probe.set(.zoom, .muted)
        probe.set(.zoom, .inCall)
        probe.set(.zoom, .muted)
        clock.advance(by: 120)
        let items = await events.settled()
        #expect(items.count == 1)
        #expect(await detector.activeApps() == [.zoom])
    }

    @Test("activity returning during the grace period keeps the same meeting")
    func returnDuringGrace() async {
        let (detector, probe, clock, events) = await make()
        defer { withExtendedLifetime(detector) {} }
        probe.set(.zoom, .inCall)
        await clock.waitForSleepers(1)
        clock.advance(by: 3)
        await events.waitFor(count: 1)
        probe.set(.zoom, AppAudioActivity.runningIdle)
        await clock.waitForSleepers(1)
        clock.advance(by: 10)
        probe.set(.zoom, .inCall)
        await clock.waitForSleepers(0)
        clock.advance(by: 60)
        #expect(await events.settled().count == 1)
    }

    @Test("a second meeting after the first ended starts again")
    func secondMeeting() async {
        let (detector, probe, clock, events) = await make()
        defer { withExtendedLifetime(detector) {} }
        for round in 1...2 {
            probe.set(.zoom, .inCall)
            await clock.waitForSleepers(1)
            clock.advance(by: 3)
            await events.waitFor(count: round * 2 - 1)
            probe.set(.zoom, .inCall)
            probe.set(.zoom, .runningIdle)
            await clock.waitForSleepers(1)
            clock.advance(by: 15)
            await events.waitFor(count: round * 2)
        }
        let items = await events.settled()
        #expect(items.count == 4)
        #expect(items.map { if case .started = $0 { "s" } else { "e" } } == ["s", "e", "s", "e"])
    }

    @Test("two apps are tracked independently")
    func twoApps() async {
        let (detector, probe, clock, events) = await make()
        defer { withExtendedLifetime(detector) {} }
        probe.set(.zoom, .inCall)
        probe.set(.teams, .inCall)
        await clock.waitForSleepers(2)
        clock.advance(by: 3)
        await events.waitFor(count: 2)
        #expect(await detector.activeApps() == [.zoom, .teams])
        probe.set(.teams, .inCall)
        probe.set(.zoom, .runningIdle)
        await clock.waitForSleepers(1)
        clock.advance(by: 15)
        await events.waitFor(count: 3)
        let items = await events.settled()
        #expect(items.count == 3)
        #expect(items.last.map { if case .ended(.zoom, _) = $0 { true } else { false } } == true)
        #expect(await detector.activeApps() == [.teams])
    }

    @Test("grace period comes from the per-app policy")
    func perAppGrace() async {
        let (detector, probe, clock, events) = await make(grace: { app in app == .zoom ? 5 : 60 })
        defer { withExtendedLifetime(detector) {} }
        probe.set(.zoom, .inCall)
        await clock.waitForSleepers(1)
        clock.advance(by: 3)
        await events.waitFor(count: 1)
        probe.set(.zoom, .runningIdle)
        await clock.waitForSleepers(1)
        clock.advance(by: 5)
        await events.waitFor(count: 2)
        #expect(await events.settled().count == 2)
    }

    @Test("the app quitting counts as inactivity")
    func appQuits() async {
        let (detector, probe, clock, events) = await make()
        defer { withExtendedLifetime(detector) {} }
        probe.set(.teams, .inCall)
        await clock.waitForSleepers(1)
        clock.advance(by: 3)
        await events.waitFor(count: 1)
        probe.set(.teams, .inactive)
        await clock.waitForSleepers(1)
        clock.advance(by: 15)
        await events.waitFor(count: 2)
        #expect(await events.settled().count == 2)
    }

    // MTG-AC-20
    @Test("an idle detector holds no timers")
    func noTimersWhenIdle() async {
        let (detector, probe, clock, _) = await make()
        defer { withExtendedLifetime(detector) {} }
        #expect(clock.sleeperCount == 0)
        probe.set(.zoom, .runningIdle)
        probe.set(.teams, .inactive)
        try? await Task.sleep(for: .milliseconds(40))
        #expect(clock.sleeperCount == 0)
        await detector.stop()
    }

    @Test("device corroboration can be required")
    func deviceCorroboration() async {
        let probe = FakeProbe()
        let clock = ManualClock()
        let detector = ProbeMeetingDetector(
            probe: probe, clock: clock, config: MeetingDetectorConfig(requireDeviceCorroboration: true))
        defer { withExtendedLifetime(detector) {} }
        let events = Collector(detector.events())
        await detector.start()
        probe.set(.zoom, AppAudioActivity(isAppRunning: true, micInput: true, audioOutput: true, deviceMicInUse: false))
        try? await Task.sleep(for: .milliseconds(40))
        #expect(clock.sleeperCount == 0)
        probe.set(.zoom, .inCall)
        await clock.waitForSleepers(1)
        clock.advance(by: 3)
        await events.waitFor(count: 1)
        #expect(await events.settled().count == 1)
    }
}

// MARK: - Real probe

@Suite("Core Audio probe")
struct RealProbeTests {
    @Test("signatures match helper bundle ids by prefix")
    func signatures() {
        let zoom = MeetingAppSignature.defaults.first { $0.app == .zoom }!
        let teams = MeetingAppSignature.defaults.first { $0.app == .teams }!
        #expect(zoom.matches("us.zoom.xos"))
        #expect(zoom.matches("us.zoom.xos.helper"))
        #expect(!zoom.matches("com.microsoft.teams2"))
        #expect(teams.matches("com.microsoft.teams2"))
        #expect(teams.matches("com.microsoft.teams2.helper.renderer"))
        #expect(!teams.matches("us.zoom.xos"))
        #expect(MeetingApp.zoom.bundleIDs.allSatisfy(zoom.matches))
        #expect(MeetingApp.teams.bundleIDs.allSatisfy(teams.matches))
    }

    @Test("reading the live system never crashes and an absent app is inactive")
    func readsSystem() async {
        let probe = CoreAudioMeetingProbe(signatures: [MeetingAppSignature(app: .teams, bundleIDPrefixes: ["com.example.no-such-app"])])
        #expect(await probe.activity(for: .teams) == .inactive)
        #expect(await probe.activity(for: .zoom) == .inactive)  // no signature configured
        var iterator = probe.changes().makeAsyncIterator()
        _ = await iterator.next()  // listener attach signals once
    }

    @Test(
        "installed Zoom has the bundle id the detector expects",
        .enabled(if: FileManager.default.fileExists(atPath: "/Applications/zoom.us.app")))
    func zoomBundleID() {
        #expect(Bundle(path: "/Applications/zoom.us.app")?.bundleIdentifier == "us.zoom.xos")
    }

    /// Opt-in: `EARMARK_ZOOM_PROBE=1 swift test --filter RealProbeTests`. Start or quit Zoom (and join a test meeting)
    /// while it runs and read the printed snapshots; this is how the real call signal gets verified.
    @Test(
        "live Zoom snapshot (opt-in)",
        .enabled(if: ProcessInfo.processInfo.environment["EARMARK_ZOOM_PROBE"] == "1"))
    func liveZoom() async {
        let probe = CoreAudioMeetingProbe()
        let running = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "us.zoom.xos" }
        let activity = await probe.activity(for: .zoom)
        print("EARMARK_ZOOM_PROBE running=\(running) activity=\(activity)")
        #expect(activity.isAppRunning == running)
        if !running { #expect(!activity.micInput && !activity.audioOutput) }
    }
}
