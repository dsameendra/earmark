import AppCore
import Foundation
import os

// Placeholder implementations for protocols whose real implementation has not landed yet (JobQueue, LiveSessionControlling,
// MeetingDetector, PermissionsServicing, AudioDeviceProviding) plus in-memory stand-ins used by previews and tests.

/// In-memory job queue. Real queue: T10.
public actor PlaceholderJobQueue: JobQueue {
    private var store: [Job]
    private let bus = Broadcaster<JobEvent>()

    public init(seed: [Job] = []) { store = seed }

    public func enqueue(_ job: Job) async throws -> JobID {
        store.append(job)
        bus.send(.updated(job))
        return job.id
    }

    public func enqueue(files: [URL], settings: JobSettings, recursive: Bool) async throws -> [JobID] {
        var ids: [JobID] = []
        for url in files { ids.append(try await enqueue(Job(kind: .transcribeFile, input: url, settings: settings))) }
        return ids
    }

    public func prioritize(_ id: JobID, to index: Int) async {
        guard let from = store.firstIndex(where: { $0.id == id }) else { return }
        let job = store.remove(at: from)
        store.insert(job, at: max(0, min(index, store.count)))
    }

    public func pause(_ id: JobID) async { update(id) { if $0.state == .running || $0.state == .pending { $0.state = .paused } } }
    public func resume(_ id: JobID) async { update(id) { if $0.state == .paused { $0.state = .pending } } }
    public func cancel(_ id: JobID) async { update(id) { $0.state = .cancelled } }
    public func retry(_ id: JobID) async {
        update(id) {
            $0.state = .pending
            $0.progress = 0
            $0.failureReason = nil
        }
    }
    public func remove(_ id: JobID) async throws {
        store.removeAll { $0.id == id }
        bus.send(.removed(id))
    }
    public func setMaxConcurrency(_ n: Int) async {}
    public func jobs() async -> [Job] { store }
    public nonisolated func events() -> AsyncStream<JobEvent> { bus.stream() }
    public func resumeInterrupted() async {}

    private func update(_ id: JobID, _ change: (inout Job) -> Void) {
        guard let index = store.firstIndex(where: { $0.id == id }) else { return }
        change(&store[index])
        bus.send(.updated(store[index]))
    }
}

/// Live session stand-in that reports a running state and one explanatory caption. Real controller: T18.
public actor PlaceholderLiveSession: LiveSessionControlling {
    private let stateBus = Broadcaster<LiveSessionState>()
    private let linesBus = Broadcaster<[CaptionLine]>()

    public init() {}

    public func start(_ config: LiveSessionConfig) async throws {
        stateBus.send(.running)
        linesBus.send([CaptionLine(text: "Live captions engine is not connected yet.", isVolatile: true)])
    }

    public func stop() async -> TranscriptID? {
        stateBus.send(.idle)
        linesBus.send([])
        return nil
    }

    public nonisolated func state() -> AsyncStream<LiveSessionState> { stateBus.stream(initial: .idle) }
    public nonisolated func lines() -> AsyncStream<[CaptionLine]> { linesBus.stream(initial: []) }
}

/// Never emits. Real detector: T23.
public struct PlaceholderMeetingDetector: MeetingDetector {
    public init() {}
    public func events() -> AsyncStream<MeetingEvent> { AsyncStream { _ in } }
}

