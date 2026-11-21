import Foundation

// MARK: - Diarization

/// Maximum speakers tracked by live diarization (LS-EEND / Sortformer limit). Beyond this the UI shows "More speakers".
public let maxLiveSpeakers = 4

/// A speaker turn. `slot` is an engine-local index; it is mapped to a `SpeakerID` after reconciliation.
public struct SpeakerTurn: Hashable, Codable, Sendable {
    public var range: TimeRange
    public var slot: Int
    public var isProvisional: Bool
    public init(range: TimeRange, slot: Int, isProvisional: Bool = false) {
        self.range = range
        self.slot = slot
        self.isProvisional = isProvisional
    }
}

public struct DiarizationOptions: Sendable, Hashable {
    public enum Count: Sendable, Hashable {
        case auto
        case exact(Int)
        case range(min: Int, max: Int)
    }
    public var speakerCount: Count
    public init(speakerCount: Count = .auto) { self.speakerCount = speakerCount }
}

public enum LiveDiarizationEvent: Sendable {
    /// A turn that may still be revised (tentative ≈0.4 s, settled ≈1 s).
    case turn(SpeakerTurn)
    /// All turns before this media time are final for this live pass (still reconcilable offline).
    case finalized(upTo: TimeInterval)
    /// More than `maxLiveSpeakers` detected; extra speakers are not labelled until the offline pass.
    case speakerLimitReached
}

public protocol Diarizer: Sendable {
    var id: EngineID { get }
    func diarize(file: URL, options: DiarizationOptions) async throws -> [SpeakerTurn]
    /// Offline pass over already-decoded audio (e.g. the remote track of a meeting).
    func diarize(audio: AsyncThrowingStream<AudioChunk, any Error>, options: DiarizationOptions) async throws -> [SpeakerTurn]
}

public protocol StreamingDiarizer: Sendable {
    var id: EngineID { get }
    func stream(audio: AsyncStream<AudioChunk>, options: DiarizationOptions) -> AsyncThrowingStream<LiveDiarizationEvent, any Error>
}

public struct SpeakerEmbedding: Hashable, Codable, Sendable {
    public var vector: [Float]
    public init(vector: [Float]) { self.vector = vector }
    /// Cosine distance in 0...2 (0 identical).
    public func distance(to other: SpeakerEmbedding) -> Double {
        guard vector.count == other.vector.count, !vector.isEmpty else { return 2 }
        var dot: Float = 0
        var na: Float = 0
        var nb: Float = 0
        for i in vector.indices {
            dot += vector[i] * other.vector[i]
            na += vector[i] * vector[i]
            nb += other.vector[i] * other.vector[i]
        }
        guard na > 0, nb > 0 else { return 2 }
        return Double(1 - dot / (na.squareRoot() * nb.squareRoot()))
    }
}

public protocol SpeakerEmbeddingProvider: Sendable {
    func embedding(file: URL, range: TimeRange) async throws -> SpeakerEmbedding
}

/// A locally stored voice profile (embedding + name). Deletable; never leaves the device.
public struct VoiceProfile: Hashable, Codable, Sendable, Identifiable {
    public var id: VoiceProfileID
    public var name: String
    public var embedding: SpeakerEmbedding
    public var createdAt: Date
    public var deletedAt: Date?
    public init(
        id: VoiceProfileID = VoiceProfileID(), name: String, embedding: SpeakerEmbedding, createdAt: Date = Date(), deletedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.embedding = embedding
        self.createdAt = createdAt
        self.deletedAt = deletedAt
    }
}

/// Reconciles provisional live slots with the final offline pass (spike §11.5): each live slot maps to the offline
/// slot it overlaps most in time. Pure and unit-tested; the live→offline relabel is expected to change ≈17–29 % of audio.
public enum SpeakerReconciler {
    public static func mapLiveSlots(live: [SpeakerTurn], offline: [SpeakerTurn]) -> [Int: Int] {
        var overlap: [Int: [Int: TimeInterval]] = [:]  // liveSlot -> offlineSlot -> seconds
        for l in live {
            for o in offline {
                let t = l.range.overlap(with: o.range)
                if t > 0 { overlap[l.slot, default: [:]][o.slot, default: 0] += t }
            }
        }
        var result: [Int: Int] = [:]
        for (liveSlot, row) in overlap {
            if let best = row.max(by: { $0.value < $1.value })?.key { result[liveSlot] = best }
        }
        return result
    }
}

// MARK: - Translation

public struct LanguagePair: Hashable, Codable, Sendable {
    public var source: LanguageCode
    public var target: LanguageCode
    public init(source: LanguageCode, target: LanguageCode) {
        self.source = source
        self.target = target
    }
}

public struct TranslationItem: Sendable, Hashable {
    public var segmentID: SegmentID
    public var text: String
    public init(segmentID: SegmentID, text: String) {
        self.segmentID = segmentID
        self.text = text
    }
}

public struct TranslatedSegment: Sendable, Hashable {
    public var segmentID: SegmentID
    public var text: String
    public var engine: EngineID
    /// Engines flag weak directions (e.g. English → Sinhala) so the UI can label them low-confidence.
    public var isLowConfidence: Bool
    public init(segmentID: SegmentID, text: String, engine: EngineID, isLowConfidence: Bool = false) {
        self.segmentID = segmentID
        self.text = text
        self.engine = engine
        self.isLowConfidence = isLowConfidence
    }
}

public protocol TranslationEngine: Sendable {
    var id: EngineID { get }
    func supportedPairs() async -> Set<LanguagePair>
    func translate(items: [TranslationItem], from: LanguageCode, to: LanguageCode) -> AsyncThrowingStream<TranslatedSegment, any Error>
}

public protocol TranslationRouter: Sendable {
    /// Chooses an engine for the pair (Apple Translation first; NLLB for Sinhala in this non-commercial build).
    func engine(for pair: LanguagePair) async throws -> any TranslationEngine
}
