import Foundation

// MARK: - Recovery helpers shared by Settings, onboarding and every blocked feature

extension PermissionKind {
    /// The `tccutil` service name that resets this permission; `nil` when `tccutil` has no service for it
    /// (Notifications are owned by the Notification Center, not TCC).
    public var tccServiceName: String? {
        switch self {
        case .microphone: "Microphone"
        case .systemAudioRecording: "AudioCapture"
        case .screenRecording: "ScreenCapture"
        case .accessibility: "Accessibility"
        case .notifications: nil
        }
    }

    /// Fallback when the running bundle has no identifier (command-line test hosts).
    public static let fallbackBundleID = "lk.dumindu.earmark.Earmark"

    /// "Reset and re-request" hint: the exact command that makes macOS forget the earlier answer so the next request shows
    /// the system prompt again. Never run by Earmark itself, because it would wipe a grant the user may still want.
    public func resetHint(bundleID: String? = Bundle.main.bundleIdentifier) -> String {
        guard let service = tccServiceName else {
            return "Notifications cannot be reset with tccutil. Remove Earmark from System Settings > Notifications, "
                + "or reinstall the app, then relaunch."
        }
        return "tccutil reset \(service) \(Self.resolvedBundleID(bundleID))"
    }

    /// The bare command for copying, `nil` for permissions `tccutil` cannot reset.
    public func resetCommand(bundleID: String? = Bundle.main.bundleIdentifier) -> String? {
        tccServiceName.map { "tccutil reset \($0) \(Self.resolvedBundleID(bundleID))" }
    }

    private static func resolvedBundleID(_ bundleID: String?) -> String {
        guard let bundleID, !bundleID.isEmpty, !bundleID.hasPrefix("com.apple.dt.") , !bundleID.hasSuffix("xctest") else {
            return fallbackBundleID
        }
        return bundleID
    }

    /// True when macOS can show the permission dialog again after a denial. It cannot for microphone, notifications and
    /// the audio tap (only a reset or System Settings changes them); the Accessibility prompt and the Screen Recording
    /// request can each be raised again and lead the user to the right pane.
    public var canPromptAfterDenial: Bool {
        switch self {
        case .accessibility, .screenRecording: true
        case .microphone, .systemAudioRecording, .notifications: false
        }
    }
}

extension PermissionsServicing {
    /// A fresh request after an earlier answer. Defaults to `request(_:)` for services that cannot do better.
    public func requestAgain(_ kind: PermissionKind) async -> PermissionStatus { await request(kind) }
}
