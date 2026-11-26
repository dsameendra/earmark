import AppCore
import Foundation
import Testing

@testable import Meetings

@Suite("Meet window titles")
struct MeetTitleTests {
    @Test("accepts call tab titles with the browser name appended")
    func accepts() {
        #expect(MeetTitle.isMeetCall("Meet - abc-defg-hij"))
        #expect(MeetTitle.isMeetCall("Meet – abc-defg-hij - Google Chrome - Work"))
        #expect(MeetTitle.isMeetCall("Meet - xyz-abcd-efg — Mozilla Firefox"))
        #expect(MeetTitle.isMeetCall("meet - abc-defg-hij"))
    }

    @Test("rejects the landing page and unrelated titles")
    func rejects() {
        #expect(!MeetTitle.isMeetCall("Google Meet"))
        #expect(!MeetTitle.isMeetCall("Meet new people - abc"))
        #expect(!MeetTitle.isMeetCall("abc-defg-hij"))  // a code without the word Meet
        #expect(!MeetTitle.isMeetCall("Meet - ABC-DEFG-HIJK"))  // wrong shape
        #expect(!MeetTitle.isMeetCall(""))
        #expect(!MeetTitle.isMeetCall("Inbox (3) - someone@example.com"))
    }
}

@Suite("Signatures")
struct SignatureTests {
    @Test("Discord matches its helpers and its Canary and PTB builds, case-insensitively")
    func discord() throws {
        let signature = try #require(MeetingAppSignature.defaults.first { $0.app == .discord })
        #expect(signature.matches("com.hnc.Discord"))
        #expect(signature.matches("com.hnc.Discord.helper"))
        #expect(signature.matches("com.hnc.DiscordCanary"))
        #expect(!signature.matches("com.hnc.Other"))
    }

    @Test("browser helpers match regardless of case (Arc names them in lower case)")
    func browserHelpers() throws {
        let arc = try #require(BrowserSignature.defaults.first { $0.name == "Arc" })
        #expect(arc.matches("company.thebrowser.Browser"))
        #expect(arc.matches("company.thebrowser.browser.helper"))
        let chrome = try #require(BrowserSignature.defaults.first { $0.name == "Chrome" })
        #expect(chrome.matches("com.google.Chrome.helper"))
        #expect(!chrome.matches("com.google.Keystone"))
    }

    @Test("Safari is listed but never detected automatically")
    func safariIsManual() throws {
        let safari = try #require(BrowserSignature.defaults.first { $0.name == "Safari" })
        #expect(!safari.detectsAutomatically)
        #expect(BrowserSignature.defaults.filter(\.detectsAutomatically).count == BrowserSignature.defaults.count - 1)
    }

    @Test("MeetingApp watches four apps and keeps browser calls manual")
    func appSet() {
        #expect(MeetingApp.allCases == [.zoom, .teams, .meet, .discord])
        #expect(!MeetingApp.allCases.contains(.browser))
    }

    @Test("Discord's default end grace is longer; the others keep 15 s")
    func graceDefaults() {
        #expect(MeetingPolicy(app: .discord).autoStopGraceSeconds == 30)
        #expect(MeetingPolicy(app: .zoom).autoStopGraceSeconds == 15)
        #expect(MeetingPolicy(app: .meet, autoStopGraceSeconds: 40).autoStopGraceSeconds == 40)
    }

