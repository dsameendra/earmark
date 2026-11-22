import AppCore
import Foundation
import os

/// Permissions fake: reports `initial` until a request, then `afterRequest`.
struct ScriptedPermissions: PermissionsServicing {
    let initial: PermissionStatus
    let afterRequest: PermissionStatus
    private let current = OSAllocatedUnfairLock<PermissionStatus?>(initialState: nil)

    init(initial: PermissionStatus, afterRequest: PermissionStatus) {
        self.initial = initial
        self.afterRequest = afterRequest
    }

    func status(_ kind: PermissionKind) async -> PermissionStatus { current.withLock { $0 } ?? initial }
    func request(_ kind: PermissionKind) async -> PermissionStatus {
        current.withLock { $0 = afterRequest }
        return afterRequest
    }
    func settingsURL(for kind: PermissionKind) -> URL { URL(fileURLWithPath: "/") }
    func changes() -> AsyncStream<(PermissionKind, PermissionStatus)> { AsyncStream { _ in } }
}
