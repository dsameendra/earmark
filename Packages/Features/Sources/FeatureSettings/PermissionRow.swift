import AppCore
import DesignSystem
import SwiftUI

// MARK: - Presentation model (pure, unit-tested)

/// Where a `PermissionRow` is shown. Settings requests on demand; onboarding only explains and defers (ONB-AC-05).
public enum PermissionRowContext: Sendable {
    case settings, onboarding
}

/// The one button a row offers next to the System Settings link.
public enum PermissionRowAction: Sendable, Equatable {
    case request, none
}

extension PermissionStatus {
    /// Chip text for the Privacy & Permissions list.
    public var chipLabel: String {
        switch self {
        case .granted: "Allowed"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .notDetermined: "Not requested"
        }
    }

    public var chipTone: DSTone {
        switch self {
        case .granted: .success
        case .denied: .danger
        case .restricted: .warning
        case .notDetermined: .neutral
        }
    }

    public var chipSystemImage: String {
        switch self {
        case .granted: "checkmark.circle.fill"
        case .denied: "xmark.circle.fill"
        case .restricted: "lock.fill"
        case .notDetermined: "circle.dashed"
        }
    }
}

extension PermissionKind {
    public var systemImage: String {
        switch self {
        case .microphone: "mic"
        case .systemAudioRecording: "speaker.wave.2"
        case .screenRecording: "rectangle.dashed.badge.record"
        case .accessibility: "accessibility"
        case .notifications: "bell"
        }
    }

    /// What breaks without the permission, in plain words. Shown after a denial together with the recovery steps.
    public var consequence: String {
        switch self {
        case .microphone: "Live captions, dictation and microphone meeting capture are unavailable."
        case .systemAudioRecording: "Captions and meeting capture cannot hear other apps."
        case .screenRecording: "Meeting video cannot be recorded. Audio transcripts still work."
        case .accessibility: "Dictation falls back to copying text to the clipboard."
        case .notifications: "Meeting and job alerts are not shown. Earmark keeps working."
        }
    }
}

/// Everything a row shows for a (kind, status, context) triple; views stay layout-only.
public struct PermissionRowState: Sendable, Equatable {
    public let kind: PermissionKind
    public let status: PermissionStatus
    public let context: PermissionRowContext

    public init(kind: PermissionKind, status: PermissionStatus, context: PermissionRowContext = .settings) {
        self.kind = kind
        self.status = status
        self.context = context
    }

    /// Onboarding says "Ask later" instead of the neutral "Not requested" (Flow, step 3).
    public var chipLabel: String { context == .onboarding && status == .notDetermined ? "Ask later" : status.chipLabel }

    /// Only a never-asked permission can be requested; denied ones go through System Settings. Granted needs nothing.
    public var action: PermissionRowAction { status == .notDetermined ? .request : .none }

    public var actionTitle: String { context == .onboarding ? "Allow now" : "Allow…" }

    /// Denied or restricted rows explain how to recover (ONB-AC-06); `nil` otherwise.
    public var recoveryNote: String? {
        switch status {
        case .denied: "\(kind.consequence) Turn Earmark on in System Settings, then return here."
        case .restricted: "\(kind.consequence) A device policy restricts this; an administrator can change it."
        case .granted, .notDetermined: nil
        }
    }

    /// The link is always available (SET-AC-17); in onboarding it appears once there is something to fix.
    public var showsSettingsLink: Bool { context == .settings || status == .denied || status == .restricted }

    public var identifierBase: String { "permission.\(kind.rawValue)" }
}

// MARK: - View

/// One permission: icon, title, why it is needed, status chip, an optional request button and a System Settings link.
/// Reused by Privacy & Permissions and by onboarding step 3.
public struct PermissionRow: View {
    private let state: PermissionRowState
    private let onRequest: () -> Void
    private let onOpenSettings: () -> Void

    public init(state: PermissionRowState, onRequest: @escaping () -> Void, onOpenSettings: @escaping () -> Void) {
        self.state = state
        self.onRequest = onRequest
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        HStack(alignment: .top, spacing: DSSpacing.md) {
            Image(systemName: state.kind.systemImage)
                .frame(width: 24)
                .foregroundStyle(DSColor.secondaryText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(state.kind.title)
                Text(state.kind.purpose).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                if let note = state.recoveryNote {
                    Text(note).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                        .accessibilityIdentifier("\(state.identifierBase).recovery")
                }
            }
            Spacer(minLength: DSSpacing.md)
            VStack(alignment: .trailing, spacing: DSSpacing.xs) {
                StatusPill(
                    LocalizedStringKey(state.chipLabel), systemImage: state.status.chipSystemImage, tone: state.status.chipTone
                )
                .accessibilityIdentifier("\(state.identifierBase).status")
                if state.action == .request {
                    Button(state.actionTitle, action: onRequest)
                        .accessibilityIdentifier("\(state.identifierBase).request")
                }
                if state.showsSettingsLink {
                    Button("Open System Settings", action: onOpenSettings)
                        .buttonStyle(.link)
                        .accessibilityIdentifier("\(state.identifierBase).openSettings")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}