/// Reports `.notDetermined` for everything. Real service: T20.
public struct PlaceholderPermissions: PermissionsServicing {
    public init() {}
    public func status(_ kind: PermissionKind) async -> PermissionStatus { .notDetermined }
    public func request(_ kind: PermissionKind) async -> PermissionStatus { .notDetermined }
    public func settingsURL(for kind: PermissionKind) -> URL {
        let anchor: String
        switch kind {
        case .microphone: anchor = "Privacy_Microphone"
        case .systemAudioRecording: anchor = "Privacy_AudioCapture"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .notifications: anchor = "Privacy_Notifications"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") ?? URL(fileURLWithPath: "/")
    }
    public func changes() -> AsyncStream<(PermissionKind, PermissionStatus)> { AsyncStream { _ in } }
}

/// One "System Default" input. Real provider: T17.
public struct PlaceholderAudioDevices: AudioDeviceProviding {
    public init() {}
    private static let systemDefault = AudioDevice(id: "default", name: "System Default Input", isInput: true, isOutput: false)
    public func devices() async -> [AudioDevice] { [Self.systemDefault] }
    public func defaultInput() async -> AudioDevice? { Self.systemDefault }
    public func changes() -> AsyncStream<Void> { AsyncStream { _ in } }
}

/// Fixed 18 GB profile for previews and tests.
public struct PlaceholderHardware: HardwareTierProviding {
    public init() {}
    public var profile: HardwareProfile {
        HardwareProfile(chip: "Apple Silicon", memoryBytes: 18 << 30, performanceCores: 6, tier: .tier16)
    }
    public func memoryPressure() -> AsyncStream<Void> { AsyncStream { _ in } }
    public func thermalPressure() -> AsyncStream<ThermalPressure> { AsyncStream { _ in } }
    public func isOnBattery() -> Bool { false }
}

/// Empty, inert model manager for previews.
public struct StaticModels: ModelManaging {
    private let descriptors: [ModelDescriptor]
    private let installed: Set<ModelID>
    public init(catalog: [ModelDescriptor] = [], installed: Set<ModelID> = []) {
        descriptors = catalog
        self.installed = installed
    }
    public func catalog() async -> [ModelDescriptor] { descriptors }
    public func state(of model: ModelID) async -> ModelState { installed.contains(model) ? .installed(bytesOnDisk: 1) : .notInstalled }
    public func stateChanges() -> AsyncStream<(ModelID, ModelState)> { AsyncStream { _ in } }
    public func installedModels() async -> Set<ModelID> { installed }
    public func ensureAvailable(_ model: ModelID) -> AsyncThrowingStream<ModelDownloadEvent, any Error> {
        AsyncThrowingStream { continuation in
            if !installed.contains(model) { continuation.yield(.progress(fraction: 0.5, bytesReceived: 1, bytesTotal: 2)) }
            continuation.yield(.completed)
            continuation.finish()
        }
    }
    public func pauseDownload(_ model: ModelID) async {}
    public func resumeDownload(_ model: ModelID) async {}
    public func cancelDownload(_ model: ModelID) async {}
    public func delete(_ model: ModelID) async throws {}
    public func importModel(folder: URL, displayName: String, languages: Set<LanguageCode>) async throws -> ModelDescriptor {
        throw AppError.other("Not available in previews")
    }
    public func diskUsage() async -> DiskUsage { DiskUsage(totalBytes: 0, perModel: [:]) }
    public func location(of model: ModelID) async throws -> URL { throw AppError.modelNotInstalled(model) }
}

/// Key-value settings kept in memory, with change streams.
public final class InMemorySettingsStore: SettingsStore {
    private let storage = OSAllocatedUnfairLock<[String: Data]>(initialState: [:])
    private let bus = Broadcaster<String>()

    public init() {}

