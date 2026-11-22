import AppCore
import Darwin
import Foundation

/// A recorder that can also persist bookmarks into the crash-safe manifest (MTG-AC-14).
public protocol BookmarkingRecorder: Recorder {
    func addBookmark(at time: TimeInterval, note: String) async
}

public struct MeetingRecorderConfig: Sendable {
    /// Media seconds written between flushes (and manifest refreshes). Bounds what a crash can lose.
    public var flushIntervalSeconds: TimeInterval
    /// Refuse to start with less free space than this.
    public var minimumFreeBytesToStart: Int64
    /// Halt (finalize files, keep what was captured) when free space drops below this.
    public var stopBelowFreeBytes: Int64
    /// How long `stop()` waits for source streams to drain before cancelling the consumers.
    public var drainGrace: TimeInterval
    /// Tracks starting at different host times are aligned by padding the later one with silence up to this much.
    public var maxStartAlignmentSeconds: TimeInterval

    public init(
        flushIntervalSeconds: TimeInterval = 2, minimumFreeBytesToStart: Int64 = 1_000_000_000,
        stopBelowFreeBytes: Int64 = 200_000_000, drainGrace: TimeInterval = 0.5, maxStartAlignmentSeconds: TimeInterval = 2
    ) {
        self.flushIntervalSeconds = flushIntervalSeconds
        self.minimumFreeBytesToStart = minimumFreeBytesToStart
        self.stopBelowFreeBytes = stopBelowFreeBytes
        self.drainGrace = drainGrace
        self.maxStartAlignmentSeconds = maxStartAlignmentSeconds
    }
}

