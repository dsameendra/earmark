import AppCore
import FeatureSupport
import Foundation
import Observation

/// Dictation: mode, insertion, cleanup, translate-before-insert, history size (SET-AC-12).
@MainActor @Observable
public final class DictationSettingsModel {
    public let mode: Pref<HotkeyMode>
    public let insertion: Pref<TextInsertionMethod>
    public let removeFillers: Pref<Bool>
    public let autoPunctuate: Pref<Bool>
    public let translateBeforeInsert: Pref<Bool>
    public let historySize: Pref<Int>

    public init(store: any SettingsStore) {
        mode = Pref(SettingsKey.dictationMode, default: .pushToTalk, store: store)
        insertion = Pref(SettingsKey.dictationInsertion, default: .pasteboardPaste, store: store)
        removeFillers = Pref(SettingsKey.dictationRemoveFillers, default: false, store: store)
        autoPunctuate = Pref(SettingsKey.dictationAutoPunctuate, default: true, store: store)
        translateBeforeInsert = Pref(SettingsKey.dictationTranslateBeforeInsert, default: false, store: store)
        historySize = Pref(SettingsKey.dictationHistorySize, default: 50, store: store)
    }

    public func load() async {
        await mode.load()
        await insertion.load()
        await removeFillers.load()
        await autoPunctuate.load()
        await translateBeforeInsert.load()
        await historySize.load()
    }
}

/// Transcript appearance defaults.
@MainActor @Observable
public final class AppearanceSettingsModel {
    public let fontSize: Pref<Double>
    public let lineSpacing: Pref<Double>
    public let showTimestamps: Pref<Bool>
    public let showLanguageBadges: Pref<Bool>
    public let showIgnored: Pref<Bool>

    public init(store: any SettingsStore) {
        fontSize = Pref(SettingsKey.appearanceFontSize, default: 15, store: store)
        lineSpacing = Pref(SettingsKey.appearanceLineSpacing, default: 4, store: store)
        showTimestamps = Pref(SettingsKey.appearanceShowTimestamps, default: true, store: store)
        showLanguageBadges = Pref(SettingsKey.appearanceShowLanguageBadges, default: false, store: store)
        showIgnored = Pref(SettingsKey.appearanceShowIgnored, default: false, store: store)
    }

    public func load() async {
        await fontSize.load()
        await lineSpacing.load()
        await showTimestamps.load()
        await showLanguageBadges.load()
        await showIgnored.load()
    }
}

/// Translation defaults. Non-commercial engines (NLLB) stay off until the user opts in (ADR-006).
@MainActor @Observable
public final class TranslationSettingsModel {
    /// Empty string means "ask each time".
    public let targetLanguage: Pref<String>
    /// `auto`, `apple` or `nllb`.
    public let engine: Pref<String>
    public let allowNonCommercial: Pref<Bool>
    public let parallelTrack: Pref<Bool>

    public init(store: any SettingsStore) {
        targetLanguage = Pref(SettingsKey.translationTarget, default: "", store: store)
        engine = Pref(SettingsKey.translationEngine, default: "auto", store: store)
        allowNonCommercial = Pref(SettingsKey.translationAllowNonCommercial, default: false, store: store)
        parallelTrack = Pref(SettingsKey.translationParallelTrack, default: true, store: store)
    }

    public func load() async {
        await targetLanguage.load()
        await engine.load()
        await allowNonCommercial.load()
        await parallelTrack.load()
    }
}

/// Storage: library location, disk usage, caches, Recently Deleted retention (SET-AC-15).
@MainActor @Observable
public final class StorageSettingsModel {
    public static let retentionChoices = [7, 14, 30, 60, 90]
    public let libraryLocation: Pref<String>
    public let retentionDays: Pref<Int>
    public private(set) var modelUsage = DiskUsage(totalBytes: 0, perModel: [:])
    public private(set) var lastFreedBytes: Int64?
    public private(set) var lastPurged: Int?

    @ObservationIgnored private let models: any ModelManaging
    @ObservationIgnored private let transcripts: (any TranscriptRepository)?
    @ObservationIgnored private let clearCachesAction: @Sendable () async -> Int64

    public init(
        store: any SettingsStore, models: any ModelManaging, transcripts: (any TranscriptRepository)?,
        clearCaches: @escaping @Sendable () async -> Int64
    ) {
        self.models = models
        self.transcripts = transcripts
        clearCachesAction = clearCaches
        libraryLocation = Pref(SettingsKey.libraryLocation, default: "", store: store)
        retentionDays = Pref(SettingsKey.recentlyDeletedRetentionDays, default: 30, store: store)
    }

    public func load() async {
        await libraryLocation.load()
        await retentionDays.load()
        modelUsage = await models.diskUsage()
    }

    public func clearCaches() async { lastFreedBytes = await clearCachesAction() }

    /// Permanently removes items deleted longer ago than the retention period.
    public func purgeExpiredNow(now: Date = Date()) async {
        guard let transcripts else { return }
        let cutoff = now.addingTimeInterval(-Double(retentionDays.value) * 86_400)
        lastPurged = try? await transcripts.purgeDeleted(before: cutoff)
    }
}

/// Privacy & Permissions: status plus deep links (SET-AC-17).
@MainActor @Observable
public final class PermissionsSettingsModel {
    public private(set) var statuses: [PermissionKind: PermissionStatus] = [:]
    @ObservationIgnored private let service: any PermissionsServicing

    public init(service: any PermissionsServicing) { self.service = service }

    public func load() async {
        for kind in PermissionKind.allCases { statuses[kind] = await service.status(kind) }
    }

    public func observe() async {
        for await (kind, status) in service.changes() { statuses[kind] = status }
    }

    public func request(_ kind: PermissionKind) async { statuses[kind] = await service.request(kind) }

    public func settingsURL(for kind: PermissionKind) -> URL { service.settingsURL(for: kind) }

    public func status(_ kind: PermissionKind) -> PermissionStatus { statuses[kind] ?? .notDetermined }

    public func rowState(_ kind: PermissionKind, context: PermissionRowContext = .settings) -> PermissionRowState {
        PermissionRowState(kind: kind, status: status(kind), context: context)
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
}
