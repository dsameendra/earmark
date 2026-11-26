import AppCore
import AppCoreTesting
import Foundation
import os

@testable import Meetings

// MARK: - Clock

/// Deterministic clock: `sleep` suspends until `advance(by:)` moves time past its deadline.
final class ManualClock: MeetingClock {
    private struct Waiter {
        let id: Int
        let deadline: Date
        let continuation: CheckedContinuation<Void, any Error>
    }
    private struct State {
        var now: Date
        var waiters: [Waiter] = []
        var nextID = 0
    }
    private let state: OSAllocatedUnfairLock<State>

    init(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) { state = OSAllocatedUnfairLock(initialState: State(now: start)) }

    func now() -> Date { state.withLock { $0.now } }
    var sleeperCount: Int { state.withLock { $0.waiters.count } }

    func sleep(for seconds: TimeInterval) async throws {
        let id = state.withLock { s -> Int in
            s.nextID += 1
            return s.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let immediate = state.withLock { s -> Bool in
                    if Task.isCancelled { return true }
                    s.waiters.append(Waiter(id: id, deadline: s.now.addingTimeInterval(seconds), continuation: continuation))
                    return false
                }
                if immediate { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let waiter = state.withLock { s -> Waiter? in
                guard let i = s.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return s.waiters.remove(at: i)
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by seconds: TimeInterval) {
        let due = state.withLock { s -> [Waiter] in
            s.now = s.now.addingTimeInterval(seconds)
            let ready = s.waiters.filter { $0.deadline <= s.now }.sorted { $0.deadline < $1.deadline }
            s.waiters.removeAll { w in ready.contains { $0.id == w.id } }
            return ready
        }
        for waiter in due { waiter.continuation.resume() }
    }

    /// Waits (bounded) until `count` tasks are sleeping on this clock.
    func waitForSleepers(_ count: Int) async {
        for _ in 0..<2000 {
            if sleeperCount == count { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}

/// Collects values from a stream so tests can assert on what has (not) been emitted.
final class Collector<Element: Sendable>: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: [Element]())
    private let task: Task<Void, Never>
    init(_ stream: AsyncStream<Element>) {
        let storage = storage
        task = Task { for await item in stream { storage.withLock { $0.append(item) } } }
    }
    deinit { task.cancel() }
    var items: [Element] { storage.withLock { $0 } }
    func waitFor(count: Int) async {
        for _ in 0..<2000 {
            if items.count >= count { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
    /// Gives in-flight work a moment, then returns what arrived.
    func settled() async -> [Element] {
        try? await Task.sleep(for: .milliseconds(60))
        return items
    }
}

// MARK: - Probe

final class FakeProbe: MeetingProbe {
    private let values = OSAllocatedUnfairLock(initialState: [MeetingApp: AppAudioActivity]())
    private let broadcaster = Broadcaster<Void>()
    func set(_ app: MeetingApp, _ activity: AppAudioActivity) {
        values.withLock { $0[app] = activity }
        broadcaster.send(())
    }
    func activity(for app: MeetingApp) async -> AppAudioActivity { values.withLock { $0[app] } ?? .inactive }
    func changes() -> AsyncStream<Void> { broadcaster.stream() }

    private let browsers = OSAllocatedUnfairLock(initialState: (readings: [BrowserReading](), titles: false))
    func setBrowsers(_ readings: [BrowserReading], canReadTitles: Bool = true) {
        browsers.withLock { $0 = (readings, canReadTitles) }
        broadcaster.send(())
    }
    func browserReadings() async -> [BrowserReading] { browsers.withLock { $0.readings } }
    var canReadTitles: Bool { browsers.withLock { $0.titles } }
}

extension AppAudioActivity {
    static let inCall = AppAudioActivity(isAppRunning: true, micInput: true, audioOutput: true, deviceMicInUse: true)
    static let muted = AppAudioActivity(isAppRunning: true, micInput: false, audioOutput: true, deviceMicInUse: false)
    static let runningIdle = AppAudioActivity(isAppRunning: true)
}

// MARK: - Settings and repositories

actor InMemorySettings: SettingsStore {
    private var storage: [String: Data] = [:]
    private let broadcaster = Broadcaster<String>()
    func value<T: Codable & Sendable>(for key: String, as: T.Type) async -> T? {
        guard let data = storage[key] else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    func set<T: Codable & Sendable>(_ value: T, for key: String) async {
        storage[key] = try? JSONEncoder().encode(value)
        broadcaster.send(key)
    }
    nonisolated func changes(for key: String) -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

actor InMemoryMeetings: MeetingRepository {
    private(set) var saved: [Meeting] = []
    func meetings() async throws -> [Meeting] { saved }
    func save(_ meeting: Meeting) async throws {
        saved.removeAll { $0.id == meeting.id }
        saved.append(meeting)
    }
    func softDelete(_ id: MeetingID) async throws { saved.removeAll { $0.id == id } }
}

actor InMemoryMedia: MediaRepository {
    private(set) var assets: [MediaAsset] = []
    func asset(_ id: MediaAssetID) async throws -> MediaAsset? { assets.first { $0.id == id } }
    func save(_ asset: MediaAsset) async throws { assets.append(asset) }
    func softDelete(_ id: MediaAssetID) async throws {}
}

actor InMemoryProfiles: VoiceProfileRepository {
    var stored: [VoiceProfile]
    init(_ profiles: [VoiceProfile] = []) { stored = profiles }
    func profiles() async throws -> [VoiceProfile] { stored }
    func save(_ profile: VoiceProfile) async throws { stored.append(profile) }
    func softDelete(_ id: VoiceProfileID) async throws {}
}

actor InMemoryTranscripts: TranscriptRepository {
    var headers: [TranscriptID: Transcript] = [:]
    var segmentStore: [TranscriptID: [Segment]] = [:]
    var bookmarkStore: [TranscriptBookmark] = []
    var failSave = false

    func setFailSave(_ value: Bool) { failSave = value }
    func seed(_ id: TranscriptID, segments: [Segment]) { segmentStore[id] = segments }

    func list(_ query: LibraryQuery) async throws -> [Transcript] { Array(headers.values) }
    func transcript(_ id: TranscriptID) async throws -> Transcript? { headers[id] }
    func save(_ transcript: Transcript) async throws {
        if failSave { throw AppError.persistence(reason: "disk full") }
        headers[transcript.id] = transcript
    }
    func segments(for id: TranscriptID) async throws -> [Segment] { segmentStore[id] ?? [] }
    func upsertSegments(_ segments: [Segment], for id: TranscriptID) async throws { segmentStore[id, default: []] += segments }
    func replaceSegments(_ segments: [Segment], for id: TranscriptID) async throws { segmentStore[id] = segments }
    func search(_ text: String, limit: Int) async throws -> [SearchHit] { [] }
    func softDelete(_ ids: [TranscriptID], at date: Date) async throws {}
    func restore(_ ids: [TranscriptID]) async throws {}
    func purge(_ ids: [TranscriptID]) async throws {}
    func purgeDeleted(before date: Date) async throws -> Int { 0 }
    func bookmarks(for id: TranscriptID) async throws -> [TranscriptBookmark] { bookmarkStore.filter { $0.transcriptID == id } }
    func save(_ bookmark: TranscriptBookmark) async throws { bookmarkStore.append(bookmark) }
}

// MARK: - Engines and diarization

/// Repository whose `save` always throws, like a failing database.
actor FailingMeetings: MeetingRepository {
    struct Failure: Error {}
    func meetings() async throws -> [Meeting] { [] }
    func save(_ meeting: Meeting) async throws { throw Failure() }
    func softDelete(_ id: MeetingID) async throws {}
}

actor CallLog {
    private(set) var entries: [String] = []
    func add(_ entry: String) { entries.append(entry) }
}

/// Engine whose output is decided per file name (`mic.caf` / `remote.caf`).
final class ScriptedEngine: TranscriptionEngine {
    let id: EngineID = "scripted"
    let log: CallLog
    let script: @Sendable (String) -> Result<[Segment], AppError>
    let neverFinishes: Bool
    init(log: CallLog, neverFinishes: Bool = false, script: @escaping @Sendable (String) -> Result<[Segment], AppError>) {
        self.log = log
        self.script = script
        self.neverFinishes = neverFinishes
    }
    func supportedLanguages(model: ModelID?) async -> Set<LanguageCode> { [.english] }
    func prepare(model: ModelID) async throws { await log.add("prepare:\(model.rawValue)") }
    func unload() async {}
    func transcribe(file: URL, options: TranscriptionOptions) -> AsyncThrowingStream<TranscriptionEvent, any Error> {
        let name = file.lastPathComponent
        let log = log
        let result = script(name)
        let hang = neverFinishes
        return AsyncThrowingStream { c in
            if hang {
                c.onTermination = { _ in }
                return
            }
            Task {
                await log.add("transcribe:\(name):model=\(options.modelID?.rawValue ?? "auto")")
                switch result {
                case .success(let segments):
                    c.yield(.progress(fraction: 0.5, mediaTime: 1))
                    for s in segments { c.yield(.final(s)) }
                    c.yield(.progress(fraction: 1, mediaTime: 2))
                    c.finish()
                case .failure(let error): c.finish(throwing: error)
                }
            }
        }
    }
    func stream(audio: AsyncStream<AudioChunk>, options: TranscriptionOptions) -> AsyncThrowingStream<TranscriptionEvent, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

final class FakeDiarizer: Diarizer {
    let id: EngineID = "fake.diarizer"
    let log: CallLog
    let result: Result<[SpeakerTurn], AppError>
    init(log: CallLog, result: Result<[SpeakerTurn], AppError>) {
        self.log = log
        self.result = result
    }
    func diarize(file: URL, options: DiarizationOptions) async throws -> [SpeakerTurn] {
        await log.add("diarize:\(file.lastPathComponent)")
        return try result.get()
    }
    func diarize(audio: AsyncThrowingStream<AudioChunk, any Error>, options: DiarizationOptions) async throws -> [SpeakerTurn] {
        try result.get()
    }
}

final class FakeEmbeddings: SpeakerEmbeddingProvider {
    let log: CallLog
    let vectors: [Double: [Float]]  // keyed by range.start
    init(log: CallLog, vectors: [Double: [Float]]) {
        self.log = log
        self.vectors = vectors
    }
    func embedding(file: URL, range: TimeRange) async throws -> SpeakerEmbedding {
        await log.add("embed:\(range.start)")
        return SpeakerEmbedding(vector: vectors[range.start] ?? [0, 0, 1])
    }
}

// MARK: - Audio helpers

func tone(seconds: Double, amplitude: Float = 0.3, hz: Double = 440, start: Double = 0, source: AudioSourceTag = .mic(deviceUID: nil))
    -> AudioChunk
{
    let n = Int(seconds * 16_000)
    let samples = (0..<n).map { i in amplitude * Float(sin(2 * Double.pi * hz * (Double(i) / 16_000 + start))) }
    return AudioChunk(samples: samples, startSeconds: start, source: source)
}

func stream(_ chunks: [AudioChunk]) -> AsyncStream<AudioChunk> {
    AsyncStream { c in
        for chunk in chunks { c.yield(chunk) }
        c.finish()
    }
}

func tempDirectory(_ name: String = "meetings") -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("earmark-\(name)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

final class FakeDisk: DiskSpaceProviding {
    private let bytes: OSAllocatedUnfairLock<Int64>
    init(_ bytes: Int64 = 10_000_000_000) { self.bytes = OSAllocatedUnfairLock(initialState: bytes) }
    func set(_ value: Int64) { bytes.withLock { $0 = value } }
    func availableBytes(at url: URL) -> Int64 { bytes.withLock { $0 } }
}

final class FakeVideo: MeetingVideoRecording {
    let fail: Bool
    let log: CallLog
    init(fail: Bool = false, log: CallLog) {
        self.fail = fail
        self.log = log
    }
    func start(app: MeetingApp, to url: URL) async throws {
        await log.add("video.start")
        if fail { throw AppError.permissionDenied(.screenRecording) }
        FileManager.default.createFile(atPath: url.path, contents: Data([1, 2, 3]))
    }
    func stop() async throws { await log.add("video.stop") }
}

func segment(_ start: Double, _ end: Double, _ text: String) -> Segment {
    Segment(start: start, end: end, text: text, languageCode: .english)
}

/// Video recorder whose `start` suspends until released, like the first ScreenCaptureKit lookup and permission prompt.
actor GatedVideo: MeetingVideoRecording {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func start(app: MeetingApp, to url: URL) async throws {
        if !released { await withCheckedContinuation { continuation = $0 } }
        FileManager.default.createFile(atPath: url.path, contents: Data([1]))
    }
    func stop() async throws {}
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