/// Dual-track crash-safe recorder (MTG-AC-08, -12, -16).
///
/// The mic ("You") and the remote/app audio are written to separate CAF files as they arrive, flushed every
/// `flushIntervalSeconds` of media, and mixed into `mix.m4a` (AAC) when `stop()` runs. A manifest (`meeting.json`)
/// beside them carries the meeting identity so ``RecordingRecovery`` can finish an interrupted recording at the next
/// launch. A remote stream that never produces audio (permission denied or silently blocked) still yields a mic-only
/// recording. Stop the audio sources first so their streams end and the tail drains before `stop()`.
public actor MeetingRecorder: BookmarkingRecorder {
    private enum State { case idle, recording, halted, finished }

    public static let micFile = "mic.caf"
    public static let remoteFile = "remote.caf"
    public static let mixFile = "mix.m4a"
    public static let videoFile = "video.mov"

    private let session: RecordingSession
    private let diskSpace: any DiskSpaceProviding
    private let config: MeetingRecorderConfig
    private let video: (any MeetingVideoRecording)?
    private let broadcaster = Broadcaster<RecorderEvent>()
    private let log = AppLog.logger("meetings.recorder")

    private var state: State = .idle
    private var directory: URL?
    private var manifest: RecordingManifest?
    private var writers: [RecordingTrack.Role: CAFTrackWriter] = [:]
    private var firstChunk: [RecordingTrack.Role: (start: TimeInterval, host: UInt64)] = [:]
    private var consumers: [Task<Void, Never>] = []
    private var framesSinceFlush = 0
    private var result: Recording?
    private var videoRunning = false

    public init(
        session: RecordingSession, diskSpace: any DiskSpaceProviding = SystemDiskSpace(),
        config: MeetingRecorderConfig = MeetingRecorderConfig(), video: (any MeetingVideoRecording)? = nil
    ) {
        self.session = session
        self.diskSpace = diskSpace
        self.config = config
        self.video = video
    }

    public nonisolated func events() -> AsyncStream<RecorderEvent> { broadcaster.stream() }

    public var isRecording: Bool { state == .recording }
    public var meetingID: MeetingID { session.meetingID }

    // MARK: Recorder

    public func start(config recording: RecordingConfig, mic: AsyncStream<AudioChunk>, remote: AsyncStream<AudioChunk>) async throws {
        guard state == .idle else { throw RecorderError.alreadyRecording }
        let dir = recording.directory
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
            throw RecorderError.cannotCreateDirectory(error.localizedDescription)
        }
        let available = diskSpace.availableBytes(at: dir)
        guard available >= config.minimumFreeBytesToStart else {
            throw RecorderError.insufficientDiskSpace(availableBytes: available, requiredBytes: config.minimumFreeBytesToStart)
        }
        do {
            writers[.mic] = try CAFTrackWriter(url: dir.appendingPathComponent(Self.micFile))
            writers[.remote] = try CAFTrackWriter(url: dir.appendingPathComponent(Self.remoteFile))
        } catch {
            writers = [:]
            throw RecorderError.cannotWriteTrack(error.localizedDescription)
        }
        directory = dir
        var tracks = [
            RecordingTrack(role: .mic, relativePath: Self.micFile), RecordingTrack(role: .remote, relativePath: Self.remoteFile),
        ]
        var includesVideo = false
        if recording.includeVideo, let video {
            do {
                try await video.start(app: session.app, to: dir.appendingPathComponent(Self.videoFile))
                videoRunning = true
                includesVideo = true
                tracks.append(RecordingTrack(role: .video, relativePath: Self.videoFile))
            } catch {
                // Video (Screen Recording permission, no window) must never stop audio recording.
                log.error("video start failed: \(String(describing: error), privacy: .public)")
                broadcaster.send(.videoFailed(reason: String(describing: error)))
            }
        }
        let manifest = RecordingManifest(
            version: 1, meetingID: session.meetingID, app: session.app, startedAt: session.startedAt, state: .recording, tracks: tracks,
            includesVideo: includesVideo, wantsMix: recording.mixTrack, keepSeparateTracks: recording.separateTracks, duration: 0,
            bookmarks: [], haltedReason: nil, relativeDirectory: session.relativeDirectory)
        self.manifest = manifest
        try manifest.write(to: dir)
        state = .recording
        consumers = [
            Task { [weak self] in for await chunk in mic { await self?.ingest(.mic, chunk) } },
            Task { [weak self] in for await chunk in remote { await self?.ingest(.remote, chunk) } },
        ]
        broadcaster.send(.started(directory: dir))
    }

    public func stop() async throws -> Recording {
        if let result { return result }
        guard state == .recording || state == .halted, let directory, var manifest else { throw RecorderError.notRecording }
        await drainConsumers()
        for writer in writers.values { try? writer.close() }
        writers = [:]
        if videoRunning, let video {
            videoRunning = false
            do { try await video.stop() } catch { broadcaster.send(.videoFailed(reason: String(describing: error))) }
        }
        manifest.state = .stopped
        try? manifest.write(to: directory)
        let outcome = await Task.detached(priority: .utility) { RecordingFinisher.finish(directory: directory, manifest: manifest) }.value
        if let failure = outcome.mixError { broadcaster.send(.mixFailed(reason: failure)) }
        self.manifest = outcome.manifest
        state = .finished
        result = outcome.recording
        broadcaster.send(.stopped(outcome.recording))
        broadcaster.finish()
        return outcome.recording
    }

    public func addBookmark(at time: TimeInterval, note: String) async {
        guard var manifest, let directory, state == .recording || state == .halted else { return }
        manifest.bookmarks.append(RecordingManifest.Bookmark(time: time, note: note))
        self.manifest = manifest
        try? manifest.write(to: directory)
    }

    // MARK: Ingest

    private func ingest(_ role: RecordingTrack.Role, _ chunk: AudioChunk) {
        guard state == .recording, let writer = writers[role] else { return }
        do {
            var samples = chunk.samples
            let rate = AudioChunk.sampleRate
            if let first = firstChunk[role] {
                // Keep this track gap-free relative to its own capture timeline: silence for dropped audio, trim overlap.
                let expected = Int(((chunk.startSeconds - first.start) * rate).rounded())
                let tolerance = Int(0.1 * rate)
                let position = writer.framesWritten
                if expected > position + tolerance {
                    try writer.appendSilence(frames: expected - position)
                } else if position - expected > tolerance {
                    samples = Array(samples.dropFirst(min(samples.count, position - expected)))
                }
            } else {
                firstChunk[role] = (chunk.startSeconds, chunk.hostTime)
                if let pad = startOffsetFrames(for: role, host: chunk.hostTime), pad > 0 { try writer.appendSilence(frames: pad) }
            }
            try writer.append(samples)
            framesSinceFlush += samples.count
            if Double(framesSinceFlush) >= config.flushIntervalSeconds * rate { try flushAll() }
        } catch {
            log.error("track write failed: \(String(describing: error), privacy: .public)")
            halt(reason: "write failed: \(error.localizedDescription)", availableBytes: nil)
        }
    }

    /// Frames of leading silence for `role` when its first chunk started later (by host time) than the other track's.
    private func startOffsetFrames(for role: RecordingTrack.Role, host: UInt64) -> Int? {
        guard host != 0, let other = firstChunk.first(where: { $0.key != role })?.value, other.host != 0, host > other.host else {
            return nil
        }
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        guard info.denom != 0 else { return nil }
        let seconds = Double(host - other.host) * Double(info.numer) / Double(info.denom) / 1_000_000_000
        guard seconds <= config.maxStartAlignmentSeconds else { return nil }
        return Int((seconds * AudioChunk.sampleRate).rounded())
    }

    private func flushAll() throws {
        for writer in writers.values { try writer.flush() }
        framesSinceFlush = 0
        let seconds = Double(writers.values.map(\.framesWritten).max() ?? 0) / AudioChunk.sampleRate
        if var manifest, let directory {
            manifest.duration = seconds
            self.manifest = manifest
            try? manifest.write(to: directory)
        }
        broadcaster.send(.flushed(seconds: seconds))
        if let directory {
            let available = diskSpace.availableBytes(at: directory)
            if available < config.stopBelowFreeBytes { halt(reason: "low disk space", availableBytes: available) }
        }
    }

    /// Stops accepting audio but keeps the recording stoppable: files are flushed and closed cleanly.
    private func halt(reason: String, availableBytes: Int64?) {
        guard state == .recording else { return }
        state = .halted
        for writer in writers.values { try? writer.close() }
        writers = [:]
        if var manifest, let directory {
            manifest.haltedReason = reason
            self.manifest = manifest
            try? manifest.write(to: directory)
        }
        if let availableBytes {
            broadcaster.send(.stoppedLowDisk(availableBytes: availableBytes))
        } else {
            broadcaster.send(.writeFailed(reason: reason))
        }
        for task in consumers { task.cancel() }
    }

    private func drainConsumers() async {
        let tasks = consumers
        consumers = []
        let grace = config.drainGrace
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for task in tasks { await task.value } }
            group.addTask {
                try? await Task.sleep(for: .seconds(grace))
                for task in tasks { task.cancel() }
            }
            await group.next()
            group.cancelAll()
        }
        for task in tasks {
            task.cancel()
            await task.value
        }
    }
}

