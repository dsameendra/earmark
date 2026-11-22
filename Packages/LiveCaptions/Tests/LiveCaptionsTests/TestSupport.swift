import AppCore
import AppCoreTesting
import Foundation
import Synchronization

@testable import LiveCaptions

// MARK: - Waiting / recording

func waitUntil(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

@MainActor
func waitUntilMain(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

final class Box<T: Sendable>: Sendable {
    let items = Mutex<[T]>([])
    var all: [T] { items.withLock { $0 } }
    var last: T? { items.withLock { $0.last } }
}

/// Records everything a stream emits until cancelled.
final class Recorder<T: Sendable>: Sendable {
    let box = Box<T>()
    let task: Task<Void, Never>
    init(_ stream: AsyncStream<T>) {
        let box = box
        task = Task {
            for await item in stream { box.items.withLock { $0.append(item) } }
        }
    }
    var all: [T] { box.all }
    var last: T? { box.last }
    func cancel() { task.cancel() }
}

func chunk(_ t: TimeInterval, source: AudioSourceTag = .mic(deviceUID: nil)) -> AudioChunk {
    AudioChunk(samples: [Float](repeating: 0.1, count: 1_600), startSeconds: t, source: source)
}

func segment(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> Segment {
    Segment(start: start, end: end, text: text)
}

// MARK: - Audio

final class ManualAudioSource: AudioSource {
    let tag: AudioSourceTag
    private let continuation = Mutex<AsyncStream<AudioChunk>.Continuation?>(nil)
    private let counts = Mutex<(start: Int, stop: Int)>((0, 0))
    let healthStream: AsyncStream<AudioSourceHealth>
    private let healthContinuation: AsyncStream<AudioSourceHealth>.Continuation

    init(tag: AudioSourceTag = .mic(deviceUID: nil)) {
        self.tag = tag
        (healthStream, healthContinuation) = AsyncStream.makeStream(of: AudioSourceHealth.self)
    }
    var startCount: Int { counts.withLock { $0.start } }
    var stopCount: Int { counts.withLock { $0.stop } }

    func start() async throws -> AsyncStream<AudioChunk> {
        let (stream, c) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .bufferingNewest(64))
        continuation.withLock { $0 = c }
        counts.withLock { $0.start += 1 }
        return stream
    }
    func stop() async {
        counts.withLock { $0.stop += 1 }
        continuation.withLock { $0?.finish() }
        healthContinuation.finish()
    }
    var levels: AsyncStream<Float> { AsyncStream { $0.finish() } }
    var health: AsyncStream<AudioSourceHealth> { healthStream }

    func send(_ chunk: AudioChunk) { continuation.withLock { _ = $0?.yield(chunk) } }
    func report(_ h: AudioSourceHealth) { healthContinuation.yield(h) }
}

struct StubAudio: LiveAudioProviding {
    var lanes: [LiveAudioLane]
    var delay: Duration = .zero
    var failure: AppError?
    func lanes(for source: CaptureSource) async throws -> [LiveAudioLane] {
        if delay > .zero { try? await Task.sleep(for: delay) }
        if let failure { throw failure }
        return lanes
    }
}

// MARK: - Engines

enum Step: Sendable {
    case events([TranscriptionEvent])
    case fail(AppError)
}

/// Emits `script[i]` when the i-th audio chunk arrives; finishes when the audio stream ends.
final class ScriptedEngine: TranscriptionEngine {
    let id: EngineID = "scripted"
    let script: [Step]
    final class Counter: Sendable { let value = Mutex(0) }
    let received = Counter()
    let options = Mutex<TranscriptionOptions?>(nil)
    init(_ script: [Step]) { self.script = script }
    var receivedCount: Int { received.value.withLock { $0 } }

    func supportedLanguages(model: ModelID?) async -> Set<LanguageCode> { [.english] }
    func prepare(model: ModelID) async throws {}
    func unload() async {}
    func transcribe(file: URL, options: TranscriptionOptions) -> AsyncThrowingStream<TranscriptionEvent, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func stream(audio: AsyncStream<AudioChunk>, options: TranscriptionOptions) -> AsyncThrowingStream<TranscriptionEvent, any Error> {
        self.options.withLock { $0 = options }
        let script = script
        let received = received
        return AsyncThrowingStream { c in
            let task = Task {
                var i = 0
                for await _ in audio {
                    received.value.withLock { $0 += 1 }
                    if i < script.count {
                        switch script[i] {
                        case .events(let events): for e in events { c.yield(e) }
                        case .fail(let error):
                            c.finish(throwing: error)
                            return
                        }
                    }
                    i += 1
                }
                c.finish()
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
}

final class StubEngines: LiveEngineProviding {
    let queue: Mutex<[ScriptedEngine]>
    init(_ engines: [ScriptedEngine]) { queue = Mutex(engines) }
    func resolve(languageMode: LanguageMode) async throws -> LiveEngineSelection {
        let engine = queue.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }
        return LiveEngineSelection(engine: engine, model: ModelID("test/model"))
    }
}

final class ScriptedDiarizer: StreamingDiarizer {
    let id: EngineID = "scripted.diarizer"
    let events: [LiveDiarizationEvent]
    init(_ events: [LiveDiarizationEvent]) { self.events = events }
    func stream(audio: AsyncStream<AudioChunk>, options: DiarizationOptions) -> AsyncThrowingStream<LiveDiarizationEvent, any Error> {
        let events = events
        return AsyncThrowingStream { c in
            for e in events { c.yield(e) }
            let task = Task {
                for await _ in audio {}
                c.finish()
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
}

/// Ignores `[BLANK_AUDIO]` (flagged, never deleted) and applies one replacement.
struct StubPostProcessor: TranscriptPostProcessor {
    func process(_ segments: [Segment], context: PostProcessingContext) async -> [Segment] {
        segments.map { s in
            var s = s
            if s.text == "[BLANK_AUDIO]" { s.isIgnored = true }
            s.text = s.text.replacingOccurrences(of: "teh", with: "the")
            return s
        }
    }
}

// MARK: - Repositories

final class InMemoryTranscriptRepository: TranscriptRepository {
    private struct State {
        var transcripts: [TranscriptID: Transcript] = [:]
        var segments: [TranscriptID: [SegmentID: Segment]] = [:]
        var order: [TranscriptID: [SegmentID]] = [:]
        var failUpserts = false
        var upsertCalls = 0
    }
    private let state = Mutex(State())

    var failUpserts: Bool {
        get { state.withLock { $0.failUpserts } }
        set { state.withLock { $0.failUpserts = newValue } }
    }
    var upsertCalls: Int { state.withLock { $0.upsertCalls } }
    var allTranscripts: [Transcript] { state.withLock { Array($0.transcripts.values) } }
    func stored(_ id: TranscriptID) -> [Segment] {
        state.withLock { s in (s.order[id] ?? []).compactMap { s.segments[id]?[$0] } }
    }

    func list(_ query: LibraryQuery) async throws -> [Transcript] { allTranscripts }
    func transcript(_ id: TranscriptID) async throws -> Transcript? { state.withLock { $0.transcripts[id] } }
    func save(_ transcript: Transcript) async throws { state.withLock { $0.transcripts[transcript.id] = transcript } }
    func segments(for id: TranscriptID) async throws -> [Segment] { stored(id) }
    func upsertSegments(_ segments: [Segment], for id: TranscriptID) async throws {
        try state.withLock { s in
            s.upsertCalls += 1
            if s.failUpserts { throw AppError.persistence(reason: "disk full") }
            for seg in segments {
                if s.segments[id]?[seg.id] == nil { s.order[id, default: []].append(seg.id) }
                s.segments[id, default: [:]][seg.id] = seg
            }
        }
    }
    func replaceSegments(_ segments: [Segment], for id: TranscriptID) async throws {}
    func search(_ text: String, limit: Int) async throws -> [SearchHit] { [] }
    func softDelete(_ ids: [TranscriptID], at date: Date) async throws {}
    func restore(_ ids: [TranscriptID]) async throws {}
    func purge(_ ids: [TranscriptID]) async throws {}
    func purgeDeleted(before date: Date) async throws -> Int { 0 }
    func bookmarks(for id: TranscriptID) async throws -> [TranscriptBookmark] { [] }
    func save(_ bookmark: TranscriptBookmark) async throws {}
}

final class InMemorySettings: SettingsStore {
    private let values = Mutex<[String: Data]>([:])
    func value<T: Codable & Sendable>(for key: String, as: T.Type) async -> T? {
        guard let data = values.withLock({ $0[key] }) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    func set<T: Codable & Sendable>(_ value: T, for key: String) async {
        if let data = try? JSONEncoder().encode(value) { values.withLock { $0[key] = data } }
    }
    func changes(for key: String) -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

final class InMemoryPresets: PresetRepository {
    private let presets = Mutex<[CaptionPreset]>([])
    func captionPresets() async throws -> [CaptionPreset] { presets.withLock { $0 } }
    func save(_ preset: CaptionPreset) async throws {
        presets.withLock { list in
            if let i = list.firstIndex(where: { $0.id == preset.id }) { list[i] = preset } else { list.append(preset) }
        }
    }
    func exportPresets() async throws -> [ExportPreset] { [] }
    func save(_ preset: ExportPreset) async throws {}
    func softDeletePreset(_ id: PresetID) async throws {
        presets.withLock { list in
            if let i = list.firstIndex(where: { $0.id == id }) { list[i].deletedAt = Date() }
        }
    }
}

// MARK: - Rig

struct Rig {
    let orchestrator: LiveSessionOrchestrator
    let repo: InMemoryTranscriptRepository
    let source: ManualAudioSource
    let engine: ScriptedEngine
}

func testOptions(
    checkpoint: Duration = .milliseconds(40), translation: Duration = .milliseconds(120)
) -> LiveSessionOptions {
    LiveSessionOptions(checkpointInterval: checkpoint, drainTimeout: .seconds(1), translationMinInterval: translation)
}

func makeRig(
    script: [Step], diarizer: (any StreamingDiarizer)? = nil, translation: (any TranslationRouter)? = nil,
    lanes: [LiveAudioLane]? = nil, repo: InMemoryTranscriptRepository = InMemoryTranscriptRepository(),
    options: LiveSessionOptions = testOptions()
) -> Rig {
    let source = ManualAudioSource()
    let engine = ScriptedEngine(script)
    let orchestrator = LiveSessionOrchestrator(
        audio: StubAudio(lanes: lanes ?? [LiveAudioLane(source: source)]), engines: StubEngines([engine]), transcripts: repo,
        postProcessor: StubPostProcessor(), diarizer: diarizer, translation: translation, options: options)
    return Rig(orchestrator: orchestrator, repo: repo, source: source, engine: engine)
}
