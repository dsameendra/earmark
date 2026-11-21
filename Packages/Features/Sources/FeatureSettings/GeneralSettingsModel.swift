import AppCore
import FeatureSupport
import Foundation
import Observation

/// General settings: Dock icon visibility and keep-running, persisted immediately (SET-AC-01/02, MENU-AC-08).
@MainActor @Observable
public final class GeneralSettingsModel {
    public private(set) var showDockIcon = true
    public private(set) var keepRunning = false

    @ObservationIgnored private let store: any SettingsStore

    public init(store: any SettingsStore) { self.store = store }

    public func load() async {
        showDockIcon = await store.value(for: SettingsKey.showDockIcon, as: Bool.self) ?? true
        keepRunning = await store.value(for: SettingsKey.keepRunning, as: Bool.self) ?? false
    }

    public func setShowDockIcon(_ value: Bool) async {
        showDockIcon = value
        await store.set(value, for: SettingsKey.showDockIcon)
    }

    public func setKeepRunning(_ value: Bool) async {
        keepRunning = value
        await store.set(value, for: SettingsKey.keepRunning)
    }

    /// Reads the persisted Dock-icon preference (default `true`).
    public static func loadShowDockIcon(from store: any SettingsStore) async -> Bool {
        await store.value(for: SettingsKey.showDockIcon, as: Bool.self) ?? true
    }
}