// MARK: - Finish and recovery

/// Turns a stopped or interrupted recording directory into a complete `Recording` (repair, mix, manifest update).
enum RecordingFinisher {
    struct Outcome {
        var recording: Recording
        var manifest: RecordingManifest
        var mixError: String?
    }

    static func finish(directory: URL, manifest input: RecordingManifest) -> Outcome {
        var manifest = input
        let fm = FileManager.default
        var kept: [RecordingTrack] = []
        var audioURLs: [URL] = []
        var longestFrames = 0
        for track in manifest.tracks {
            let url = directory.appendingPathComponent(track.relativePath)
            switch track.role {
            case .mic, .remote:
                guard fm.fileExists(atPath: url.path), let frames = try? CAFTrackRecovery.repair(url), frames > 0 else {
                    try? fm.removeItem(at: url)
                    continue
                }
                longestFrames = max(longestFrames, frames)
                kept.append(track)
                audioURLs.append(url)
            case .video:
                let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                if size > 0 { kept.append(track) }
            case .mix: break
            }
        }
        var mixError: String?
        if manifest.wantsMix, !audioURLs.isEmpty {
            let mixURL = directory.appendingPathComponent(MeetingRecorder.mixFile)
            do {
                try TrackMixer.mix(tracks: audioURLs, to: mixURL)
                kept.append(RecordingTrack(role: .mix, relativePath: MeetingRecorder.mixFile))
                if !manifest.keepSeparateTracks {
                    for url in audioURLs { try? fm.removeItem(at: url) }
                    kept.removeAll { $0.role == .mic || $0.role == .remote }
                }
            } catch {
                try? fm.removeItem(at: mixURL)
                mixError = String(describing: error)
            }
        }
        let duration = Double(longestFrames) / AudioChunk.sampleRate
        manifest.tracks = kept
        manifest.duration = duration
        // A failed mix leaves the manifest in `.stopped` so recovery retries it; otherwise the recording is complete.
        manifest.state = mixError == nil ? .finalized : .stopped
        try? manifest.write(to: directory)
        let prefix = manifest.relativeDirectory.map { $0.hasSuffix("/") ? $0 : $0 + "/" } ?? ""
        let published = kept.map { RecordingTrack(role: $0.role, relativePath: prefix + $0.relativePath) }
        return Outcome(recording: Recording(tracks: published, duration: duration), manifest: manifest, mixError: mixError)
    }
}

public struct RecoveredRecording: Sendable, Equatable {
    public var directory: URL
    public var meeting: Meeting
    public var manifest: RecordingManifest
}

/// Finishes recordings interrupted by a crash or `kill -9` (MTG-AC-12): repairs the track headers, mixes, and makes sure
/// a `Meeting` with the recording exists. Call at launch, then enqueue a finalization job per result.
public enum RecordingRecovery {
    /// Directories (direct children of `root`, or `root` itself) holding a manifest not yet `.finalized`.
    public static func interruptedDirectories(in root: URL) -> [URL] {
        let fm = FileManager.default
        var candidates = [root]
        candidates += (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?.filter { $0.hasDirectoryPath } ?? []
        return candidates.filter { dir in
            guard let manifest = try? RecordingManifest.read(from: dir) else { return false }
            return manifest.state != .finalized
        }
    }

    @discardableResult
    public static func recover(in root: URL, meetings: (any MeetingRepository)? = nil) async -> [RecoveredRecording] {
        var out: [RecoveredRecording] = []
        for dir in interruptedDirectories(in: root) {
            guard let manifest = try? RecordingManifest.read(from: dir) else { continue }
            let outcome = await Task.detached(priority: .utility) { RecordingFinisher.finish(directory: dir, manifest: manifest) }.value
            let existing = try? await meetings?.meetings().first { $0.id == manifest.meetingID }
            var meeting = existing ?? Meeting(id: manifest.meetingID, app: manifest.app, startedAt: manifest.startedAt)
            meeting.endedAt = meeting.endedAt ?? manifest.startedAt.addingTimeInterval(outcome.recording.duration)
            meeting.recording = outcome.recording
            try? await meetings?.save(meeting)
            out.append(RecoveredRecording(directory: dir, meeting: meeting, manifest: outcome.manifest))
        }
        return out
    }
}
