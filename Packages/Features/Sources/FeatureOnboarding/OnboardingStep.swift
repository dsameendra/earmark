import AppCore
import DesignSystem
import Foundation

/// The five onboarding steps (ONB non-functional: at most five screens). Copy follows the M8 Flow board.
public enum OnboardingStep: Int, CaseIterable, Identifiable, Sendable {
    case welcome, languages, permissions, tour, ready

    public var id: Int { rawValue }

    /// 1-based position shown as "Step N of 5".
    public var number: Int { rawValue + 1 }
    public static var count: Int { allCases.count }

    public var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    public var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }
    public var isFirst: Bool { previous == nil }
    public var isLast: Bool { next == nil }

    public var title: String {
        switch self {
        case .welcome: "Your voice stays on your Mac"
        case .languages: "Which languages do you speak?"
        case .permissions: "Permissions, only when needed"
        case .tour: "Earmark lives in your menu bar"
        case .ready: "You are ready"
        }
    }

    public var subtitle: String {
        switch self {
        case .welcome: "Earmark turns speech into transcripts you can edit and export. Everything runs on this Mac."
        case .languages: "English is the default. Earmark picks the right model for each language."
        case .permissions: "Nothing is requested now. Each is asked at the moment a feature needs it."
        case .tour: "Close the window and it keeps listening for meetings when you choose."
        case .ready: "Drop a file to begin, or start live captions. Recording consent is explained once, here."
        }
    }

    /// Duotone symbol where covered by `DSSymbol`.
    public var symbol: DSSymbol? { DSSymbol(replacingStock: systemImage) }

    /// Symbol shown on the brand panel.
    public var systemImage: String {
        switch self {
        case .welcome: "lock.shield"
        case .languages: DSSymbol.translate.systemImageName
        case .permissions: "hand.raised"
        case .tour: "menubar.rectangle"
        case .ready: "checkmark.seal"
        }
    }

    public var progressText: String { "Step \(number) of \(Self.count)" }

    /// Title of the primary button.
    public var primaryTitle: String {
        switch self {
        case .welcome: "Get started"
        case .ready: "Open Earmark"
        default: "Continue"
        }
    }
}

/// One line of the welcome, tour or ready lists. Symbol names live here, not in views (alignment rule A3).
public struct OnboardingHighlight: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let systemImage: String
    public var symbol: DSSymbol? { DSSymbol(replacingStock: systemImage) }
}

extension OnboardingHighlight {
    /// Step 1: the privacy promise.
    public static let welcome: [OnboardingHighlight] = [
        .init(id: "private", title: "Private by default", detail: "No accounts, no cloud, no analytics.", systemImage: "lock"),
        .init(id: "fast", title: "Fast on Apple silicon", detail: "Transcribe files, meetings and live audio.", systemImage: "bolt"),
        .init(
            id: "languages", title: "English and Sinhala", detail: "Plus 97 more languages, mixed in one transcript.",
            systemImage: DSSymbol.language.systemImageName),
    ]

    /// Step 4: menu bar, live captions, meeting capture and dictation (ONB-AC-07). `dictationShortcut` is the user's binding.
    public static func tour(dictationShortcut: String) -> [OnboardingHighlight] {
        [
            .init(
                id: "menuBar", title: "Menu bar icon", detail: "Shows a red dot while capturing. Drop files on it to transcribe.",
                systemImage: "menubar.rectangle"),
            .init(
                id: "liveCaptions", title: "Live captions",
                detail: "Start or stop from the menu bar. Captions float over any app.", systemImage: DSSymbol.liveCaptions.systemImageName),
            .init(
                id: "meetings", title: "Meeting capture",
                detail: "Earmark asks before it records a detected meeting.", systemImage: DSSymbol.meetings.systemImageName),
            .init(
                id: "dictation", title: "Dictation anywhere",
                detail: "Press \(dictationShortcut), speak, and the text is inserted where you type. Fn works too; choose it in Settings.",
                systemImage: DSSymbol.dictation.systemImageName),
        ]
    }

    /// Step 5: where to begin.
    public static let ready: [OnboardingHighlight] = [
        .init(id: "file", title: "Transcribe a file", detail: "Drag audio or video onto Home.", systemImage: "doc.badge.plus"),
        .init(id: "live", title: "Start live captions", detail: "Choose Live in the sidebar or the menu bar.", systemImage: DSSymbol.liveCaptions.systemImageName),
    ]
}

/// Words for the recording-consent notice (shown once, in the last step).
public enum RecordingConsentCopy {
    public static let title = "Recording consent"
    public static let message = "You are responsible for telling participants before you record."
    public static let acknowledge = "Got it"
    public static let acknowledged = "Acknowledged"
    public static let systemImage = "exclamationmark.bubble"
}

extension KeyCombo {
    /// Spoken form for VoiceOver and prose, e.g. "Control-Option-D" or "Fn".
    public var spokenDescription: String {
        if keyCode == KeyCombo.functionKey.keyCode, modifiers & (1 << 23) != 0 { return "Fn" }
        var parts: [String] = []
        if modifiers & (1 << 18) != 0 { parts.append("Control") }
        if modifiers & (1 << 19) != 0 { parts.append("Option") }
        if modifiers & (1 << 17) != 0 { parts.append("Shift") }
        if modifiers & (1 << 20) != 0 { parts.append("Command") }
        parts.append(OnboardingKeyNames.name(for: keyCode))
        return parts.joined(separator: "-")
    }
}

enum OnboardingKeyNames {
    private static let names: [UInt16: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N",
        31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z", 49: "Space",
    ]
    static func name(for keyCode: UInt16) -> String { names[keyCode] ?? "key \(keyCode)" }
}
