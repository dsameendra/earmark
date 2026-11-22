import AppCore
import FeatureSupport
import Foundation
import LiveCaptions
import ServiceManagement
import os

/// Registers the app as a login item (SET-AC-02).
public protocol LaunchAtLoginControlling: Sendable {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

/// `SMAppService.mainApp`-backed implementation.
public struct SMAppServiceLaunchAtLogin: LaunchAtLoginControlling {
    public init() {}
    public var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// In-memory login item for tests and previews.
public final class InMemoryLaunchAtLogin: LaunchAtLoginControlling {
    private let state = OSAllocatedUnfairLock(initialState: false)
    public init() {}
    public var isEnabled: Bool { state.withLock { $0 } }
    public func setEnabled(_ enabled: Bool) throws { state.withLock { $0 = enabled } }
}

/// Everything the Settings scene needs, expressed as AppCore protocols (built by the composition root).
public struct SettingsDependencies: Sendable {
    public var store: any SettingsStore
    public var models: any ModelManaging
    public var hardware: any HardwareTierProviding
    public var audioDevices: any AudioDeviceProviding
    public var permissions: any PermissionsServicing
    public var rules: any RuleRepository
    public var presets: any PresetRepository
    public var hotkeys: (any HotkeyServicing)?
    public var transcripts: (any TranscriptRepository)?
    /// Global hotkey health for Settings > Shortcuts (nil when no hotkey service is wired).
    public var hotkeyDiagnostics: (any HotkeyDiagnosing)?
    /// Retries a failed global hotkey registration (after the user grants access).
    public var retryHotkeys: (@Sendable () async -> Void)?
    public var launchAtLogin: any LaunchAtLoginControlling
    /// Connected displays for the caption overlay picker (nil means the system's).
    public var displays: (any DisplayProviding)?
    /// Moves the live caption overlay and shows the test caption (nil disables the preview).
    public var overlayPlacement: (any OverlayPlacementControlling)?
    /// Removes regenerable caches and returns the bytes freed.
    public var clearCaches: @Sendable () async -> Int64

    public init(
        store: any SettingsStore, models: any ModelManaging, hardware: any HardwareTierProviding,
        audioDevices: any AudioDeviceProviding, permissions: any PermissionsServicing, rules: any RuleRepository,
        presets: any PresetRepository, hotkeys: (any HotkeyServicing)? = nil, transcripts: (any TranscriptRepository)? = nil,
        hotkeyDiagnostics: (any HotkeyDiagnosing)? = nil, retryHotkeys: (@Sendable () async -> Void)? = nil,
        launchAtLogin: any LaunchAtLoginControlling = SMAppServiceLaunchAtLogin(),
        displays: (any DisplayProviding)? = nil, overlayPlacement: (any OverlayPlacementControlling)? = nil,
        clearCaches: @escaping @Sendable () async -> Int64 = { SettingsDependencies.clearDefaultCaches() }
    ) {
        self.store = store
        self.models = models
        self.hardware = hardware
        self.audioDevices = audioDevices
        self.permissions = permissions
        self.rules = rules
        self.presets = presets
        self.hotkeys = hotkeys
        self.transcripts = transcripts
        self.hotkeyDiagnostics = hotkeyDiagnostics
        self.retryHotkeys = retryHotkeys
        self.launchAtLogin = launchAtLogin
        self.displays = displays
        self.overlayPlacement = overlayPlacement
        self.clearCaches = clearCaches
    }

    /// Placeholder wiring used when the app only supplies a `SettingsStore`.
    public static func standalone(store: any SettingsStore) -> SettingsDependencies {
        SettingsDependencies(
            store: store, models: StaticModels(), hardware: PlaceholderHardware(), audioDevices: PlaceholderAudioDevices(),
            permissions: PlaceholderPermissions(), rules: InMemoryRuleRepository(), presets: InMemoryPresetRepository())
    }

    /// Deletes the contents of this app's folder in the user caches directory.
    public static func clearDefaultCaches() -> Int64 {
        let fm = FileManager.default
        guard let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent(AppLog.subsystem),
            let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        else { return 0 }
        var freed: Int64 = 0
        for item in items {
            let size = (try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0
            if (try? fm.removeItem(at: item)) != nil { freed += Int64(size) }
        }
        return freed
    }
}

/// In-memory `RuleRepository` (tests, previews, standalone wiring).
public actor InMemoryRuleRepository: RuleRepository {
    private var ignore: [IgnoreRule]
    private var replacements: [ReplacementRule]
    public init(ignore: [IgnoreRule] = [], replacements: [ReplacementRule] = []) {
        self.ignore = ignore
        self.replacements = replacements
    }
    public func ignoreRules() -> [IgnoreRule] { ignore }
    public func saveIgnoreRule(_ rule: IgnoreRule) {
        if let index = ignore.firstIndex(where: { $0.id == rule.id }) { ignore[index] = rule } else { ignore.append(rule) }
    }
    public func removeIgnoreRule(_ id: RuleID) { ignore.removeAll { $0.id == id } }
    public func replaceAllIgnoreRules(_ rules: [IgnoreRule]) { ignore = rules }
    public func replacementRules() -> [ReplacementRule] { replacements }
    public func saveReplacementRule(_ rule: ReplacementRule) {
        if let index = replacements.firstIndex(where: { $0.id == rule.id }) {
            replacements[index] = rule
        } else {
            replacements.append(rule)
        }
    }
    public func removeReplacementRule(_ id: RuleID) { replacements.removeAll { $0.id == id } }
}

/// In-memory `PresetRepository` (tests, previews, standalone wiring).
public actor InMemoryPresetRepository: PresetRepository {
    private var caption: [CaptionPreset]
    private var export: [ExportPreset]
    public init(caption: [CaptionPreset] = [], export: [ExportPreset] = []) {
        self.caption = caption
        self.export = export
    }
    public func captionPresets() -> [CaptionPreset] { caption }
    public func save(_ preset: CaptionPreset) {
        if let index = caption.firstIndex(where: { $0.id == preset.id }) { caption[index] = preset } else { caption.append(preset) }
    }
    public func exportPresets() -> [ExportPreset] { export }
    public func save(_ preset: ExportPreset) {
        if let index = export.firstIndex(where: { $0.id == preset.id }) { export[index] = preset } else { export.append(preset) }
    }
    public func softDeletePreset(_ id: PresetID) {
        if let index = caption.firstIndex(where: { $0.id == id }) { caption[index].deletedAt = Date() }
        if let index = export.firstIndex(where: { $0.id == id }) { export[index].deletedAt = Date() }
    }
}
