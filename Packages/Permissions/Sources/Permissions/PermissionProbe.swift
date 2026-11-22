import AppCore
import Foundation

/// What the OS can tell us about one permission, before Earmark's own bookkeeping is applied.
public enum RawPermissionState: String, Sendable, Equatable {
    case notDetermined, granted, denied, restricted
    /// The OS exposes no status for this permission (System Audio Recording has no public API).
    case indeterminate
}

/// The seam between `PermissionsService` and the operating system. The real implementation is
/// `SystemPermissionProbe`; tests inject a fake so every branch of the service logic is exercised without prompts.
public protocol PermissionProbing: Sendable {
    /// Current OS state without ever prompting.
    func rawState(_ kind: PermissionKind) async -> RawPermissionState
    /// Triggers the OS prompt (or the closest equivalent) and returns the outcome it observed.
    func performRequest(_ kind: PermissionKind) async -> RawPermissionState
    /// Input Monitoring (global key listening). Not part of the frozen `PermissionKind`; used by dictation hotkeys.
    func inputMonitoringGranted() -> Bool
    func requestInputMonitoring() -> Bool
}

/// Persists what Earmark itself has learned, because several panes cannot tell "never asked" from "denied".
public protocol PermissionMemory: Sendable {
    func hasRequested(_ kind: PermissionKind) -> Bool
    func markRequested(_ kind: PermissionKind)
    /// Last observed outcome for permissions the OS cannot report (System Audio Recording).
    func lastOutcome(_ kind: PermissionKind) -> PermissionStatus?
    func setLastOutcome(_ kind: PermissionKind, _ status: PermissionStatus)
}