    public func value<T: Codable & Sendable>(for key: String, as type: T.Type) async -> T? {
        guard let data = storage.withLock({ $0[key] }) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    public func set<T: Codable & Sendable>(_ value: T, for key: String) async {
        guard let data = try? JSONEncoder().encode(value) else { return }
        storage.withLock { $0[key] = data }
        bus.send(key)
    }

    public func changes(for key: String) -> AsyncStream<Void> {
        let source = bus.stream()
        return AsyncStream { continuation in
            let task = Task {
                for await changed in source where changed == key { continuation.yield() }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// In-memory transcript repository honouring every `LibraryQuery` filter, sort, segments and a naive full-text search.
public actor InMemoryTranscripts: TranscriptRepository {
    private var items: [Transcript]
    private var segmentStore: [TranscriptID: [Segment]] = [:]

    public init(items: [Transcript] = [], segments: [TranscriptID: [Segment]] = [:]) {
        self.items = items
        segmentStore = segments
    }

    public func list(_ query: LibraryQuery) async throws -> [Transcript] {
        var result = items.filter { ($0.deletedAt != nil) == query.deletedOnly }
        if !query.sources.isEmpty { result = result.filter { query.sources.contains($0.source) } }
        if !query.languages.isEmpty { result = result.filter { !$0.languages.isDisjoint(with: query.languages) } }
        if let folder = query.folderID { result = result.filter { $0.folderID == folder } }
        if !query.tags.isEmpty { result = result.filter { query.tags.isSubset(of: Set($0.tags)) } }
        if !query.speakerNames.isEmpty { result = result.filter { !Set($0.speakers.map(\.name)).isDisjoint(with: query.speakerNames) } }
        if let range = query.dateRange { result = result.filter { range.contains($0.createdAt) } }
        if let range = query.durationRange { result = result.filter { range.contains($0.duration) } }
        if let text = query.text, !text.isEmpty {
            result = result.filter { item in
                item.title.localizedCaseInsensitiveContains(text)
                    || (segmentStore[item.id] ?? []).contains { !$0.isIgnored && $0.text.localizedCaseInsensitiveContains(text) }
            }
        }
        switch query.sort {
        case .createdDesc: result.sort { $0.createdAt > $1.createdAt }
        case .createdAsc: result.sort { $0.createdAt < $1.createdAt }
        case .titleAsc: result.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .durationDesc: result.sort { $0.duration > $1.duration }
        case .modifiedDesc: result.sort { $0.modifiedAt > $1.modifiedAt }
        }
        if let limit = query.limit { result = Array(result.prefix(limit)) }
        return result
    }
    public func transcript(_ id: TranscriptID) async throws -> Transcript? { items.first { $0.id == id } }
    public func save(_ transcript: Transcript) async throws {
        if let index = items.firstIndex(where: { $0.id == transcript.id }) { items[index] = transcript } else { items.append(transcript) }
    }
    public func segments(for id: TranscriptID) async throws -> [Segment] { segmentStore[id] ?? [] }
    public func upsertSegments(_ segments: [Segment], for id: TranscriptID) async throws {
        var current = segmentStore[id] ?? []
        for segment in segments {
            if let index = current.firstIndex(where: { $0.id == segment.id }) { current[index] = segment } else { current.append(segment) }
        }
        segmentStore[id] = current
    }
    public func replaceSegments(_ segments: [Segment], for id: TranscriptID) async throws { segmentStore[id] = segments }
    public func search(_ text: String, limit: Int) async throws -> [SearchHit] {
        var hits: [SearchHit] = []
        for item in items where item.deletedAt == nil {
            for segment in segmentStore[item.id] ?? [] where !segment.isIgnored && segment.text.localizedCaseInsensitiveContains(text) {
                hits.append(SearchHit(transcriptID: item.id, segmentID: segment.id, snippet: segment.text, time: segment.start))
            }
        }
        return Array(hits.prefix(limit))
    }
    public func softDelete(_ ids: [TranscriptID], at date: Date) async throws {
        for index in items.indices where ids.contains(items[index].id) { items[index].deletedAt = date }
    }
    public func restore(_ ids: [TranscriptID]) async throws {
        for index in items.indices where ids.contains(items[index].id) { items[index].deletedAt = nil }
    }
    public func purge(_ ids: [TranscriptID]) async throws {
        items.removeAll { ids.contains($0.id) }
        for id in ids { segmentStore[id] = nil }
    }
    public func purgeDeleted(before date: Date) async throws -> Int {
        let before = items.count
        items.removeAll { ($0.deletedAt ?? .distantFuture) < date }
        return before - items.count
    }
    public func bookmarks(for id: TranscriptID) async throws -> [TranscriptBookmark] { [] }
    public func save(_ bookmark: TranscriptBookmark) async throws {}
}

/// In-memory media repository.
public actor InMemoryMedia: MediaRepository {
    private var items: [MediaAssetID: MediaAsset]
    public init(items: [MediaAsset] = []) { self.items = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) }) }
    public func asset(_ id: MediaAssetID) async throws -> MediaAsset? { items[id] }
    public func save(_ asset: MediaAsset) async throws { items[asset.id] = asset }
    public func softDelete(_ id: MediaAssetID) async throws { items[id]?.deletedAt = Date() }
}

/// In-memory meeting repository.
public actor InMemoryMeetings: MeetingRepository {
    private var items: [Meeting]
    public init(items: [Meeting] = []) { self.items = items }
    public func meetings() async throws -> [Meeting] { items.filter { $0.deletedAt == nil } }
    public func save(_ meeting: Meeting) async throws {
        if let index = items.firstIndex(where: { $0.id == meeting.id }) { items[index] = meeting } else { items.append(meeting) }
    }
    public func softDelete(_ id: MeetingID) async throws {
        if let index = items.firstIndex(where: { $0.id == id }) { items[index].deletedAt = Date() }
    }
}

/// In-memory voice profile repository for previews and tests.
public actor InMemoryVoiceProfiles: VoiceProfileRepository {
    private var items: [VoiceProfile]
    public init(items: [VoiceProfile] = []) { self.items = items }
    public func profiles() async throws -> [VoiceProfile] { items.filter { $0.deletedAt == nil } }
    public func save(_ profile: VoiceProfile) async throws {
        if let index = items.firstIndex(where: { $0.id == profile.id }) { items[index] = profile } else { items.append(profile) }
    }
    public func softDelete(_ id: VoiceProfileID) async throws {
        if let index = items.firstIndex(where: { $0.id == id }) { items[index].deletedAt = Date() }
    }
}
