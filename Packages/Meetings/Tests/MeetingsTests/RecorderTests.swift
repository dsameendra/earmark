import AVFoundation
import AppCore
import Foundation
import Testing

@testable import Meetings

private func recorder(
    disk: FakeDisk = FakeDisk(), video: (any MeetingVideoRecording)? = nil, flush: TimeInterval = 1, session: RecordingSession? = nil
) -> MeetingRecorder {
    MeetingRecorder(
        session: session ?? RecordingSession(app: .zoom, startedAt: Date(timeIntervalSince1970: 1_700_000_000)), diskSpace: disk,
        config: MeetingRecorderConfig(flushIntervalSeconds: flush, minimumFreeBytesToStart: 1000, stopBelowFreeBytes: 500, drainGrace: 1),
        video: video)
}

private func frames(_ url: URL) throws -> Int { Int(try AVAudioFile(forReading: url).length) }

@Suite("CAF track", .timeLimit(.minutes(1)))
struct CAFTrackTests {
    @Test("a track that was never closed (kill -9) is readable and recoverable")
    func openFileIsReadable() throws {
        let dir = tempDirectory()
        let url = dir.appendingPathComponent("t.caf")
        let writer = try CAFTrackWriter(url: url)
        try writer.append(tone(seconds: 1).samples)
        try writer.flush()
        // No close(): the data chunk size is still -1 ("until EOF").
        #expect(try frames(url) == 16_000)
        #expect(try CAFTrackRecovery.frameCount(url) == 16_000)
        try writer.append(tone(seconds: 0.5).samples)
        try writer.flush()
        #expect(try frames(url) == 24_000)
        try writer.close()
        #expect(try frames(url) == 24_000)
    }

    @Test("recovery drops a torn trailing sample and patches the size")
    func repairTornTail() throws {
        let dir = tempDirectory()
        let url = dir.appendingPathComponent("t.caf")
        let writer = try CAFTrackWriter(url: url)
        try writer.append(tone(seconds: 0.25).samples)
        try writer.flush()
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x7F]))  // half a sample
        try handle.close()
        #expect(try CAFTrackRecovery.repair(url) == 4_000)
        #expect(try frames(url) == 4_000)
    }

    @Test("samples round-trip through int16 within quantisation error")
    func roundTrip() throws {
        let dir = tempDirectory()
        let url = dir.appendingPathComponent("t.caf")
        let input = tone(seconds: 0.1, amplitude: 0.5).samples
        let writer = try CAFTrackWriter(url: url)
        try writer.append(input)
        try writer.close()
        let reader = try CAFTrackReader(url: url)
        let out = try reader.read(maxFrames: 10_000)
        #expect(out.count == input.count)
        #expect(zip(out, input).allSatisfy { abs($0 - $1) < 0.001 })
    }

    @Test("non CAF files are rejected")
    func rejectsGarbage() throws {
        let url = tempDirectory().appendingPathComponent("x.caf")
        try Data(repeating: 0, count: 200).write(to: url)
        #expect(throws: CAFTrackError.self) { try CAFTrackRecovery.repair(url) }
    }
}

@Suite("Meeting recorder", .timeLimit(.minutes(1)))
struct RecorderTests {
    // MTG-AC-08
    @Test("records mic and remote separately and mixes to m4a")
    func dualTrackAndMix() async throws {
        let dir = tempDirectory()
        let rec = recorder(session: RecordingSession(app: .zoom, relativeDirectory: "Meetings/Test"))
        try await rec.start(
            config: RecordingConfig(directory: dir), mic: stream([tone(seconds: 2)]),
            remote: stream([tone(seconds: 3, hz: 220, source: .app(bundleID: "us.zoom.xos"))]))
        let recording = try await rec.stop()
        #expect(Set(recording.tracks.map(\.role)) == [.mic, .remote, .mix])
        #expect(recording.tracks.first { $0.role == .mix }?.relativePath == "Meetings/Test/mix.m4a")
        #expect(abs(recording.duration - 3) < 0.01)
        #expect(try frames(dir.appendingPathComponent("mic.caf")) == 32_000)
        #expect(try frames(dir.appendingPathComponent("remote.caf")) == 48_000)
        let mix = try AVAudioFile(forReading: dir.appendingPathComponent("mix.m4a"))
        #expect(abs(Double(mix.length) / mix.fileFormat.sampleRate - 3) < 0.2)
        #expect(await rec.isRecording == false)
        let manifest = try RecordingManifest.read(from: dir)
        #expect(manifest.state == .finalized)
        #expect(manifest.app == .zoom)
    }

