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

    /// For the permissions whose list lives in System Settings (Accessibility, Screen Recording, System Audio Recording):
    /// when Earmark is already listed but Earmark still reports no access, the old entry no longer matches this build.
    /// Removing it and adding it again, then Re-check (or a relaunch), makes macOS recognise the current app.
    public var staleEntryHint: String? {
        let pane: String
        switch self {
        case .accessibility: pane = "Privacy & Security > Accessibility"
        case .screenRecording: pane = "Privacy & Security > Screen & System Audio Recording"
        case .systemAudioRecording: pane = "Privacy & Security > Screen & System Audio Recording (System Audio Recording Only)"
        case .microphone, .notifications: return nil
        }
        return "If Earmark is already listed in \(pane) but Earmark still says access is needed: select Earmark in the list, "
            + "click \u{2212} to remove it, click + and add Earmark again from Applications, turn it on, then click Re-check. "
            + "If it still isn't detected, quit and reopen Earmark."
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
