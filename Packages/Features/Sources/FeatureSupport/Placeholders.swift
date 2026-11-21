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
    public init() {}
    public func catalog() async -> [ModelDescriptor] { [] }
    public func state(of model: ModelID) async -> ModelState { .notInstalled }
    public func stateChanges() -> AsyncStream<(ModelID, ModelState)> { AsyncStream { _ in } }
    public func installedModels() async -> Set<ModelID> { [] }
    public func ensureAvailable(_ model: ModelID) -> AsyncThrowingStream<ModelDownloadEvent, any Error> {
        AsyncThrowingStream { $0.finish() }
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

/// In-memory transcript repository supporting list, soft delete, restore and naive title search.
public actor InMemoryTranscripts: TranscriptRepository {
    private var items: [Transcript]

    public init(items: [Transcript] = []) { self.items = items }

    public func list(_ query: LibraryQuery) async throws -> [Transcript] {
        var result = items.filter { ($0.deletedAt != nil) == query.deletedOnly }
        if let text = query.text, !text.isEmpty { result = result.filter { $0.title.localizedCaseInsensitiveContains(text) } }
        result.sort { $0.createdAt > $1.createdAt }
        if let limit = query.limit { result = Array(result.prefix(limit)) }
        return result
    }
    public func transcript(_ id: TranscriptID) async throws -> Transcript? { items.first { $0.id == id } }
    public func save(_ transcript: Transcript) async throws {
        if let index = items.firstIndex(where: { $0.id == transcript.id }) { items[index] = transcript } else { items.append(transcript) }
    }
    public func segments(for id: TranscriptID) async throws -> [Segment] { [] }
    public func upsertSegments(_ segments: [Segment], for id: TranscriptID) async throws {}
    public func replaceSegments(_ segments: [Segment], for id: TranscriptID) async throws {}
    public func search(_ text: String, limit: Int) async throws -> [SearchHit] { [] }
    public func softDelete(_ ids: [TranscriptID], at date: Date) async throws {
        for index in items.indices where ids.contains(items[index].id) { items[index].deletedAt = date }
    }
    public func restore(_ ids: [TranscriptID]) async throws {
        for index in items.indices where ids.contains(items[index].id) { items[index].deletedAt = nil }
    }
    public func purge(_ ids: [TranscriptID]) async throws { items.removeAll { ids.contains($0.id) } }
    public func purgeDeleted(before date: Date) async throws -> Int {
        let before = items.count
        items.removeAll { ($0.deletedAt ?? .distantFuture) < date }
        return before - items.count
    }
    public func bookmarks(for id: TranscriptID) async throws -> [TranscriptBookmark] { [] }
    public func save(_ bookmark: TranscriptBookmark) async throws {}
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
