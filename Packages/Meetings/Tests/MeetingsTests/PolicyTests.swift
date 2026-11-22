import AppCore
import Foundation
import Testing

@testable import Meetings

private func date(hour: Int) -> Date {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(secondsFromGMT: 0)!
    return c.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: hour, minute: 30))!
}
private var gmt: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(secondsFromGMT: 0)!
    return c
}

@Suite("Meeting policy")
struct PolicyTests {
    // MTG-AC-03
    @Test("default policy is askFirst for both apps and an empty store yields it")
    func defaultsAskFirst() async {
        let store = MeetingPolicyStore(store: InMemorySettings())
        for app in MeetingApp.allCases {
            #expect(MeetingPolicy(app: app).behavior == .askFirst)
            let policy = await store.policy(for: app)
            #expect(policy.behavior == .askFirst)
            let decision = await store.decide(for: app, now: date(hour: 12), calendar: gmt)
            #expect(decision.action == .promptUser)
        }
    }

    // MTG-AC-05 / MTG-AC-06 matrix: behavior x (clear | quiet hours | excluded title)
    struct Row: Sendable {
        var behavior: MeetingBehavior
        var hour: Int
        var title: String?
        var action: MeetingAction
        var reason: MeetingDecisionReason
    }
    static let matrix: [Row] = [
        Row(behavior: .doNothing, hour: 12, title: nil, action: .ignore, reason: .configured),
        Row(behavior: .doNothing, hour: 23, title: "Board review", action: .ignore, reason: .configured),
        Row(behavior: .askFirst, hour: 12, title: nil, action: .promptUser, reason: .configured),
        Row(behavior: .askFirst, hour: 23, title: nil, action: .promptUser, reason: .configured),
        Row(behavior: .autoTranscribe, hour: 12, title: "Standup", action: .transcribe, reason: .configured),
        Row(behavior: .autoTranscribe, hour: 23, title: "Standup", action: .promptUser, reason: .quietHours),
        Row(behavior: .autoTranscribe, hour: 12, title: "Board review", action: .promptUser, reason: .excludedKeyword("board")),
        Row(behavior: .autoTranscribeAndRecord, hour: 12, title: "Standup", action: .transcribeAndRecord, reason: .configured),
        Row(behavior: .autoTranscribeAndRecord, hour: 23, title: "Standup", action: .promptUser, reason: .quietHours),
        Row(behavior: .autoTranscribeAndRecord, hour: 12, title: "Board review", action: .promptUser, reason: .excludedKeyword("board")),
        Row(behavior: .autoTranscribeAndRecord, hour: 23, title: "Board review", action: .promptUser, reason: .excludedKeyword("board")),
        Row(behavior: .autoTranscribeAndRecord, hour: 12, title: nil, action: .transcribeAndRecord, reason: .configured),
    ]

    @Test("behavior matrix with quiet hours and keyword exclusions", arguments: matrix)
    func matrixRows(row: Row) {
        let policy = MeetingPolicy(app: .zoom, behavior: row.behavior, quietHours: 22...24, excludedKeywords: ["board"])
        let decision = MeetingPolicyEngine.decide(policy: policy, now: date(hour: row.hour), title: row.title, calendar: gmt)
        #expect(decision.action == row.action)
        #expect(decision.reason == row.reason)
    }

    @Test("quiet hours are half-open at both ends")
    func quietBoundaries() {
        let policy = MeetingPolicy(app: .teams, behavior: .autoTranscribe, quietHours: 9...17)
        func action(_ hour: Int) -> MeetingAction {
            MeetingPolicyEngine.decide(policy: policy, now: date(hour: hour), calendar: gmt).action
        }
        #expect(action(8) == .transcribe)
        #expect(action(9) == .promptUser)
        #expect(action(16) == .promptUser)
        #expect(action(17) == .transcribe)
        let late = MeetingPolicy(app: .teams, behavior: .autoTranscribe, quietHours: 22...24)
        #expect(MeetingPolicyEngine.decide(policy: late, now: date(hour: 23), calendar: gmt).action == .promptUser)
        #expect(MeetingPolicyEngine.decide(policy: late, now: date(hour: 0), calendar: gmt).action == .transcribe)
    }

