import AVFoundation
import AppCore
import Foundation

// MARK: - Manifest

/// Written next to the tracks when recording starts and rewritten as it progresses. It makes an interrupted recording
/// recoverable: it carries the meeting identity that the `Recorder` protocol itself cannot.
public struct RecordingManifest: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        /// Tracks are being written (or the app died while they were).
        case recording
        /// Capture stopped; tracks are complete, mix may be pending.
        case stopped
        /// Mix done and the meeting finalized by the recorder (recovery has nothing to do).
        case finalized
    }
    public struct Bookmark: Codable, Sendable, Equatable {
        public var time: TimeInterval
        public var note: String
        public init(time: TimeInterval, note: String) {
            self.time = time
            self.note = note
        }
    }

    public static let fileName = "meeting.json"

    public var version: Int
    public var meetingID: MeetingID
    public var app: MeetingApp
    public var startedAt: Date
    public var state: State
    public var tracks: [RecordingTrack]
    public var includesVideo: Bool
    public var wantsMix: Bool
    public var keepSeparateTracks: Bool
    public var duration: TimeInterval
    public var bookmarks: [Bookmark]
    public var haltedReason: String?
    /// Folder of this recording relative to the library root (prefixed onto `Recording` track paths), if known.
    public var relativeDirectory: String?

    public func write(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }

    public static func read(from directory: URL) throws -> RecordingManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Self.self, from: Data(contentsOf: directory.appendingPathComponent(fileName)))
    }
}

/// Identity of the meeting being recorded (passed to the recorder because `Recorder.start` carries none).
public struct RecordingSession: Sendable, Equatable {
    public var meetingID: MeetingID
    public var app: MeetingApp
    public var startedAt: Date
    /// Folder of the recording relative to the library root (e.g. `Meetings/2026-11-22 Zoom`); prefixed onto the
    /// `Recording` track paths so they resolve from the library root. `nil` keeps paths relative to the recording folder.
    public var relativeDirectory: String?
    public init(meetingID: MeetingID = MeetingID(), app: MeetingApp, startedAt: Date = Date(), relativeDirectory: String? = nil) {
        self.meetingID = meetingID
        self.app = app
        self.startedAt = startedAt
        self.relativeDirectory = relativeDirectory
    }
}

// MARK: - Errors and events

public enum RecorderError: Error, Equatable, Sendable {
    case alreadyRecording
    case notRecording
    case insufficientDiskSpace(availableBytes: Int64, requiredBytes: Int64)
    case cannotCreateDirectory(String)
    case cannotWriteTrack(String)
}

public enum RecorderEvent: Sendable, Equatable {
    case started(directory: URL)
    /// Tracks were flushed to disk (media seconds written on the longest track).
    case flushed(seconds: TimeInterval)
    /// Free space fell below the stop threshold: capture halted, files are finalized, call `stop()` to get the result.
    case stoppedLowDisk(availableBytes: Int64)
    case videoFailed(reason: String)
    /// A track write failed (disk error); capture halted, call `stop()` to keep what was written.
    case writeFailed(reason: String)
    case mixFailed(reason: String)
    case stopped(Recording)
}

// MARK: - Disk space

public protocol DiskSpaceProviding: Sendable {
    /// Bytes available for writing at `url` (nearest existing ancestor is queried).
    func availableBytes(at url: URL) -> Int64
}

public struct SystemDiskSpace: DiskSpaceProviding {
    public init() {}
    public func availableBytes(at url: URL) -> Int64 {
        var target = url
        while !FileManager.default.fileExists(atPath: target.path), target.pathComponents.count > 1 {
            target.deleteLastPathComponent()
        }
        let values = try? target.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage { return important }
        return Int64(values?.volumeAvailableCapacity ?? 0)
    }
}

// MARK: - Video seam

/// Records the meeting window to a movie file. The ScreenCaptureKit implementation is opt-in; tests use a fake.
public protocol MeetingVideoRecording: Sendable {
    /// Starts writing a movie to `url` for the app's meeting window. Throws (e.g. permission denied) without
    /// affecting audio recording.
    func start(app: MeetingApp, to url: URL) async throws
    func stop() async throws
}

// MARK: - Mix

/// Mixes the mic and remote tracks (sample-aligned, summed with clipping) into one AAC `.m4a`.
enum TrackMixer {
    static func mix(tracks: [URL], to output: URL) throws {
        let readers = try tracks.map { try CAFTrackReader(url: $0) }
        defer { readers.forEach { $0.close() } }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: CAFLayout.sampleRate, AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000,
        ]
        try? FileManager.default.removeItem(at: output)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: CAFLayout.sampleRate, channels: 1, interleaved: false)
        else { throw RecorderError.cannotWriteTrack("mix format") }
        var file: AVAudioFile? = try AVAudioFile(
            forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let block = 16_384
        while readers.contains(where: { $0.framesRemaining > 0 }) {
            var mixed = [Float](repeating: 0, count: block)
            var longest = 0
            for reader in readers {
                let samples = try reader.read(maxFrames: block)
                longest = max(longest, samples.count)
                for i in samples.indices { mixed[i] += samples[i] }
            }
            guard longest > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(longest)) else { break }
            buffer.frameLength = AVAudioFrameCount(longest)
            let channel = buffer.floatChannelData![0]
            for i in 0..<longest { channel[i] = max(-1, min(1, mixed[i])) }
            try file?.write(from: buffer)
        }
        file = nil  // releases the AVAudioFile, which finalizes the m4a
    }
}
