import AppCore
import AppKit
import DesignSystem
import Observation
import SwiftUI

// MARK: - Presentation shared by Settings, onboarding and every blocked feature

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
    public var title: String {
        switch self {
        case .microphone: "Microphone"
        case .systemAudioRecording: "System Audio Recording"
        case .screenRecording: "Screen Recording"
        case .accessibility: "Accessibility"
        case .notifications: "Notifications"
        }
    }

    public var purpose: String {
        switch self {
        case .microphone: "Transcribe your voice for live captions, dictation and meetings."
        case .systemAudioRecording: "Capture audio from other apps and meetings."
        case .screenRecording: "Record meeting video (optional)."
        case .accessibility: "Insert dictated text into other apps."
        case .notifications: "Tell you when a meeting starts or a job finishes."
        }
    }

    /// Duotone symbol where covered by `DSSymbol`; other permissions keep their stock `systemImage`.
    public var symbol: DSSymbol? {
        switch self {
        case .microphone: .dictation
        case .systemAudioRecording: .systemAudio
        case .screenRecording, .accessibility, .notifications: nil
        }
    }

    public var systemImage: String {
        switch self {
        case .microphone: DSSymbol.dictation.systemImageName
        case .systemAudioRecording: DSSymbol.systemAudio.systemImageName
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

    /// Where to turn it on, e.g. "Privacy & Security > Microphone".
    public var settingsPaneName: String {
        switch self {
        case .microphone: "Privacy & Security > Microphone"
        case .systemAudioRecording: "Privacy & Security > Screen & System Audio Recording"
        case .screenRecording: "Privacy & Security > Screen & System Audio Recording"
        case .accessibility: "Privacy & Security > Accessibility"
        case .notifications: "Notifications > Earmark"
        }
    }
}

// MARK: - Blocked-feature gate

/// Tracks the permissions one feature needs, so Live, Dictation, Meetings, the menu bar and Settings can show the same
/// status chips and an inline "Request access" without each reimplementing the flow.
@MainActor @Observable
public final class PermissionGateModel {
    public let kinds: [PermissionKind]
    public private(set) var statuses: [PermissionKind: PermissionStatus] = [:]
    /// `false` until the first read: an unread status is "unknown", not "not requested", so nothing is flagged as blocked
    /// (a granted user never sees the banner flash).
    public private(set) var hasLoaded = false
    @ObservationIgnored private let service: any PermissionsServicing

    public init(kinds: [PermissionKind], service: any PermissionsServicing) {
        self.kinds = kinds
        self.service = service
    }

    /// Reads current statuses; never prompts.
    public func load() async {
        for kind in kinds { statuses[kind] = await service.status(kind) }
        hasLoaded = true
    }

    /// Follows OS-side changes (for example after the user returns from System Settings) until cancelled.
    public func observe() async {
        for await (kind, status) in service.changes() where kinds.contains(kind) { statuses[kind] = status }
    }

    /// The permissions that still need attention: anything not granted.
    public var blocked: [PermissionKind] { blocked(among: kinds) }
    public var isBlocked: Bool { !blocked.isEmpty }

    /// The not-granted permissions among `relevant` (for example only the ones the chosen Live source needs).
    public func blocked(among relevant: [PermissionKind]) -> [PermissionKind] {
        guard hasLoaded else { return [] }
        return kinds.filter { relevant.contains($0) && (statuses[$0] ?? .notDetermined) != .granted }
    }

    public func status(_ kind: PermissionKind) -> PermissionStatus { statuses[kind] ?? .notDetermined }

    /// "Request access": the system prompt when never asked; for a denial, the request that can be raised again
    /// (Accessibility, Screen Recording) or a plain re-read. The view opens System Settings when it is still not granted.
    @discardableResult
    public func requestAccess(_ kind: PermissionKind) async -> PermissionStatus {
        let result = await service.requestAgain(kind)
        statuses[kind] = result
        return result
    }

    /// Re-reads the OS state (the "Re-check" button); never prompts.
    public func recheck(_ kind: PermissionKind) async { statuses[kind] = await service.status(kind) }

    public func settingsURL(for kind: PermissionKind) -> URL { service.settingsURL(for: kind) }

    /// Plain-language line for one blocked permission, naming the feature it blocks.
    public func message(for kind: PermissionKind, feature: String) -> String {
        switch status(kind) {
        case .notDetermined: "\(feature) needs \(kind.title) access. \(kind.purpose)"
        case .denied:
            "\(feature) cannot use \(kind.title) because access is turned off. Turn Earmark on in \(kind.settingsPaneName), then re-check."
        case .restricted: "\(feature) is blocked because a device policy restricts \(kind.title)."
        case .granted: ""
        }
    }

    /// The title of the primary button for `kind`.
    public func actionTitle(for kind: PermissionKind) -> String { status(kind) == .denied ? "Request access" : "Allow…" }
}

/// An inline banner for a blocked feature: one block per missing permission with its status chip, "Request access",
/// "Re-check", the exact System Settings pane and the `tccutil` reset hint. Renders nothing when everything is granted.
public struct PermissionGateBanner: View {
    private let model: PermissionGateModel
    private let feature: String
    private let identifierBase: String
    private let relevant: [PermissionKind]?
    @Environment(\.openURL) private var openURL
    @State private var showsReset = false

    /// - Parameter relevant: limits the banner to these permissions (default: every permission the model tracks).
    public init(model: PermissionGateModel, feature: String, identifier: String = "permissionGate", relevant: [PermissionKind]? = nil) {
        self.model = model
        self.feature = feature
        self.identifierBase = identifier
        self.relevant = relevant
    }

    private var blocked: [PermissionKind] { model.blocked(among: relevant ?? model.kinds) }

    public var body: some View {
        Group {
            if !blocked.isEmpty {
                VStack(alignment: .leading, spacing: DSSpacing.md) {
                    ForEach(blocked, id: \.self) { kind in row(kind) }
                }
                .padding(DSSpacing.md)
                .background(DSColor.insetBackground, in: RoundedRectangle(cornerRadius: DSRadius.large))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(identifierBase)
            }
        }
        .task {
            await model.load()
            await model.observe()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.load() }
        }
    }

    private func row(_ kind: PermissionKind) -> some View {
        let status = model.status(kind)
        let base = "\(identifierBase).\(kind.rawValue)"
        return VStack(alignment: .leading, spacing: DSSpacing.xs) {
            HStack(spacing: DSSpacing.sm) {
                Text(kind.title).font(DSTypography.headline)
                StatusPill(LocalizedStringKey(status.chipLabel), systemImage: status.chipSystemImage, tone: status.chipTone)
                    .accessibilityIdentifier("\(base).status")
            }
            Text(model.message(for: kind, feature: feature)).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
            // Wraps instead of clipping at large text sizes or narrow popovers.
            WrappingChips(spacing: DSSpacing.sm) {
                if status != .restricted {
                    Button(model.actionTitle(for: kind)) {
                        Task {
                            let wasDenied = model.status(kind) == .denied
                            let result = await model.requestAccess(kind)
                            // A first-time prompt the user declined stays put; an "again" that did not help opens the pane.
                            if wasDenied, result != .granted { openURL(model.settingsURL(for: kind)) }
                        }
                    }
                    .accessibilityIdentifier("\(base).request")
                }
                if status == .denied {
                    Button("Re-check") { Task { await model.recheck(kind) } }.accessibilityIdentifier("\(base).recheck")
                }
                Button("Open System Settings") { openURL(model.settingsURL(for: kind)) }
                    .buttonStyle(.link).accessibilityIdentifier("\(base).openSettings")
                if status == .denied {
                    Button(showsReset ? "Hide reset hint" : "Reset and re-request") { showsReset.toggle() }
                        .buttonStyle(.link).accessibilityIdentifier("\(base).resetToggle")
                }
            }
            if status == .denied, let stale = kind.staleEntryHint {
                Text(stale)
                    .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(base).staleEntryHint")
            }
            if showsReset, status == .denied {
                Text("Still stuck? Quit Earmark, run this in Terminal, then reopen it: \(kind.resetHint())")
                    .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText).textSelection(.enabled)
                    .accessibilityIdentifier("\(base).resetHint")
            }
        }
    }
}
