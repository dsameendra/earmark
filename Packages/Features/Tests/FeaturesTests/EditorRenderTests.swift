import AVFoundation
import AppCore
import FeatureSupport
import Foundation
import SwiftUI
import Testing

@testable import FeatureEditor

private struct FindBarHost: View {
    let model: TranscriptEditorModel
    let find: FindReplaceModel
    @FocusState private var focused: Bool
    var body: some View { FindBarView(model: model, find: find, fieldFocused: $focused) }
}

/// The first ImageRenderer use in a process blocks the main actor for a few hundred ms while SwiftUI warms up, which
/// starves other suites' timing-sensitive main-actor tests (Menu Bar's 300 ms waits). Rendering starts after a grace period.
enum RenderGate {
    static let ready = Task { try? await Task.sleep(for: .seconds(2)) }
}

@Suite @MainActor struct EditorRenderTests {
    /// Renders on the main actor; sleeps first so other main-actor tests (timing-sensitive Menu Bar tests) are not starved.
    private func render<V: View>(_ view: V, size: CGSize = CGSize(width: 640, height: 360)) async -> NSImage? {
        await RenderGate.ready.value
        try? await Task.sleep(for: .milliseconds(40))
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height).background(Color.white))
        renderer.scale = 1
        return renderer.nsImage
    }

    private func hasInk(_ image: NSImage) -> Bool {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return false }
        var seen = Set<UInt32>()
        for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let key = UInt32(color.redComponent * 255) << 16 | UInt32(color.greenComponent * 255) << 8
                seen.insert(key | UInt32(color.blueComponent * 255))
                if seen.count > 3 { return true }
            }
        }
        return false
    }

    private func loadedModel() async -> TranscriptEditorModel {
        var segments = Fixtures.segments()
        segments.append(Fixtures.segment("ශ්‍රී ලංකාව සහ English mixed", start: 15, speaker: Fixtures.bob.id, language: "si"))
        segments[1].isIgnored = true
        let (model, _) = await Fixtures.model(segments: segments)
        model.setShowIgnored(true)
        return model
    }

    @Test func segmentAndParagraphRowsRender() async {
        // ImageRenderer cannot draw ScrollView/LazyVStack content, so the rows are rendered in a plain stack.
        let model = await loadedModel()
        let find = FindReplaceModel(editor: model)
        let segmentRows = VStack(alignment: .leading, spacing: 0) {
            ForEach(model.visibleSegments) { SegmentRowView(model: model, find: find, segment: $0) }
        }
        let segmentImage = await render(segmentRows)
        #expect(segmentImage != nil && segmentImage.map(hasInk) == true)
        model.updateOptions { $0.layout = .paragraphs }
        #expect(model.paragraphs.isEmpty == false)
        let paragraphRows = VStack(alignment: .leading, spacing: 0) {
            ForEach(model.paragraphs) { ParagraphRowView(model: model, find: find, paragraph: $0) }
        }
        #expect(await render(paragraphRows).map(hasInk) == true)
        // The scrolling container itself must at least build.
        #expect(await render(TranscriptListView(model: model, find: find)) != nil)
    }

    @Test func barsPanelsAndStatesRender() async {
        let model = await loadedModel()
        let find = FindReplaceModel(editor: model)
        find.open(replace: true)
        find.text = "is"
        await find.searchNow()
        let views: [AnyView] = [
            AnyView(FindBarHost(model: model, find: find)),
            AnyView(TransportBar(model: model)),
            AnyView(SpeakersPanel(model: model)),
            AnyView(BookmarksPanel(model: model)),
            AnyView(ViewOptionsPanel(model: model)),
            AnyView(MediaMissingView(onRelink: {})),
            AnyView(ExportSheet(export: EditorExportModel(editor: model), onClose: {})),
        ]
        for (index, view) in views.enumerated() {
            let image = await render(view, size: CGSize(width: 560, height: 420))
            // Index 4 is a grouped Form of AppKit-backed controls, which ImageRenderer draws as placeholders.
            #expect(index == 4 ? image != nil : image.map(hasInk) == true, "view \(index)")
        }
    }

    @Test func fullEditorViewRendersLoadingState() async {
        let services = AppServices.preview()
        let image = await render(TranscriptEditorView(transcriptID: TranscriptID(), services: services))
        #expect(image != nil)
    }

    @Test func detachedPlayerWindowSharesPlaybackState() async {
        await RenderGate.ready.value
        let model = await loadedModel()
        let player = FakePlayer()
        model.playback.attach(player, isVideo: false)
        let controller = PlayerWindowController(model: model, onRelink: {})
        model.playback.isDetached = true
        controller.show()
        player.onTick?(4.7)  // a tick drives both the docked transcript and the detached window's model
        #expect(model.playback.activeRef?.segmentID == model.segments[1].id)
        await model.playback.seekToWord(in: model.segments[2], wordIndex: 1).value
        #expect(player.seeks.last == model.segments[2].words[1].start)
        controller.close()
    }
}