    @Test("new MeetingApp values round-trip and unknown ones are rejected")
    func codable() throws {
        for app in [MeetingApp.zoom, .teams, .meet, .discord, .browser] {
            let data = try JSONEncoder().encode(app)
            #expect(try JSONDecoder().decode(MeetingApp.self, from: data) == app)
        }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(MeetingApp.self, from: Data(#""webex""#.utf8)) }
    }
}

@Suite("Detect meetings scan", .timeLimit(.minutes(1)))
struct ScanTests {
    private func make() async -> (ProbeMeetingDetector, FakeProbe) {
        let probe = FakeProbe()
        let detector = ProbeMeetingDetector(probe: probe, clock: ManualClock(), config: MeetingDetectorConfig())
        return (detector, probe)
    }

    private let chrome = BrowserSignature.defaults.first { $0.name == "Chrome" }!
    private let safari = BrowserSignature.defaults.first { $0.name == "Safari" }!
    private let firefox = BrowserSignature.defaults.first { $0.name == "Firefox" }!

    @Test("finds a Zoom call immediately, without the start debounce")
    func zoomImmediately() async {
        let (detector, probe) = await make()
        probe.set(.zoom, .inCall)
        let scan = await detector.scan()
        #expect(scan.calls.map(\.app) == [.zoom])
        #expect(scan.calls.first?.label == "Zoom")
    }

    @Test("a muted listen-only call is found too")
    func mutedCall() async {
        let (detector, probe) = await make()
        probe.set(.teams, .muted)
        #expect(await detector.scan().calls.map(\.app) == [.teams])
    }

    @Test("Discord is found only with the microphone open, never from playback alone")
    func discordNeedsMic() async {
        let (detector, probe) = await make()
        probe.set(.discord, AppAudioActivity(isAppRunning: true, micInput: false, audioOutput: true))
        #expect(await detector.scan().calls.isEmpty)
        probe.set(.discord, AppAudioActivity(isAppRunning: true, micInput: true, audioOutput: false))
        #expect(await detector.scan().calls.map(\.app) == [.discord])
    }

    @Test("a browser with the microphone open and a Meet window is a Meet call in that browser")
    func meetCall() async {
        let (detector, probe) = await make()
        probe.setBrowsers([BrowserReading(browser: chrome, isRunning: true, micInput: true, audioOutput: true, meetWindowOpen: true)])
        let call = await detector.scan().calls.first
        #expect(call?.app == .meet)
        #expect(call?.label == "Google Meet in Chrome")
        #expect(call?.captureBundleID == "com.google.Chrome")
    }

    @Test("without a Meet window the call is a plain browser call, and Accessibility is suggested when titles cannot be read")
    func browserCall() async {
        let (detector, probe) = await make()
        probe.setBrowsers([BrowserReading(browser: firefox, isRunning: true, micInput: true)], canReadTitles: false)
        let scan = await detector.scan()
        #expect(scan.calls.first?.app == .browser)
        #expect(scan.calls.first?.label == "Browser call in Firefox")
        #expect(scan.needsAccessibilityForMeet)
        probe.setBrowsers([BrowserReading(browser: firefox, isRunning: true, micInput: true)], canReadTitles: true)
        #expect(await detector.scan().needsAccessibilityForMeet == false)
    }

    @Test("Safari appears as a browser call the user can pick")
    func safariListed() async {
        let (detector, probe) = await make()
        probe.setBrowsers([BrowserReading(browser: safari, isRunning: true, micInput: true)])
        #expect(await detector.scan().calls.first?.label == "Browser call in Safari")
    }

    @Test("two sources are both listed")
    func several() async {
        let (detector, probe) = await make()
        probe.set(.zoom, .inCall)
        probe.setBrowsers([BrowserReading(browser: chrome, isRunning: true, micInput: true, audioOutput: true, meetWindowOpen: true)])
        #expect(Set(await detector.scan().calls.map(\.app)) == [.zoom, .meet])
    }

    @Test("an idle browser is not a call and nothing found explains what was seen")
    func nothingFound() async {
        let (detector, probe) = await make()
        probe.set(.zoom, .runningIdle)
        probe.setBrowsers([BrowserReading(browser: chrome, isRunning: true)])
        let scan = await detector.scan()
        #expect(scan.calls.isEmpty)
        #expect(scan.notes.contains("Zoom: running, no call audio"))
        #expect(scan.notes.contains("Chrome: open, microphone not in use"))
        #expect(scan.notes.contains("Discord: not running"))
    }

    @Test("no supported browser open is reported")
    func noBrowsers() async {
        let (detector, _) = await make()
        #expect(await detector.scan().notes.contains("No supported browser is open"))
    }
}

@Suite("Discord detection", .timeLimit(.minutes(1)))
struct DiscordDetectionTests {
    @Test("playback alone never starts a Discord meeting, microphone plus playback does")
    func outputOnlyNeverStartsDiscord() async {
        let probe = FakeProbe()
        let clock = ManualClock()
        let detector = ProbeMeetingDetector(probe: probe, clock: clock, config: MeetingDetectorConfig(startDebounce: 3))
        let events = Collector(detector.events())
        await detector.start()
        defer { withExtendedLifetime(detector) {} }
        probe.set(.discord, AppAudioActivity(isAppRunning: true, micInput: false, audioOutput: true))
        await clock.waitForSleepers(1)
        clock.advance(by: 20)
        #expect(await events.settled().isEmpty)
        probe.set(.discord, .inCall)
        await clock.waitForSleepers(1)
        clock.advance(by: 3.1)
        await events.waitFor(count: 1)
        #expect(events.items.first.map { if case .started(.discord, _) = $0 { true } else { false } } == true)
    }
}
