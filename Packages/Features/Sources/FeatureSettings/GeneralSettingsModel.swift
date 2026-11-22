import AppCore
import FeatureSupport
import Foundation
import Observation

/// General settings: login item, Dock / menu bar visibility, default language mode, notifications (SET-AC-02, MENU-AC-08).
@MainActor @Observable
public final class GeneralSettingsModel {
    public private(set) var showDockIcon = true
    public private(set) var keepRunning = false
    public private(set) var launchAtLogin = false
    public var launchError: String?
    public let showMenuBarIcon: Pref<Bool>
    public let notificationsEnabled: Pref<Bool>
    public let notifyJobCompleted: Pref<Bool>
    public let languageMode: Pref<LanguageMode>

    @ObservationIgnored private let store: any SettingsStore
    @ObservationIgnored private let loginItem: any LaunchAtLoginControlling

    public init(store: any SettingsStore, loginItem: any LaunchAtLoginControlling = SMAppServiceLaunchAtLogin()) {
        self.store = store
        self.loginItem = loginItem
        showMenuBarIcon = Pref(SettingsKey.showMenuBarIcon, default: true, store: store)
        notificationsEnabled = Pref(SettingsKey.notificationsEnabled, default: true, store: store)
        notifyJobCompleted = Pref(SettingsKey.notifyJobCompleted, default: true, store: store)
        languageMode = Pref(SettingsKey.languageMode, default: .default, store: store)
    }

    public func load() async {
        showDockIcon = await store.value(for: SettingsKey.showDockIcon, as: Bool.self) ?? true
        keepRunning = await store.value(for: SettingsKey.keepRunning, as: Bool.self) ?? false
        launchAtLogin = loginItem.isEnabled
        await showMenuBarIcon.load()
        await notificationsEnabled.load()
        await notifyJobCompleted.load()
        await languageMode.load()
    }

    public func setShowDockIcon(_ value: Bool) async {
        showDockIcon = value
        await store.set(value, for: SettingsKey.showDockIcon)
    }

    public func setKeepRunning(_ value: Bool) async {
        keepRunning = value
        await store.set(value, for: SettingsKey.keepRunning)
    }

    /// Registers or unregisters the login item; on failure the toggle snaps back and the error is shown.
    public func setLaunchAtLogin(_ value: Bool) async {
        launchError = nil
        do {
            try loginItem.setEnabled(value)
            launchAtLogin = loginItem.isEnabled
        } catch {
            launchAtLogin = loginItem.isEnabled
            launchError = "Could not change the login item: \(error.localizedDescription)"
        }
        await store.set(launchAtLogin, for: SettingsKey.launchAtLogin)
    }

    /// The default language mode kind shown in General (English by default, LANG-AC-01).
    public var languageKind: LanguageModeKind {
        switch languageMode.value {
        case .single: .single
        case .autoDetect: .autoDetect
        case .multilingual: .multilingual
        }
    }

    /// Switches the default mode; multilingual keeps its set (configure it in Languages).
    public func setLanguageKind(_ kind: LanguageModeKind) async {
        switch (kind, languageMode.value) {
        case (.single, .single), (.autoDetect, .autoDetect), (.multilingual, .multilingual): return
        case (.single, _): await languageMode.set(.single(.english))
        case (.autoDetect, _): await languageMode.set(.autoDetect)
        case (.multilingual, _): await languageMode.set(.multilingual([.english]))
        }
    }

    /// Re-arms the welcome flow; the app presents it when it sees the completion flag cleared (ONB-AC-01).
    public func showWelcomeAgain() async {
        await store.set(0, for: SettingsKey.onboardingStep)
        await store.set(false, for: SettingsKey.onboardingCompleted)
    }

    /// Reads the persisted Dock-icon preference (default `true`).
    public static func loadShowDockIcon(from store: any SettingsStore) async -> Bool {
        await store.value(for: SettingsKey.showDockIcon, as: Bool.self) ?? true
    }
}