// MARK: - Seek latency (EDIT-AC-02)

@Suite @MainActor struct SeekLatencyTests {
    /// Writes a mono 16-bit tone file of `seconds` length.
    private nonisolated static func makeTone(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "tone-\(UUID().uuidString).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * 16_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 16_000)) * 0.4 }
        try file.write(from: buffer)
        return url
    }

    struct LatencyStats {
        var median: Double
        var p95: Double
        var max: Double
    }

    /// Click-handler path while playing: word lookup + frame-accurate (zero tolerance) AVPlayer seek, awaited to completion.
    private func measure(url: URL, duration: Double, samples: Int = 40) async throws -> LatencyStats {
        let engine = AVPlayerEngine(url: url)
        #expect(await engine.waitUntilReady())
        let step = duration / Double(samples + 1)
        let (model, _) = await Fixtures.model(
            segments: (0..<samples).map {
                Fixtures.segment("alpha beta gamma delta epsilon", start: Double($0) * step, secondsPerWord: 0.2)
            })
        model.playback.attach(engine, isVideo: false)
        await model.playback.seek(to: 0).value  // warm up
        engine.play()
        defer { engine.pause() }
        var durations: [Double] = []
        let clock = ContinuousClock()
        for index in 0..<samples {
            try await Task.sleep(for: .milliseconds(250))  // clicks are human-paced, not back to back
            let segment = model.segments[(index * 7) % model.segments.count]
            let word = index % 5
            let start = clock.now
            await model.playback.seekToWord(in: segment, wordIndex: word).value
            let elapsed = clock.now - start
            durations.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        }
        durations.sort()
        let p95 = durations[Int(Double(durations.count) * 0.95)]
        return LatencyStats(median: durations[durations.count / 2], p95: p95, max: durations.last!)
    }

    private func fixture(_ relative: String) -> URL? {
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["EARMARK_FIXTURES_DIR"] { candidates.append(URL(fileURLWithPath: env)) }
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<7 {
            candidates.append(dir.appending(path: "fixtures"))
            dir.deleteLastPathComponent()
        }
        return candidates.map { $0.appending(path: relative) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    @Test func clickToSeekOnCompressedMediaStaysUnder100ms() async throws {
        // Fixture-gated: AAC (m4a) and H.264/AAC (mp4). Skipped when the large fixtures are not checked out.
        if let wav = fixture("en-single-librispeech/en-single-librispeech.wav") {
            let m4a = FileManager.default.temporaryDirectory.appending(path: "fixture-\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: m4a) }
            let convert = Process()
            convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            convert.arguments = ["-f", "m4af", "-d", "aac", wav.path, m4a.path]
            try convert.run()
            convert.waitUntilExit()
            if convert.terminationStatus == 0 {
                let stats = try await measure(url: m4a, duration: 90)
                print("SEEK_LATENCY_AAC_MS median=\(stats.median) p95=\(stats.p95) max=\(stats.max)")
                #expect(stats.p95 < 100)
            }
        }
        if let mp4 = fixture("video-wikimedia-talk/talk_h264.mp4") {
            let stats = try await measure(url: mp4, duration: 270)
            print("SEEK_LATENCY_H264_MS median=\(stats.median) p95=\(stats.p95) max=\(stats.max)")
            #expect(stats.p95 < 100)
        }
    }

    @Test func clickToSeekCompletesWellUnder100ms() async throws {
        let url = try await Task.detached { try Self.makeTone(seconds: 90) }.value
        defer { try? FileManager.default.removeItem(at: url) }
        let stats = try await measure(url: url, duration: 85)
        print("SEEK_LATENCY_MS median=\(stats.median) p95=\(stats.p95) max=\(stats.max)")
        #expect(stats.p95 < 100)
    }
}
