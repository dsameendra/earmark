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

/// Everything a row shows for a (kind, status, context) triple; views stay layout-only.
public struct PermissionRowState: Sendable, Equatable {
    public let kind: PermissionKind
    public let status: PermissionStatus
    public let context: PermissionRowContext
    public let bundleID: String?

    public init(
        kind: PermissionKind, status: PermissionStatus, context: PermissionRowContext = .settings,
        bundleID: String? = Bundle.main.bundleIdentifier
    ) {
        self.kind = kind
        self.status = status
        self.context = context
        self.bundleID = bundleID
    }

    /// Onboarding says "Ask later" instead of the neutral "Not requested" (Flow, step 3).
    public var chipLabel: String { context == .onboarding && status == .notDetermined ? "Ask later" : status.chipLabel }

    /// A never-asked permission is requested; a denied one offers "Request access" too: it raises the prompts macOS lets an
    /// app raise again (Accessibility, Screen Recording), re-reads the rest, and opens the exact System Settings pane when
    /// that is still not enough. Granted and restricted rows need nothing.
    public var action: PermissionRowAction {
        switch status {
        case .notDetermined, .denied: .request
        case .granted, .restricted: .none
        }
    }

    public var actionTitle: String {
        if status == .denied { return "Request access" }
        return context == .onboarding ? "Allow now" : "Allow…"
    }

    /// A denied row can be re-read from the OS without relaunching, in Settings and in onboarding.
    public var showsRecheck: Bool { status == .denied }

    /// "Reset and re-request": the tccutil command for the toggle-is-on-but-still-denied case (ad-hoc builds and reinstalls
    /// change identity) and for getting the system prompt back. `nil` unless denied.
    public var helpNote: String? {
        guard status == .denied else { return nil }
        if let stale = kind.staleEntryHint {
            return stale + " Or quit Earmark and run \(kind.resetHint(bundleID: bundleID)) in Terminal, then reopen it."
        }
        if kind.tccServiceName == nil { return kind.resetHint(bundleID: bundleID) }
        return "To be asked again, or if the toggle is on but Earmark still says access is needed, quit Earmark and run "
            + "\(kind.resetHint(bundleID: bundleID)) in Terminal, then reopen it."
    }

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
    private let onRecheck: (() -> Void)?

    public init(
        state: PermissionRowState, onRequest: @escaping () -> Void, onOpenSettings: @escaping () -> Void,
        onRecheck: (() -> Void)? = nil
    ) {
        self.state = state
        self.onRequest = onRequest
        self.onOpenSettings = onOpenSettings
        self.onRecheck = onRecheck
    }

    public var body: some View {
        HStack(alignment: .top, spacing: DSSpacing.md) {
            DSIcon(state.kind.symbol, orStock: state.kind.systemImage)
                .dsSymbolStyle(.monochrome)
                .frame(width: 24)
                .foregroundStyle(DSColor.secondaryText)
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(state.kind.title)
                Text(state.kind.purpose).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                if let note = state.recoveryNote {
                    Text(note).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                        .accessibilityIdentifier("\(state.identifierBase).recovery")
                }
                if let help = state.helpNote {
                    Text(help).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText).textSelection(.enabled)
                        .accessibilityIdentifier("\(state.identifierBase).help")
                }
            }
            Spacer(minLength: DSSpacing.md)
            VStack(alignment: .trailing, spacing: DSSpacing.xs) {
                StatusPill(
                    LocalizedStringKey(state.chipLabel), systemImage: state.status.chipSystemImage, tone: state.status.chipTone
                )
                .accessibilityIdentifier("\(state.identifierBase).status")
                // Buttons sit side by side when there is room and stack when there is not.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: DSSpacing.sm) { actionButtons }
                    VStack(alignment: .trailing, spacing: DSSpacing.xs) { actionButtons }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var actionButtons: some View {
        if state.action == .request {
            Button(state.actionTitle, action: onRequest)
                .accessibilityIdentifier("\(state.identifierBase).request")
        }
        if state.showsRecheck, let onRecheck {
            Button("Re-check", action: onRecheck)
                .accessibilityIdentifier("\(state.identifierBase).recheck")
        }
        if state.showsSettingsLink {
            Button("Open System Settings", action: onOpenSettings)
                .buttonStyle(.dsLink)
                .accessibilityIdentifier("\(state.identifierBase).openSettings")
        }
    }
}