    @Test("exclusions are case and diacritic insensitive, and a missing title never matches")
    func exclusionMatching() {
        let policy = MeetingPolicy(app: .zoom, behavior: .autoTranscribe, excludedKeywords: ["Café", "  ", "1:1"])
        #expect(MeetingPolicyEngine.matchedExclusion(policy, title: "Weekly CAFE sync") == "Café")
        #expect(MeetingPolicyEngine.matchedExclusion(policy, title: "Alex 1:1") == "1:1")
        #expect(MeetingPolicyEngine.matchedExclusion(policy, title: "All hands") == nil)
        #expect(MeetingPolicyEngine.matchedExclusion(policy, title: nil) == nil)
        #expect(MeetingPolicyEngine.decide(policy: policy, now: date(hour: 12), title: nil, calendar: gmt).action == .transcribe)
    }

    @Test("video is only requested when recording")
    func videoFlag() {
        let record = MeetingPolicy(app: .zoom, behavior: .autoTranscribeAndRecord, recordVideo: true)
        #expect(MeetingPolicyEngine.decide(policy: record, now: date(hour: 12), calendar: gmt).recordVideo)
        let transcribe = MeetingPolicy(app: .zoom, behavior: .autoTranscribe, recordVideo: true)
        #expect(!MeetingPolicyEngine.decide(policy: transcribe, now: date(hour: 12), calendar: gmt).recordVideo)
    }

    @Test("policies are per app and persist under the Settings UI keys")
    func persistence() async {
        let settings = InMemorySettings()
        let store = MeetingPolicyStore(store: settings)
        await store.save(MeetingPolicy(app: .zoom, behavior: .autoTranscribe, autoStopGraceSeconds: 30))
        #expect(await store.policy(for: .zoom).behavior == .autoTranscribe)
        #expect(await store.policy(for: .zoom).autoStopGraceSeconds == 30)
        #expect(await store.policy(for: .teams).behavior == .askFirst)
        // The exact bytes the Settings UI would read.
        #expect(await settings.value(for: "meetings.policy.zoom", as: MeetingPolicy.self)?.behavior == .autoTranscribe)
    }

    // MTG-AC-17
    @Test("toggle auto-record flips between ask-first and auto-record")
    func toggle() async {
        let store = MeetingPolicyStore(store: InMemorySettings())
        #expect(await store.toggleAutoRecord(for: .zoom).behavior == .autoTranscribeAndRecord)
        #expect(await store.toggleAutoRecord(for: .zoom).behavior == .askFirst)
        await store.save(MeetingPolicy(app: .zoom, behavior: .autoTranscribe))
        #expect(await store.toggleAutoRecord(for: .zoom).behavior == .autoTranscribeAndRecord)
    }

    @Test("legacy autoRecord flag migrates only when no policy is stored")
    func legacyMigration() async {
        let settings = InMemorySettings()
        await settings.set(true, for: "meetings.autoRecord")
        let store = MeetingPolicyStore(store: settings)
        #expect(await store.policy(for: .zoom).behavior == .autoTranscribeAndRecord)
        await store.save(MeetingPolicy(app: .zoom, behavior: .doNothing))
        #expect(await store.policy(for: .zoom).behavior == .doNothing)
    }

    @Test("setting keys match FeatureSupport.SettingsKey literals")
    func keyLiterals() {
        #expect(MeetingsSettingsKeys.policy(.zoom) == "meetings.policy.zoom")
        #expect(MeetingsSettingsKeys.policy(.teams) == "meetings.policy.teams")
        #expect(MeetingsSettingsKeys.consentNotice == "meetings.consentNotice")
        #expect(MeetingsSettingsKeys.legacyAutoRecord == "meetings.autoRecord")
        #expect(MeetingsSettingsKeys.storageLocation == "meetings.storageLocation")
    }

    // MTG-AC-11
    @Test("consent notice shows once, then is stored as acknowledged")
    func consent() async {
        let consent = MeetingConsentStore(store: InMemorySettings())
        #expect(await consent.needsNotice())
        #expect(await consent.acknowledgedAt() == nil)
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        await consent.recordAcknowledged(at: when)
        #expect(!(await consent.needsNotice()))
        #expect(await consent.acknowledgedAt() == when)
    }
}
