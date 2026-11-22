import AppCore
import FeatureSettings
import FeatureSupport
import Foundation
import Observation

/// Step 3: shows permission rows but requests nothing unless the user taps "Allow now" (ONB-AC-05/06).
/// A denial never blocks the flow; the row explains recovery and links to System Settings.
@MainActor @Observable
public final class OnboardingPermissionsModel {
    /// Microphone, System Audio, Accessibility and Notifications as on the Flow board, then Screen Recording for meeting video.
    public static let kinds: [PermissionKind] = [.microphone, .systemAudioRecording, .accessibility, .notifications, .screenRecording]

    public private(set) var statuses: [PermissionKind: PermissionStatus] = [:]
    @ObservationIgnored private let permissions: any PermissionsServicing

    public init(permissions: any PermissionsServicing) { self.permissions = permissions }

    /// Reads current statuses; never prompts.
    public func load() async {
        for kind in Self.kinds { statuses[kind] = await permissions.status(kind) }
    }

    /// Follows OS-side changes (for example after the user returns from System Settings) until cancelled.
    public func observe() async {
        for await (kind, status) in permissions.changes() where Self.kinds.contains(kind) { statuses[kind] = status }
    }

    public func rowState(for kind: PermissionKind) -> PermissionRowState {
        PermissionRowState(kind: kind, status: statuses[kind] ?? .notDetermined, context: .onboarding)
    }

    /// Only called from an explicit "Allow now" tap.
    public func request(_ kind: PermissionKind) async { statuses[kind] = await permissions.request(kind) }

    public func settingsURL(for kind: PermissionKind) -> URL { permissions.settingsURL(for: kind) }
}

/// The five-step first-run flow: persistence, resume, navigation and the one-time consent acknowledgement
/// (ONB-AC-01, ONB-AC-08). Skipping from any step counts as completing.
@MainActor @Observable
public final class OnboardingModel {
    public private(set) var step: OnboardingStep = .welcome
    /// Set once the flow was completed or skipped; the host closes the window when it becomes `true`.
    public private(set) var isFinished = false
    public private(set) var consentAcknowledged = false
    public private(set) var dictationShortcut: KeyCombo = .defaultDictation

    public let languages: OnboardingLanguageModel
    public let permissions: OnboardingPermissionsModel
    @ObservationIgnored private let store: any SettingsStore

    public init(
        services: AppServices, router: (any EngineRouter)? = nil, isOnline: @escaping OnlineCheck = NetworkReachability.systemCheck,
        freeDiskBytes: (@Sendable () -> Int64?)? = nil
    ) {
        store = services.settings
        if let freeDiskBytes {
            languages = OnboardingLanguageModel(services: services, router: router, isOnline: isOnline, freeDiskBytes: freeDiskBytes)
        } else {
            languages = OnboardingLanguageModel(services: services, router: router, isOnline: isOnline)
        }
        permissions = OnboardingPermissionsModel(permissions: services.permissions)
    }

    // MARK: First launch

    /// `true` until the flow has been completed or skipped.
    public static func shouldPresent(store: any SettingsStore) async -> Bool {
        await store.value(for: SettingsKey.onboardingCompleted, as: Bool.self) != true
    }

    /// Re-arms the flow from its first step (Settings > General "Show Welcome Again", Help menu).
    public static func requestWelcomeAgain(store: any SettingsStore) async {
        await store.set(0, for: SettingsKey.onboardingStep)
        await store.set(false, for: SettingsKey.onboardingCompleted)
    }

    // MARK: Loading

    /// Resumes at the last step shown (quitting mid-flow resumes at the same step) and loads the step models.
    public func load() async {
        isFinished = false
        let saved = await store.value(for: SettingsKey.onboardingStep, as: Int.self) ?? 0
        step = OnboardingStep(rawValue: saved) ?? .welcome
        consentAcknowledged = await store.value(for: SettingsKey.meetingConsentNotice, as: Bool.self) == false
        let combo = await store.value(for: SettingsKey.shortcut("dictation"), as: KeyCombo.self)
        dictationShortcut = combo ?? .defaultDictation
        await permissions.load()
        await languages.load()
    }

    // MARK: Navigation

    public var canGoBack: Bool { !step.isFirst }
    public var primaryTitle: String { step.primaryTitle }
    public var tourHighlights: [OnboardingHighlight] { OnboardingHighlight.tour(dictationShortcut: dictationShortcut.spokenDescription) }

    /// Advances; on the last step completes the flow.
    public func next() async {
        guard let following = step.next else {
            await finish()
            return
        }
        await go(to: following)
    }

    public func back() async {
        guard let previous = step.previous else { return }
        await go(to: previous)
    }

    /// Leaves the flow from any step; it is not shown again until re-opened (ONB-AC-01).
    public func skip() async { await finish() }

    private func go(to newStep: OnboardingStep) async {
        step = newStep
        await store.set(newStep.rawValue, for: SettingsKey.onboardingStep)
        if newStep == .permissions { await permissions.load() }
    }

    private func finish() async {
        await store.set(true, for: SettingsKey.onboardingCompleted)
        await store.set(0, for: SettingsKey.onboardingStep)
        isFinished = true
    }

    // MARK: Consent (ONB-AC-08)

    /// Records that the one-time recording-consent notice was read; Meetings then stops showing it before the first capture.
    /// Finishing without acknowledging leaves the notice pending, so it still appears before the first meeting capture.
    public func acknowledgeConsent() async {
        consentAcknowledged = true
        await store.set(false, for: SettingsKey.meetingConsentNotice)
    }
}