    @Test("separateTracks off keeps only the mix")
    func mixOnly() async throws {
        let dir = tempDirectory()
        let rec = recorder()
        try await rec.start(
            config: RecordingConfig(directory: dir, separateTracks: false), mic: stream([tone(seconds: 1)]),
            remote: stream([tone(seconds: 1)]))
        let recording = try await rec.stop()
        #expect(recording.tracks.map(\.role) == [.mix])
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.caf").path))
    }

    // MTG-AC-16
    @Test("a silent or missing remote stream still gives a mic-only recording")
    func micOnly() async throws {
        let dir = tempDirectory()
        let rec = recorder()
        try await rec.start(config: RecordingConfig(directory: dir), mic: stream([tone(seconds: 1)]), remote: stream([]))
        let recording = try await rec.stop()
        #expect(Set(recording.tracks.map(\.role)) == [.mic, .mix])
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("remote.caf").path))
        #expect(abs(recording.duration - 1) < 0.01)
    }

    @Test("dropped audio becomes silence so the track stays on the timeline; overlap is trimmed")
    func gapsAndOverlap() async throws {
        let dir = tempDirectory()
        let rec = recorder()
        let chunks = [
            tone(seconds: 0.5, start: 0),
            tone(seconds: 0.5, start: 1.5),  // 1 s gap
            tone(seconds: 1.0, start: 2.0),  // starts at 2.0 == current end: contiguous
            tone(seconds: 1.0, start: 2.5),  // overlaps by 0.5 s
        ]
        try await rec.start(config: RecordingConfig(directory: dir, mixTrack: false), mic: stream(chunks), remote: stream([]))
        _ = try await rec.stop()
        #expect(try frames(dir.appendingPathComponent("mic.caf")) == 56_000)  // 3.5 s
        let reader = try CAFTrackReader(url: dir.appendingPathComponent("mic.caf"))
        _ = try reader.read(maxFrames: 8_000)
        let gap = try reader.read(maxFrames: 16_000)
        #expect(gap.allSatisfy { $0 == 0 })
    }

    // MTG-AC-12
    @Test("flushes regularly so a crash (no stop) leaves playable audio, then recovery finishes it")
    func crashAndRecover() async throws {
        let root = tempDirectory("root")
        let dir = root.appendingPathComponent("2026-11-22 Zoom", isDirectory: true)
        let id = MeetingID()
        let session = RecordingSession(
            meetingID: id, app: .zoom, startedAt: Date(timeIntervalSince1970: 1_700_000_000), relativeDirectory: "2026-11-22 Zoom")
        let rec = recorder(flush: 1, session: session)
        let events = Collector(rec.events())
        var mic: AsyncStream<AudioChunk>.Continuation!
        var remote: AsyncStream<AudioChunk>.Continuation!
        let micStream = AsyncStream<AudioChunk> { mic = $0 }
        let remoteStream = AsyncStream<AudioChunk> { remote = $0 }
        try await rec.start(config: RecordingConfig(directory: dir), mic: micStream, remote: remoteStream)
        mic.yield(tone(seconds: 2))
        remote.yield(tone(seconds: 2, hz: 300))
        await events.waitFor(count: 3)  // started + flushed (x2 tracks)
        // -- process "dies" here: no stop(), files left open, manifest says recording --
        #expect(try frames(dir.appendingPathComponent("mic.caf")) == 32_000)
        let crashed = try RecordingManifest.read(from: dir)
        #expect(crashed.state == .recording)
        #expect(crashed.duration >= 1)
        #expect(
            RecordingRecovery.interruptedDirectories(in: root).map { $0.resolvingSymlinksInPath().path } == [
                dir.resolvingSymlinksInPath().path
            ])

        let repo = InMemoryMeetings()
        let recovered = await RecordingRecovery.recover(in: root, meetings: repo)
        mic.finish()
        remote.finish()
        #expect(recovered.count == 1)
        let item = try #require(recovered.first)
        #expect(item.meeting.id == id)
        #expect(item.meeting.recording?.tracks.map(\.role).contains(.mix) == true)
        #expect(item.meeting.recording?.tracks.first?.relativePath.hasPrefix("2026-11-22 Zoom/") == true)
        #expect(abs((item.meeting.recording?.duration ?? 0) - 2) < 0.01)
        #expect(await repo.saved.count == 1)
        #expect(try frames(dir.appendingPathComponent("mix.m4a")) > 30_000)
        // Second launch: nothing left to recover.
        #expect(RecordingRecovery.interruptedDirectories(in: root).isEmpty)
    }

    @Test("recovery keeps an existing meeting record and ignores finalized recordings")
    func recoveryExistingMeeting() async throws {
        let root = tempDirectory("root")
        let dir = root.appendingPathComponent("m1")
        let id = MeetingID()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let writer = try {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return try CAFTrackWriter(url: dir.appendingPathComponent("mic.caf"))
        }()
        try writer.append(tone(seconds: 1).samples)
        try writer.flush()
        try RecordingManifest(
            version: 1, meetingID: id, app: .teams, startedAt: start, state: .recording,
            tracks: [RecordingTrack(role: .mic, relativePath: "mic.caf"), RecordingTrack(role: .remote, relativePath: "remote.caf")],
            includesVideo: false, wantsMix: true, keepSeparateTracks: true, duration: 0, bookmarks: [], haltedReason: nil,
            relativeDirectory: nil
        ).write(to: dir)
        let repo = InMemoryMeetings()
        try await repo.save(Meeting(id: id, app: .teams, startedAt: start, transcriptID: TranscriptID()))
        let recovered = await RecordingRecovery.recover(in: root, meetings: repo)
        #expect(recovered.first?.meeting.transcriptID != nil)  // existing record preserved
        #expect(recovered.first?.meeting.endedAt == start.addingTimeInterval(1))
        #expect(await RecordingRecovery.recover(in: root, meetings: repo).isEmpty)
    }

    @Test("flush cadence follows media time, not wall time")
    func flushCadence() async throws {
        let dir = tempDirectory()
        let rec = recorder(flush: 1)
        let events = Collector(rec.events())
        try await rec.start(
            config: RecordingConfig(directory: dir, mixTrack: false),
            mic: stream([tone(seconds: 0.5, start: 0), tone(seconds: 0.5, start: 0.5), tone(seconds: 0.5, start: 1)]),
            remote: stream([]))
        _ = try await rec.stop()
        let flushes = await events.settled().filter { if case .flushed = $0 { true } else { false } }
        #expect(flushes.count == 1)
    }

    @Test("bookmarks are stored in the manifest")
    func bookmarks() async throws {
        let dir = tempDirectory()
        let rec = recorder()
        try await rec.start(config: RecordingConfig(directory: dir), mic: stream([tone(seconds: 1)]), remote: stream([]))
        await rec.addBookmark(at: 12.5, note: "pricing")
        let manifest = try RecordingManifest.read(from: dir)
        #expect(manifest.bookmarks == [RecordingManifest.Bookmark(time: 12.5, note: "pricing")])
        _ = try await rec.stop()
    }

    @Test("refuses to start with too little disk space and writes no tracks")
    func lowDiskAtStart() async throws {
        let dir = tempDirectory()
        let rec = recorder(disk: FakeDisk(100))
        await #expect(throws: RecorderError.insufficientDiskSpace(availableBytes: 100, requiredBytes: 1000)) {
            try await rec.start(config: RecordingConfig(directory: dir), mic: stream([]), remote: stream([]))
        }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.caf").path))
        #expect(await rec.isRecording == false)
    }

    @Test("falling below the stop threshold halts capture but keeps what was recorded")
    func lowDiskStop() async throws {
        let dir = tempDirectory()
        let disk = FakeDisk(10_000)
        let rec = recorder(disk: disk, flush: 1)
        let events = Collector(rec.events())
        var mic: AsyncStream<AudioChunk>.Continuation!
        let micStream = AsyncStream<AudioChunk> { mic = $0 }
        try await rec.start(config: RecordingConfig(directory: dir), mic: micStream, remote: stream([]))
        mic.yield(tone(seconds: 1, start: 0))
        await events.waitFor(count: 2)  // started, flushed
        disk.set(100)
        mic.yield(tone(seconds: 1, start: 1))
        await events.waitFor(count: 4)  // flushed, stoppedLowDisk
        #expect(await events.settled().contains(.stoppedLowDisk(availableBytes: 100)))
        #expect(await rec.isRecording == false)
        mic.yield(tone(seconds: 1, start: 2))  // ignored
        mic.finish()
        let recording = try await rec.stop()
        #expect(abs(recording.duration - 2) < 0.01)
        #expect(recording.tracks.contains { $0.role == .mix })
        #expect(try RecordingManifest.read(from: dir).haltedReason == "low disk space")
    }

    // MTG-AC-09 (seam)
    @Test("a failing video recorder never stops audio")
    func videoFailureIsNonFatal() async throws {
        let dir = tempDirectory()
        let log = CallLog()
        let rec = recorder(video: FakeVideo(fail: true, log: log))
        let events = Collector(rec.events())
        try await rec.start(
            config: RecordingConfig(directory: dir, includeVideo: true), mic: stream([tone(seconds: 1)]), remote: stream([]))
        let recording = try await rec.stop()
        #expect(recording.tracks.contains { $0.role == .mic })
        #expect(!recording.tracks.contains { $0.role == .video })
        let all = await events.settled()
        #expect(all.contains { if case .videoFailed = $0 { true } else { false } })
        #expect(await log.entries == ["video.start"])
    }

    @Test("audio arriving while video is still starting is not lost")
    func audioDuringVideoStartup() async throws {
        let dir = tempDirectory()
        let video = GatedVideo()
        let rec = recorder(video: video)
        var mic: AsyncStream<AudioChunk>.Continuation!
        // Like the real sources: bounded, newest wins, so nothing survives unless a consumer is already reading.
        let micStream = AsyncStream<AudioChunk>(bufferingPolicy: .bufferingNewest(1)) { mic = $0 }
        let starting = Task {
            try await rec.start(config: RecordingConfig(directory: dir, includeVideo: true), mic: micStream, remote: stream([]))
        }
        for i in 0..<3 {
            mic.yield(tone(seconds: 1, start: Double(i)))
            try await Task.sleep(for: .milliseconds(80))
        }
        await video.release()
        try await starting.value
        mic.finish()
        let recording = try await rec.stop()
        #expect(abs(recording.duration - 3) < 0.01)
        #expect(try frames(dir.appendingPathComponent("mic.caf")) == 48_000)
        #expect(recording.tracks.contains { $0.role == .video })
    }

    @Test("video is recorded only when requested, started before audio and stopped on stop")
    func videoRecorded() async throws {
        let dir = tempDirectory()
        let log = CallLog()
        let rec = recorder(video: FakeVideo(log: log))
        try await rec.start(
            config: RecordingConfig(directory: dir, includeVideo: true), mic: stream([tone(seconds: 1)]), remote: stream([]))
        let recording = try await rec.stop()
        #expect(recording.tracks.contains { $0.role == .video && $0.relativePath == "video.mov" })
        #expect(await log.entries == ["video.start", "video.stop"])

        let plain = recorder(video: FakeVideo(log: log))
        try await plain.start(config: RecordingConfig(directory: tempDirectory()), mic: stream([tone(seconds: 1)]), remote: stream([]))
        #expect(try await plain.stop().tracks.contains { $0.role == .video } == false)
    }

    @Test("start twice and stop before start are errors; stop is idempotent")
    func lifecycle() async throws {
        let rec = recorder()
        await #expect(throws: RecorderError.notRecording) { try await rec.stop() }
        try await rec.start(config: RecordingConfig(directory: tempDirectory()), mic: stream([tone(seconds: 1)]), remote: stream([]))
        await #expect(throws: RecorderError.alreadyRecording) {
            try await rec.start(config: RecordingConfig(directory: tempDirectory()), mic: stream([]), remote: stream([]))
        }
        let first = try await rec.stop()
        #expect(try await rec.stop() == first)
    }

    @Test("stop does not hang when the sources never end")
    func stopWithoutStreamEnd() async throws {
        let rec = recorder()
        var mic: AsyncStream<AudioChunk>.Continuation!
        let micStream = AsyncStream<AudioChunk> { mic = $0 }
        try await rec.start(config: RecordingConfig(directory: tempDirectory()), mic: micStream, remote: stream([]))
        mic.yield(tone(seconds: 1))
        try await Task.sleep(for: .milliseconds(100))
        let recording = try await rec.stop()
        #expect(recording.duration > 0.9)
        mic.finish()
    }
}
