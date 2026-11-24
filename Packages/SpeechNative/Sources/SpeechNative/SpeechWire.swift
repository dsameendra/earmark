import Foundation

/// Versioned helper transport. These records describe native output, independently of app persistence contracts.
public enum SpeechWire {
    public static let version = 1
    public static let maximumMessageBytes = 4 * 1_024 * 1_024
    public static let maximumFrameSamples = 16_000
    public static let maximumRunSamples = 30 * 16_000
    public static let maximumSessionSamples = 6 * 60 * 60 * 16_000
    public static let maximumRows = 100_000

    public static func decodePCM(_ data: Data, maximumSamples: Int) throws -> [Float] {
        guard !data.isEmpty, data.count.isMultiple(of: 4), data.count / 4 <= maximumSamples else {
            throw SpeechWireError.invalid("Invalid PCM frame size.")
        }
        let samples = data.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: 4).map { offset in
                Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            }
        }
        guard samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else {
            throw SpeechWireError.invalid("PCM must contain finite samples in [-1, 1].")
        }
        return samples
    }
}

public enum SpeechWireError: Error, LocalizedError, Equatable, Sendable {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let reason): reason } }
}

public struct SpeechWorkerRequest: Codable, Sendable {
    public enum Operation: String, Codable, Sendable { case begin, feed, finish, reset, run }
    public var id: UInt64
    public var operation: Operation
    public var pcm: Data?
    public var language: String?
    public var targetLanguage: String?
    public var diarize: Bool?

    public init(id: UInt64, operation: Operation, pcm: Data? = nil, language: String? = nil, targetLanguage: String? = nil, diarize: Bool? = nil) {
        self.id = id; self.operation = operation; self.pcm = pcm
        self.language = language; self.targetLanguage = targetLanguage; self.diarize = diarize
    }
}

public struct SpeechWorkerReady: Codable, Sendable {
    public var architecture: String
    public var variant: String
    public var backend: String
    public var languages: [String]
    public var translationTargets: [String]
    public var canDetectLanguage: Bool
    public var canStream: Bool
    public var canTranslate: Bool
    public var canDiarize: Bool
    public var canStreamWithSpeakers: Bool
    public var nativeVersion: String
    public init(architecture: String, variant: String, backend: String, languages: [String], translationTargets: [String],
                canDetectLanguage: Bool, canStream: Bool, canTranslate: Bool, canDiarize: Bool, canStreamWithSpeakers: Bool, nativeVersion: String) {
        self.architecture = architecture; self.variant = variant; self.backend = backend; self.languages = languages
        self.translationTargets = translationTargets; self.canDetectLanguage = canDetectLanguage
        self.canStream = canStream; self.canTranslate = canTranslate; self.canDiarize = canDiarize; self.canStreamWithSpeakers = canStreamWithSpeakers; self.nativeVersion = nativeVersion
    }
}

public struct SpeechNativeSegment: Codable, Sendable {
    public var startMS: Int64
    public var endMS: Int64
    public var text: String
    public var speaker: Int32
    public var firstWord: Int32
    public var wordCount: Int32
    public init(startMS: Int64, endMS: Int64, text: String, speaker: Int32, firstWord: Int32, wordCount: Int32) {
        self.startMS = startMS; self.endMS = endMS; self.text = text; self.speaker = speaker
        self.firstWord = firstWord; self.wordCount = wordCount
    }
}

public struct SpeechNativeWord: Codable, Sendable {
    public var startMS: Int64
    public var endMS: Int64
    public var text: String
    public var segmentIndex: Int32
    public init(startMS: Int64, endMS: Int64, text: String, segmentIndex: Int32) {
        self.startMS = startMS; self.endMS = endMS; self.text = text; self.segmentIndex = segmentIndex
    }
}

public struct SpeechNativeSpeakerTurn: Codable, Sendable {
    public var startMS: Int64
    public var endMS: Int64
    public var speaker: Int32
    public init(startMS: Int64, endMS: Int64, speaker: Int32) {
        self.startMS = startMS; self.endMS = endMS; self.speaker = speaker
    }
}

public enum SpeechNativeTimestampKind: String, Codable, Sendable { case none, segment, word, token, unknown }

public struct SpeechNativeSnapshot: Codable, Sendable {
    public var timestampKind: SpeechNativeTimestampKind
    public var text: String
    public var committedText: String
    public var tentativeText: String
    public var language: String?
    public var revision: Int32
    public var isFinal: Bool
    public var inputReceivedMS: Int64
    public var audioCommittedMS: Int64
    public var bufferedMS: Int64
    public var committedSegments: Int
    public var committedWords: Int
    public var segments: [SpeechNativeSegment]
    public var words: [SpeechNativeWord]
    public var speakerTurns: [SpeechNativeSpeakerTurn]
    public init(timestampKind: SpeechNativeTimestampKind, text: String, committedText: String, tentativeText: String, language: String?, revision: Int32,
                isFinal: Bool, inputReceivedMS: Int64, audioCommittedMS: Int64, bufferedMS: Int64,
                committedSegments: Int, committedWords: Int, segments: [SpeechNativeSegment], words: [SpeechNativeWord],
                speakerTurns: [SpeechNativeSpeakerTurn]) {
        self.timestampKind = timestampKind
        self.text = text; self.committedText = committedText; self.tentativeText = tentativeText; self.language = language
        self.revision = revision; self.isFinal = isFinal; self.inputReceivedMS = inputReceivedMS
        self.audioCommittedMS = audioCommittedMS; self.bufferedMS = bufferedMS; self.committedSegments = committedSegments
        self.committedWords = committedWords; self.segments = segments; self.words = words; self.speakerTurns = speakerTurns
    }
}

public struct SpeechWorkerReply: Codable, Sendable {
    public var id: UInt64
    public var version = SpeechWire.version
    public var ready: SpeechWorkerReady?
    public var snapshot: SpeechNativeSnapshot?
    public var error: String?
    public init(id: UInt64, ready: SpeechWorkerReady? = nil, snapshot: SpeechNativeSnapshot? = nil, error: String? = nil) {
        self.id = id; self.ready = ready; self.snapshot = snapshot; self.error = error
    }
}
