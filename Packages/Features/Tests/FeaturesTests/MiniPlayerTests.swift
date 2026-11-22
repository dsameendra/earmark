import AppCore
import DesignSystem
import FeatureSupport
import Foundation
import SwiftUI
import Testing

@testable import FeatureEditor
@testable import FeatureShell

/// The mini-player scrubber: peaks and speaker ribbon owned by the playback session, not by an editor.
@Suite @MainActor struct MiniPlayerTests {
    private func service(in dir: URL) -> WaveformService {
        WaveformService(cache: WaveformCache(directory: dir.appendingPathComponent("cache")))
    }

    private func wav(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("talk.wav")
        try WaveformPlaybackTests.writeWAV([(2, 0.8), (2, 0.2)], to: url)
        return url
    }

    @Test func sessionLoadsPeaksOnceAndKeepsThemAfterTheEditorIsGone() async throws {
        let dir = try WaveformPlaybackTests.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try wav(in: dir)
        let center = PlaybackCenter()
        let log = EngineLog()
        let session = try #require(
            await center.open(transcriptID: TranscriptID(), title: "Talk", mediaURL: file, factory: log.factory))
        #expect(session.waveformState == .loading && session.waveformPyramid == nil)
        let service = service(in: dir)
        async let first: Void = session.loadWaveform(service: service, assetID: "a")
        async let second: Void = session.loadWaveform(service: service, assetID: "a")
        _ = await (first, second)
        #expect(session.waveformState == .ready)
        let peaks = try #require(session.waveformPeaks)
        #expect(abs(peaks.duration - 4) < 0.05)
        #expect(session.waveformPyramid != nil)
        #expect(session.waveformLoadState == .ready)
        #expect(center.session === session)
    }

    @Test func undecodableMediaIsUnavailableAndMissingMediaOverrides() async throws {
        let dir = try WaveformPlaybackTests.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bad = dir.appendingPathComponent("not-audio.wav")
        try Data("nope".utf8).write(to: bad)
        let center = PlaybackCenter()
        let session = try #require(
            await center.open(transcriptID: TranscriptID(), title: "Bad", mediaURL: bad, factory: EngineLog().factory))
        await session.loadWaveform(service: service(in: dir), assetID: nil)
        #expect(session.waveformState == .unavailable && session.waveformPyramid == nil)
        session.playback.markMissing()
        #expect(session.waveformLoadState == .unavailable)
    }

    @Test func editorPushesRibbonAndBookmarksIntoTheSession() async throws {
        let dir = try WaveformPlaybackTests.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try wav(in: dir)
        let asset = MediaAsset(kind: .audio, bookmark: try file.bookmarkData(options: [.withSecurityScope]))
        let transcript = Transcript(
            title: "Talk", source: .file, duration: 4, speakers: [Fixtures.alice, Fixtures.bob], mediaAssetID: asset.id)
        let repo = FakeTranscriptRepository(transcript: transcript, segments: Fixtures.segments())
        let center = PlaybackCenter()
        let model = TranscriptEditorModel(
            transcriptID: transcript.id, repository: repo, settings: InMemorySettingsStore(), media: InMemoryMedia(items: [asset]),
            persistDelay: .milliseconds(5), playbackCenter: center, engineFactory: EngineLog().factory)
        model.waveformService = service(in: dir)
        await model.load()
        let session = try #require(center.session)
        #expect(session.waveformSegments.count == 3)
        #expect(session.waveformSegments[0].label == "Alice" && session.waveformSegments[1].label == "Bob")
        #expect(session.waveformSegmentIDs == model.segments.map(\.id))
        model.addBookmark(at: 2, note: "Key point")
        #expect(session.waveformBookmarks.map(\.label) == ["Key point"])
        await session.loadWaveform(service: service(in: dir), assetID: nil)
        #expect(session.waveformState == .ready)
        // The editor closes: the ribbon, bookmarks and peaks stay on the session for the mini-player.
        model.leaveEditor()
        #expect(session.waveformSegments.count == 3 && session.waveformBookmarks.count == 1 && session.waveformPyramid != nil)
        #expect(session.waveformActiveIndex == nil || (0..<3).contains(session.waveformActiveIndex ?? -1))
    }

    @Test func stoppingTheSessionDropsIt() async throws {
        let center = PlaybackCenter()
        let session = try #require(
            await center.open(
                transcriptID: TranscriptID(), title: "Talk", mediaURL: URL(fileURLWithPath: "/tmp/x.m4a"), factory: EngineLog().factory))
        #expect(center.session === session)
        center.stop()
        #expect(center.session == nil)
    }

    @Test func miniPlayerSourceUsesTheSharedWaveformAndMotionTokens() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let mini = try String(contentsOf: root.appendingPathComponent("FeatureEditor/MiniPlayerView.swift"), encoding: .utf8)
        #expect(!mini.contains("Slider("), "the mini-player scrubs with WaveformView, not a Slider")
        #expect(mini.contains("WaveformView(") && mini.contains("miniPlayer.seek"))
        #expect(mini.components(separatedBy: "glass-layer:").count == 2, "exactly one floater glass layer")
        #expect(mini.components(separatedBy: ".dsGlass(").count == 2)
        for pattern in ["Color(red:", "Color(hex:", "NSColor(", "Color.gray", ".foregroundStyle(.secondary)"] {
            #expect(!mini.contains(pattern), "MiniPlayerView contains \(pattern)")
        }
        for id in ["miniPlayer.play", "miniPlayer.title", "miniPlayer.position", "miniPlayer.close", "\"miniPlayer\""] {
            #expect(mini.contains(id), "missing \(id)")
        }
        let shell = try String(contentsOf: root.appendingPathComponent("FeatureShell/ShellView.swift"), encoding: .utf8)
        let range = try #require(shell.range(of: "MiniPlayerView(center"))
        #expect(shell[range.upperBound...].prefix(300).contains(".dsTransition(.settle)"))
    }
}
