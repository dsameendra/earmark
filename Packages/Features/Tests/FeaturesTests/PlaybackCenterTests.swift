import AppCore
import FeatureEditor
import FeatureShell
import FeatureSupport
import Foundation
import SwiftUI
import Testing

/// Keeps every engine a factory built so tests can count how many are still alive.
@MainActor final class EngineLog {
    private(set) var made: [FakePlayer] = []
    /// Players built and not yet released; more than one would mean two `AVPlayer`s could be audible at once.
    var liveCount: Int { made.filter { $0.releaseCount == 0 }.count }
    var factory: PlayerEngineFactory {
        { [self] _ in
            let player = FakePlayer()
            made.append(player)
            return (player, false)
        }
    }
}

@Suite @MainActor struct PlaybackCenterTests {
    private let url = URL(fileURLWithPath: "/tmp/earmark-test.m4a")

    @Test func openingSecondTranscriptStopsFirst() async throws {
        let center = PlaybackCenter()
        let log = EngineLog()
        let a = try #require(await center.open(transcriptID: TranscriptID(), title: "A", mediaURL: url, factory: log.factory))
        a.playback.togglePlay()
        let b = try #require(await center.open(transcriptID: TranscriptID(), title: "B", mediaURL: url, factory: log.factory))
        #expect(log.made[0].releaseCount == 1)
        #expect(log.made[0].pauseCount >= 1 && !log.made[0].isPlaying)
        #expect(log.liveCount == 1)
        #expect(center.session === b)
        #expect(!a.playback.canPlay)
    }

    @Test func reopeningSameTranscriptReusesSessionAndPosition() async throws {
        let center = PlaybackCenter()
        let log = EngineLog()
        let id = TranscriptID()
        let first = try #require(await center.open(transcriptID: id, title: "A", mediaURL: url, factory: log.factory))
        first.playback.togglePlay()
        await first.playback.seek(to: 12).value
        let again = try #require(await center.open(transcriptID: id, title: "A", mediaURL: url, factory: log.factory))
        #expect(again === first)
        #expect(log.made.count == 1)
        #expect(again.playback.currentTime == 12)
        #expect(again.playback.isPlaying)
        #expect(log.liveCount == 1)
    }

    @Test func closeStopsAndReleases() async throws {
        let center = PlaybackCenter()
        let log = EngineLog()
        let session = try #require(await center.open(transcriptID: TranscriptID(), title: "A", mediaURL: url, factory: log.factory))
        session.playback.togglePlay()
        center.stop()
        #expect(center.session == nil)
        #expect(log.made[0].releaseCount == 1 && !log.made[0].isPlaying)
        #expect(log.liveCount == 0)
        #expect(session.playback.engine == nil)
    }

    @Test func concurrentOpensLeaveExactlyOnePlayer() async {
        let center = PlaybackCenter()
        let log = EngineLog()
        let factory = log.factory
        let slow: PlayerEngineFactory = { url in
            for _ in 0..<5 { await Task.yield() }
            return await factory(url)
        }
        let target = url
        let first = Task { await center.open(transcriptID: TranscriptID(), title: "A", mediaURL: target, factory: slow) }
        let second = Task { await center.open(transcriptID: TranscriptID(), title: "B", mediaURL: target, factory: slow) }
        _ = await (first.value, second.value)
        #expect(log.liveCount == 1)
        #expect(center.session?.title == "B")
    }

    @Test func captureStartPausesButKeepsSession() async throws {
        let center = PlaybackCenter()
        let log = EngineLog()
        let session = try #require(await center.open(transcriptID: TranscriptID(), title: "A", mediaURL: url, factory: log.factory))
        session.playback.togglePlay()
        #expect(log.made[0].isPlaying)
        center.captureDidStart()
        #expect(!log.made[0].isPlaying)
        #expect(center.session === session)
    }

