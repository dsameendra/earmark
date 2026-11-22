import AppCore
import Foundation

/// What the HUD needs to know when a session begins.
public struct DictationHUDInfo: Sendable, Equatable {
    public var hint: String
    public var isExperimental: Bool
    public var position: DictationHUDPosition
    public init(hint: String, isExperimental: Bool = false, position: DictationHUDPosition = .nearCursor) {
        self.hint = hint
        self.isExperimental = isExperimental
        self.position = position
    }
}

/// The dictation HUD as seen by the controller. The AppKit implementation is ``DictationHUDController``.
public protocol DictationHUDPresenting: Sendable {
    func show(_ info: DictationHUDInfo) async
    func update(partial: String) async
    func update(level: Float) async
    /// Capture ended, text is being finalized.
    func showProcessing() async
    /// The routed engine is experimental (Sinhala): show a badge.
    func showExperimentalBadge() async
    func dismiss() async
    /// Dismisses the listening HUD and shows a short error toast (DICT-AC-14).
    func dismissWithError(_ message: String) async
}

public struct DictationNotice: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case info, warning, error }
    public var kind: Kind
    public var message: String
    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }
}

/// Out-of-HUD notifications (device fallback, translation failure, refusal reasons).
public protocol DictationNotifying: Sendable {
    func notify(_ notice: DictationNotice) async
}

/// Shows and hides the Accessibility onboarding sheet (DICT-AC-06). The sheet content is ``AccessibilityOnboardingView``.
public protocol DictationOnboardingPresenting: Sendable {
    func presentAccessibilityOnboarding(settingsURL: URL) async
    func dismissAccessibilityOnboarding() async
}

public enum DictationState: Sendable, Equatable {
    case idle
    case listening(partial: String)
    case finalizing
    /// Accessibility not granted: nothing is captured or inserted until it is.
    case needsAccessibility
    /// Global key monitoring unavailable (Input Monitoring not granted); the app keeps working without the hotkey.
    case hotkeyUnavailable
    case failed(String)
}
