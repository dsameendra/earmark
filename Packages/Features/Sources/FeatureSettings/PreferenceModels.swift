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

/// A validated library move waiting for the user's confirmation (LIB-AC-13): no file is touched before they confirm.
public struct PendingLibraryMove: Equatable, Sendable {
    public var plan: StorageRelocation.Plan
    /// `true` when the destination is the default location (the stored setting is cleared instead of set).
    public var toDefault: Bool
}

/// Storage: breakdown, library location (with move and confirm), caches, Recently Deleted retention (LIB-AC-13, SET-AC-15).
@MainActor @Observable
public final class StorageSettingsModel {
    public static let retentionChoices = [7, 14, 30, 60, 90]
    public let libraryLocation: Pref<String>
    public let retentionDays: Pref<Int>
    public private(set) var modelUsage = DiskUsage(totalBytes: 0, perModel: [:])
    public private(set) var breakdown: StorageBreakdown?
    public private(set) var lastFreedBytes: Int64?
    public private(set) var lastPurged: Int?
    @ObservationIgnored private let purger: MediaPurger?
    /// A move waiting for the user's confirmation.
    public private(set) var pendingMove: PendingLibraryMove?
    public private(set) var isMoving = false
    /// Set after a successful move: new meeting recordings use the new folder after the next launch.
    public private(set) var movedNotice: String?
    public var errorMessage: String?

    @ObservationIgnored private let models: any ModelManaging
    @ObservationIgnored private let transcripts: (any TranscriptRepository)?
    @ObservationIgnored private let clearCachesAction: @Sendable () async -> Int64
    @ObservationIgnored private let meetingLocation: Pref<String>
    @ObservationIgnored private let defaultBase: URL
    @ObservationIgnored private let cachesDirectory: URL?
    @ObservationIgnored private let databaseFiles: [URL]
    @ObservationIgnored private let activate: @Sendable (URL) -> Void

    public init(
        store: any SettingsStore, models: any ModelManaging, transcripts: (any TranscriptRepository)?,
        purger: MediaPurger? = nil, clearCaches: @escaping @Sendable () async -> Int64,
        defaultBase: URL = LibraryLocation.defaultBase,
        cachesDirectory: URL? = SettingsDependencies.defaultCachesDirectory,
        databaseFiles: [URL] = LibraryLocation.databaseFiles,
        activate: @escaping @Sendable (URL) -> Void = { LibraryLocation.use(base: $0) }
    ) {
        self.purger = purger
        self.models = models
        self.transcripts = transcripts
        clearCachesAction = clearCaches
        self.defaultBase = defaultBase
        self.cachesDirectory = cachesDirectory
        self.databaseFiles = databaseFiles
        self.activate = activate
        libraryLocation = Pref(SettingsKey.libraryLocation, default: "", store: store)
        meetingLocation = Pref(SettingsKey.meetingStorageLocation, default: "", store: store)
        retentionDays = Pref(SettingsKey.recentlyDeletedRetentionDays, default: 30, store: store)
    }

    /// The folder that currently holds `Library/` and `Meetings/`.
    public var currentBase: URL {
        libraryLocation.value.isEmpty ? defaultBase : URL(fileURLWithPath: libraryLocation.value, isDirectory: true)
    }

    public var isDefaultLocation: Bool { libraryLocation.value.isEmpty }

    /// Recordings live in `Meetings/` unless a separate meetings folder was chosen in the Meetings section.
    private var meetingsRoot: URL {
        meetingLocation.value.isEmpty
            ? LibraryLocation.meetingsRoot(base: currentBase) : URL(fileURLWithPath: meetingLocation.value, isDirectory: true)
    }

    public func load() async {
        await libraryLocation.load()
        await meetingLocation.load()
        await retentionDays.load()
        modelUsage = await models.diskUsage()
        await refreshBreakdown()
    }

    /// Measures library, models, recordings and caches off the main actor.
    public func refreshBreakdown() async {
        let library = [LibraryLocation.libraryRoot(base: currentBase)] + databaseFiles
        let recordings = meetingsRoot
        let caches = cachesDirectory
        let modelBytes = modelUsage.totalBytes
        breakdown = await Task.detached(priority: .utility) {
            StorageBreakdown(
                library: DiskMeasure.bytes(of: library), models: modelBytes, recordings: DiskMeasure.bytes(of: recordings),
                caches: caches.map { DiskMeasure.bytes(of: $0) } ?? 0)
        }.value
    }

    public func clearCaches() async {
        lastFreedBytes = await clearCachesAction()
        await refreshBreakdown()
    }

    // MARK: Library location (LIB-AC-13)

    /// Validates a chosen folder and queues a move for confirmation; nothing is changed yet.
    public func proposeLocation(_ folder: URL) async {
        errorMessage = nil
        movedNotice = nil
        let source = currentBase
        let movesMeetings = meetingLocation.value.isEmpty
        let toDefault = folder.standardizedFileURL.resolvingSymlinksInPath() == defaultBase.standardizedFileURL.resolvingSymlinksInPath()
        do {
            let plan = try await Task.detached { try StorageRelocation.plan(from: source, to: folder, movesMeetings: movesMeetings) }
                .value
            pendingMove = PendingLibraryMove(plan: plan, toDefault: toDefault)
        } catch {
            pendingMove = nil
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Could not use that folder: \(error)"
        }
    }

    /// Returns to the default location (Application Support) through the same confirm step.
    public func proposeDefaultLocation() async {
        try? FileManager.default.createDirectory(at: defaultBase, withIntermediateDirectories: true)
        await proposeLocation(defaultBase)
    }

    public func cancelMove() { pendingMove = nil }

    /// Performs the confirmed move, then switches the library location. A failure leaves everything where it was.
    public func confirmMove(_ confirmed: PendingLibraryMove? = nil) async {
        guard let pending = confirmed ?? pendingMove, !isMoving else { return }
        isMoving = true
        defer { isMoving = false }
        let plan = pending.plan
        do {
            try await Task.detached(priority: .userInitiated) { try StorageRelocation.move(plan) }.value
        } catch {
            pendingMove = nil
            errorMessage = "Could not move the library: \(error.localizedDescription). Nothing was changed."
            return
        }
        let base = pending.toDefault ? defaultBase : plan.destination
        await libraryLocation.set(pending.toDefault ? "" : plan.destination.path)
        activate(base)
        pendingMove = nil
        movedNotice = "Library moved. New meeting recordings use the new folder after you restart Earmark."
        await refreshBreakdown()
    }

    /// Permanently removes items deleted longer ago than the retention period.
    public func purgeExpiredNow(now: Date = Date()) async {
        guard let transcripts else { return }
        let cutoff = now.addingTimeInterval(-Double(retentionDays.value) * 86_400)
        if let purger { lastPurged = try? await purger.purgeDeleted(before: cutoff) } else {
            lastPurged = try? await transcripts.purgeDeleted(before: cutoff)
        }
        await refreshBreakdown()
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
