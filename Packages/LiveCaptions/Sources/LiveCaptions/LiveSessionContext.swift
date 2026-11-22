import AppCore
import DesignSystem
import Foundation
import Synchronization

/// Media-time high-water mark written by capture pumps (off the actor) and read by the orchestrator.
final class SessionClock: Sendable {
    private let value = Mutex<TimeInterval>(0)
    func advance(to t: TimeInterval) { value.withLock { $0 = max($0, t) } }
    var now: TimeInterval { value.withLock { $0 } }
}

/// Mutable per-session state. Confined to the `LiveSessionOrchestrator` actor (never escapes it).
final class SessionContext {
    enum Phase { case starting, running, stopping, finished }

    let config: LiveSessionConfig
    let clock = SessionClock()
    var phase: Phase = .starting
    var cancelRequested = false

    var lanes: [LiveAudioLane] = []
    var store: CaptionLineStore
    var timeline = LiveSpeakerTimeline()
    var diarizedLanes: Set<Int> = []
    var postContext = PostProcessingContext()
    var detectedLanguage: LanguageCode?
    var sourcesStopped = false

    // Persistence
    var transcriptID: TranscriptID?
    var transcriptTitle = ""
    var createdAt = Date()
    var finals: [Segment] = []
    var finalIndex: [SegmentID: Int] = [:]
    var dirty: Set<SegmentID> = []
    var speakers: [Int: Speaker] = [:]

    // Tasks
    var pumpTasks: [Task<Void, Never>] = []
    var engineTasks: [Task<Void, Never>] = []
    var auxTasks: [Task<Void, Never>] = []  // diarization, health, translation worker
    var checkpointTask: Task<Void, Never>?
    var activeEngineLanes = 0

    // Translation
    struct TranslationJob {
        var lineID: UUID
        var segmentID: SegmentID?
        var text: String
        var language: LanguageCode?
    }
    var pendingFinalTranslations: [TranslationJob] = []
    var volatileTranslation: TranslationJob?
    var translationWake: AsyncStream<Void>.Continuation?
    var lastTranslationAt: ContinuousClock.Instant?

    init(config: LiveSessionConfig, maxRetainedLines: Int) {
        self.config = config
        store = CaptionLineStore(maxRetained: maxRetainedLines)
    }

    /// Single configured language when the mode is fixed.
    var fixedLanguage: LanguageCode? {
        if case .single(let l) = config.languageMode { return l }
        return nil
    }

    func laneLabel(_ lane: Int) -> String? { lanes.indices.contains(lane) ? lanes[lane].label : nil }

    /// Persisted speaker for a live display index (created lazily; stable ids for the session).
    func speaker(forIndex index: Int) -> Speaker {
        if let s = speakers[index] { return s }
        let s = Speaker(name: LiveSpeakerTimeline.name(forIndex: index), colorHex: Self.hex(forSlot: index))
        speakers[index] = s
        return s
    }

    static func hex(forSlot slot: Int) -> String {
        let c = SpeakerPalette.entry(forSlot: slot).light
        func b(_ v: Double) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", b(c.r), b(c.g), b(c.b))
    }

    func record(_ segment: Segment) {
        if let i = finalIndex[segment.id] {
            finals[i] = segment
        } else {
            finalIndex[segment.id] = finals.count
            finals.append(segment)
        }
        dirty.insert(segment.id)
    }

    func mutateFinal(_ id: SegmentID, _ body: (inout Segment) -> Void) {
        guard let i = finalIndex[id] else { return }
        body(&finals[i])
        dirty.insert(id)
    }
}
