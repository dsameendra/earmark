import AppCore
import Foundation
import os

/// Process-lifetime memory (tests, previews).
public final class InMemoryPermissionMemory: PermissionMemory {
    private struct State {
        var requested: Set<PermissionKind> = []
        var outcomes: [PermissionKind: PermissionStatus] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    public init() {}
    public func hasRequested(_ kind: PermissionKind) -> Bool { state.withLock { $0.requested.contains(kind) } }
    public func markRequested(_ kind: PermissionKind) { state.withLock { _ = $0.requested.insert(kind) } }
    public func lastOutcome(_ kind: PermissionKind) -> PermissionStatus? { state.withLock { $0.outcomes[kind] } }
    public func setLastOutcome(_ kind: PermissionKind, _ status: PermissionStatus) { state.withLock { $0.outcomes[kind] = status } }
}

/// `UserDefaults`-backed memory so "already asked" survives relaunch.
public final class UserDefaultsPermissionMemory: PermissionMemory, @unchecked Sendable {
    // UserDefaults is documented thread-safe.
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private func requestedKey(_ kind: PermissionKind) -> String { "permissions.requested.\(kind.rawValue)" }
    private func outcomeKey(_ kind: PermissionKind) -> String { "permissions.outcome.\(kind.rawValue)" }
    public func hasRequested(_ kind: PermissionKind) -> Bool { defaults.bool(forKey: requestedKey(kind)) }
    public func markRequested(_ kind: PermissionKind) { defaults.set(true, forKey: requestedKey(kind)) }
    public func lastOutcome(_ kind: PermissionKind) -> PermissionStatus? {
        defaults.string(forKey: outcomeKey(kind)).flatMap(PermissionStatus.init(rawValue:))
    }
    public func setLastOutcome(_ kind: PermissionKind, _ status: PermissionStatus) {
        defaults.set(status.rawValue, forKey: outcomeKey(kind))
    }
}