    @Test func sharedSessionHandlesSpaceAndK() async throws {
        let center = PlaybackCenter()
        let log = EngineLog()
        let session = try #require(await center.open(transcriptID: TranscriptID(), title: "A", mediaURL: url, factory: log.factory))
        session.playback.perform(try #require(PlaybackShortcut.resolve(key: .space, modifiers: [])))
        #expect(log.made[0].isPlaying)
        session.playback.perform(try #require(PlaybackShortcut.resolve(key: KeyEquivalent("k"), modifiers: [])))
        #expect(!log.made[0].isPlaying)
    }

    // MARK: Through the editor model

    private func mediaModel(
        center: PlaybackCenter, log: EngineLog, id: TranscriptID = TranscriptID(), file: URL
    ) throws -> TranscriptEditorModel {
        let asset = MediaAsset(kind: .audio, bookmark: try file.bookmarkData(options: [.withSecurityScope]))
        let media = InMemoryMedia(items: [asset])
        let transcript = Transcript(id: id, title: "Talk", source: .file, duration: 60, speakers: [], mediaAssetID: asset.id)
        let repo = FakeTranscriptRepository(transcript: transcript, segments: Fixtures.segments())
        return TranscriptEditorModel(
            transcriptID: id, repository: repo, settings: InMemorySettingsStore(), media: media, persistDelay: .milliseconds(5),
            playbackCenter: center, engineFactory: log.factory)
    }

    private func tempFile() throws -> URL {
        let file = FileManager.default.temporaryDirectory.appending(path: "earmark-\(UUID().uuidString).m4a")
        try Data([0]).write(to: file)
        return file
    }

    @Test func reopenedEditorResumesAtCurrentPositionWithOnePlayer() async throws {
        let file = try tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let center = PlaybackCenter()
        let log = EngineLog()
        let id = TranscriptID()
        let first = try mediaModel(center: center, log: log, id: id, file: file)
        await first.load()
        first.playback.togglePlay()
        await first.playback.seek(to: 12).value
        first.leaveEditor()
        #expect(center.session != nil)  // keeps playing for the mini-player
        #expect(log.made[0].isPlaying)
        let second = try mediaModel(center: center, log: log, id: id, file: file)
        await second.load()
        #expect(second.playback === first.playback)
        #expect(second.playback.currentTime == 12)
        #expect(log.made.count == 1 && log.liveCount == 1)
    }

    @Test func openingAnotherTranscriptInEditorReplacesSession() async throws {
        let file = try tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let center = PlaybackCenter()
        let log = EngineLog()
        let a = try mediaModel(center: center, log: log, file: file)
        await a.load()
        a.playback.togglePlay()
        let b = try mediaModel(center: center, log: log, file: file)
        await b.load()
        #expect(log.made.count == 2)
        #expect(log.made[0].releaseCount == 1 && !log.made[0].isPlaying)
        #expect(log.liveCount == 1)
        #expect(center.session?.transcriptID == b.transcriptID)
    }

    @Test func leavingEditorDoesNotRetainTheModel() async throws {
        let file = try tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let center = PlaybackCenter()
        let log = EngineLog()
        weak var weakModel: TranscriptEditorModel?
        do {
            let model = try mediaModel(center: center, log: log, file: file)
            weakModel = model
            await model.load()
            model.leaveEditor()
            await model.flush()
        }
        #expect(await eventually { weakModel == nil })
        center.stop()
        #expect(log.liveCount == 0)
    }

    @Test func editorWithoutCenterStopsItsOwnPlayerOnLeave() async {
        let player = FakePlayer()
        let model = TranscriptEditorModel(
            transcriptID: TranscriptID(), repository: FakeTranscriptRepository(transcript: Fixtures.transcript(), segments: []),
            settings: InMemorySettingsStore(), engineFactory: { _ in nil })
        model.playback.attach(player, isVideo: false)
        model.playback.togglePlay()
        model.leaveEditor()
        #expect(player.releaseCount == 1 && !player.isPlaying)
    }

    // MARK: Shell

    @Test func shellShowsMiniPlayerAfterNavigationAndCloseStops() async throws {
        let shell = ShellModel(services: .preview())
        let log = EngineLog()
        let id = TranscriptID()
        let session = try #require(await shell.playback.open(transcriptID: id, title: "A", mediaURL: url, factory: log.factory))
        session.playback.togglePlay()
        shell.openTranscript(id)
        #expect(!shell.showsMiniPlayer)  // the editor dock is showing
        shell.select(.library)
        #expect(shell.showsMiniPlayer)
        #expect(log.made[0].isPlaying)  // still playing, with controls on screen
        shell.openTranscript(id)  // same transcript resumes
        #expect(shell.playback.session === session && log.liveCount == 1)
        shell.select(.home)
        shell.playback.stop()
        #expect(!shell.showsMiniPlayer && log.made[0].releaseCount == 1)
    }

    @Test func shellOpeningDifferentTranscriptStopsOldAudio() async throws {
        let shell = ShellModel(services: .preview())
        let log = EngineLog()
        let session = try #require(
            await shell.playback.open(transcriptID: TranscriptID(), title: "A", mediaURL: url, factory: log.factory))
        session.playback.togglePlay()
        shell.openTranscript(TranscriptID())
        #expect(shell.playback.session == nil)
        #expect(!log.made[0].isPlaying && log.made[0].releaseCount == 1)
    }

    @Test func shellCaptureStartPausesPlayback() async throws {
        let shell = ShellModel(services: .preview())
        let log = EngineLog()
        let session = try #require(
            await shell.playback.open(transcriptID: TranscriptID(), title: "A", mediaURL: url, factory: log.factory))
        session.playback.togglePlay()
        shell.captureStateChanged(recording: false, dictating: false)
        #expect(log.made[0].isPlaying)
        shell.captureStateChanged(recording: false, dictating: true)
        #expect(!log.made[0].isPlaying)
    }

    @Test func deletingPlayingTranscriptStopsPlayback() async throws {
        let transcript = Transcript(title: "A", source: .file, duration: 60)
        let shell = ShellModel(services: .preview(transcripts: [transcript]))
        let log = EngineLog()
        let session = try #require(
            await shell.playback.open(transcriptID: transcript.id, title: "A", mediaURL: url, factory: log.factory))
        session.playback.togglePlay()
        await shell.library.delete([transcript.id])
        #expect(shell.playback.session == nil)
        #expect(log.made[0].releaseCount == 1)
    }
}
