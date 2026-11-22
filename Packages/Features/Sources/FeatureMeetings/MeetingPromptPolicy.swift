import AppCore
import FeatureSupport
import Foundation

/// What to do when a meeting is detected.
public enum MeetingDecision: Sendable, Equatable {
    /// Behaviour is "Do nothing": no prompt, no capture.
    case none
    /// Show the notification and inline banner (default, MTG-AC-03/04).
    case prompt
    /// Start without prompting (MTG-AC-05).
    case auto(record: Bool)
}

/// Pure decision function for a detected meeting (MTG-AC-03, 05, 06).
public enum MeetingPromptPolicy {
    /// - Parameters:
    ///   - hour: local time as fractional hours, 0..<24 (e.g. 22.5 is 22:30).
    ///   - title: the meeting title when known, matched against `excludedKeywords`.
    ///
    /// Quiet hours are half-open `[lower, upper)` in fractional hours, so `22...24` suppresses automatic starts from
    /// 22:00 up to midnight and `9...17` from 09:00 up to (not including) 17:00. Quiet hours and keyword matches never
    /// silence the prompt: they turn an automatic behaviour into `.prompt` (the user may still record).
    public static func decide(policy: MeetingPolicy, hour: Double, title: String? = nil) -> MeetingDecision {
        switch policy.behavior {
        case .doNothing: return .none
        case .askFirst: return .prompt
        case .autoTranscribe, .autoTranscribeAndRecord:
            if isQuiet(policy.quietHours, hour: hour) || matchesExclusion(policy.excludedKeywords, title: title) { return .prompt }
            return .auto(record: policy.behavior == .autoTranscribeAndRecord)
        }
    }

    public static func isQuiet(_ range: ClosedRange<Int>?, hour: Double) -> Bool {
        guard let range else { return false }
        return hour >= Double(range.lowerBound) && hour < Double(range.upperBound)
    }

    public static func matchesExclusion(_ keywords: [String], title: String?) -> Bool {
        guard let title, !title.isEmpty else { return false }
        return keywords.contains { keyword in
            let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && title.localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// Fractional local hour of `date`.
    public static func hour(of date: Date, calendar: Calendar = .current) -> Double {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60
    }

    /// The policy change a notification action implies, or `nil` when the action does not touch the policy.
    /// "Always" maps to `autoTranscribe` (never to auto-record: recording must stay an explicit choice in Settings).
    public static func behavior(after action: MeetingPromptAction) -> MeetingBehavior? {
        switch action {
        case .alwaysForApp: .autoTranscribe
        case .neverForApp: .doNothing
        case .record, .transcribeOnly, .ignoreThisMeeting: nil
        }
    }
}
