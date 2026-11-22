import AppCore
import Foundation

/// What the app should do when a meeting starts, after applying the per-app policy.
public enum MeetingAction: Sendable, Equatable {
    /// Policy is `doNothing`.
    case ignore
    /// Show the "Zoom meeting detected. Transcribe? Record?" notification (MTG-AC-04).
    case promptUser
    case transcribe
    case transcribeAndRecord
}

public enum MeetingDecisionReason: Sendable, Equatable {
    case configured
    /// An automatic behaviour was downgraded to `promptUser` because the time is inside quiet hours.
    case quietHours
    /// An automatic behaviour was downgraded because the meeting title matched this exclusion keyword.
    case excludedKeyword(String)
}

public struct MeetingDecision: Sendable, Equatable {
    public var action: MeetingAction
    public var reason: MeetingDecisionReason
    /// Record video of the meeting window (only meaningful with `.transcribeAndRecord`).
    public var recordVideo: Bool
}

/// Pure policy evaluation (MTG-AC-03, -05, -06).
public enum MeetingPolicyEngine {
    /// Quiet hours are the half-open hour range `[lowerBound, upperBound)`, so `22...24` covers 22:00 to midnight.
    /// A `ClosedRange<Int>` cannot wrap past midnight, so an overnight window is not expressible (limitation of the
    /// frozen `MeetingPolicy`).
    public static func isQuietHour(_ policy: MeetingPolicy, at date: Date, calendar: Calendar = .current) -> Bool {
        guard let range = policy.quietHours else { return false }
        let hour = calendar.component(.hour, from: date)
        return hour >= range.lowerBound && hour < range.upperBound
    }

    /// First exclusion keyword contained (case- and diacritic-insensitive) in `title`. A `nil` title never matches
    /// because window titles are not read in v1 (no Accessibility, research §4).
    public static func matchedExclusion(_ policy: MeetingPolicy, title: String?) -> String? {
        guard let title, !title.isEmpty else { return nil }
        return policy.excludedKeywords.first { keyword in
            let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && title.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    public static func decide(
        policy: MeetingPolicy, now: Date, title: String? = nil, calendar: Calendar = .current
    ) -> MeetingDecision {
        let video = policy.recordVideo
        switch policy.behavior {
        case .doNothing:
            return MeetingDecision(action: .ignore, reason: .configured, recordVideo: false)
        case .askFirst:
            return MeetingDecision(action: .promptUser, reason: .configured, recordVideo: video)
        case .autoTranscribe, .autoTranscribeAndRecord:
            // Exclusions always win and fall back to asking (never to silently doing nothing).
            if let keyword = matchedExclusion(policy, title: title) {
                return MeetingDecision(action: .promptUser, reason: .excludedKeyword(keyword), recordVideo: video)
            }
            if isQuietHour(policy, at: now, calendar: calendar) {
                return MeetingDecision(action: .promptUser, reason: .quietHours, recordVideo: video)
            }
            let record = policy.behavior == .autoTranscribeAndRecord
            return MeetingDecision(action: record ? .transcribeAndRecord : .transcribe, reason: .configured, recordVideo: record && video)
        }
    }
}

/// Reads and writes per-app policies in the shared `SettingsStore` under the keys the Settings UI uses.
public struct MeetingPolicyStore: Sendable {
    private let store: any SettingsStore
    public init(store: any SettingsStore) { self.store = store }

    /// Stored policy, or the default (`askFirst`). A legacy `meetings.autoRecord == true` flag (no stored policy yet)
    /// migrates to `autoTranscribeAndRecord`.
    public func policy(for app: MeetingApp) async -> MeetingPolicy {
        if let stored = await store.value(for: MeetingsSettingsKeys.policy(app), as: MeetingPolicy.self) { return stored }
        if await store.value(for: MeetingsSettingsKeys.legacyAutoRecord, as: Bool.self) == true {
            return MeetingPolicy(app: app, behavior: .autoTranscribeAndRecord)
        }
        return MeetingPolicy(app: app)
    }

    public func save(_ policy: MeetingPolicy) async {
        await store.set(policy, for: MeetingsSettingsKeys.policy(policy.app))
    }

    /// Menu bar "Toggle auto-record" (MTG-AC-17): auto-record becomes ask-first, anything else becomes auto-record.
    @discardableResult
    public func toggleAutoRecord(for app: MeetingApp) async -> MeetingPolicy {
        var policy = await policy(for: app)
        policy.behavior = policy.behavior == .autoTranscribeAndRecord ? .askFirst : .autoTranscribeAndRecord
        await save(policy)
        return policy
    }

    public func decide(for app: MeetingApp, now: Date, title: String? = nil, calendar: Calendar = .current) async -> MeetingDecision {
        MeetingPolicyEngine.decide(policy: await policy(for: app), now: now, title: title, calendar: calendar)
    }
}

/// The one-time recording consent notice (MTG-AC-11). `meetings.consentNotice` stays the Settings switch ("show the
/// notice", default true); acknowledging flips it off and records when it happened.
public struct MeetingConsentStore: Sendable {
    private let store: any SettingsStore
    public init(store: any SettingsStore) { self.store = store }

    public func needsNotice() async -> Bool {
        await store.value(for: MeetingsSettingsKeys.consentNotice, as: Bool.self) ?? true
    }

    public func acknowledgedAt() async -> Date? {
        await store.value(for: MeetingsSettingsKeys.consentAcknowledgedAt, as: Double.self).map { Date(timeIntervalSince1970: $0) }
    }

    public func recordAcknowledged(at date: Date = Date()) async {
        await store.set(date.timeIntervalSince1970, for: MeetingsSettingsKeys.consentAcknowledgedAt)
        await store.set(false, for: MeetingsSettingsKeys.consentNotice)
    }
}
