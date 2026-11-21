import AppCore
import Foundation
import Testing

@testable import AudioCapture

private func isError(_ error: any Error, _ matches: (AppError) -> Bool) -> Bool {
    guard let appError = error as? AppError else { return false }
    return matches(appError)
}

private func isMediaMissing(_ error: any Error) -> Bool {
    isError(error) { if case .mediaMissing = $0 { true } else { false } }
}

private func isUnsupported(_ error: any Error) -> Bool {
    isError(error) { if case .unsupportedFormat = $0 { true } else { false } }
}

@Suite struct AVFileDecoderTests {
    let decoder = AVFileDecoder()

    private func collect(_ url: URL, chunk: TimeInterval, start: TimeInterval = 0) async throws -> [AudioChunk] {
        var chunks: [AudioChunk] = []
        for try await item in decoder.decode(file: url, chunkSeconds: chunk, startingAt: start) { chunks.append(item) }
        return chunks
    }

    @Test func sampleCountAndDurationFromSyntheticWAV() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tone.wav")
        try writeSineWAV(to: url, seconds: 10.3, sampleRate: 8_000)
        let duration = try await decoder.duration(of: url)
        #expect(abs(duration - 10.3) < 0.01)
        let chunks = try await collect(url, chunk: 2.5)
        let total = chunks.reduce(0) { $0 + $1.samples.count }
        #expect(abs(total - Int(10.3 * 16_000)) <= 80)  // resampler edge tolerance 5 ms
        #expect(chunks.count == 5)
        #expect(chunks.dropLast().allSatisfy { $0.samples.count == 40_000 })
        #expect(chunks.allSatisfy { $0.source == .file })
        for (index, chunk) in chunks.enumerated() {
            #expect(abs(chunk.startSeconds - Double(index) * 2.5) < 1e-6)
        }
        let peak = chunks[1].samples.map(abs).max() ?? 0
        #expect(peak > 0.45 && peak < 0.55)
    }

    @Test func resumeOffsetSkipsAudio() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tone.wav")
        try writeSineWAV(to: url, seconds: 10, sampleRate: 16_000)
        let chunks = try await collect(url, chunk: 2, start: 5)
        let first = try #require(chunks.first)
        #expect(abs(first.startSeconds - 5) < 0.01)
        let total = chunks.reduce(0) { $0 + $1.samples.count }
        #expect(abs(total - 80_000) <= 160)
        #expect(chunks.count == 3)
    }

    @Test func startingPastEndYieldsNothing() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tone.wav")
        try writeSineWAV(to: url, seconds: 2, sampleRate: 16_000)
        #expect(try await collect(url, chunk: 1, start: 30).isEmpty)
    }

    @Test func memoryStaysBoundedOnLongFile() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("long.wav")
        // 45 minutes at 16 kHz = 172 MB of Float32 if it were ever fully materialised.
        try writeSineWAV(to: url, seconds: 45 * 60, sampleRate: 16_000)
        let baseline = residentBytes()
        var peak = baseline
        var samples = 0
        var maxChunk = 0
        for try await chunk in decoder.decode(file: url, chunkSeconds: 30, startingAt: 0) {
            samples += chunk.samples.count
            maxChunk = max(maxChunk, chunk.samples.count)
            peak = max(peak, residentBytes())
        }
        #expect(abs(samples - 45 * 60 * 16_000) <= 1_600)
        #expect(maxChunk == 30 * 16_000)
        #expect(peak - baseline < 48 * 1_024 * 1_024, "resident growth \((peak - baseline) / 1_048_576) MB")
    }

    @Test func cancellationStopsDecoding() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tone.wav")
        try writeSineWAV(to: url, seconds: 600, sampleRate: 16_000)
        let decoder = self.decoder
        let task = Task { () -> Int in
            var count = 0
            for try await _ in decoder.decode(file: url, chunkSeconds: 1, startingAt: 0) {
                count += 1
                if count == 3 { withUnsafeCurrentTask { $0?.cancel() } }
            }
            return count
        }
        do {
            let count = try await task.value
            #expect(count < 600)
        } catch is CancellationError {
        }
    }

    @Test func missingFileMapsToMediaMissing() async throws {
        let url = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).wav")
        await #expect { try await collect(url, chunk: 1) } throws: { isMediaMissing($0) }
        await #expect { try await decoder.duration(of: url) } throws: { isMediaMissing($0) }
    }

    @Test func nonMediaFileMapsToUnsupportedFormat() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("fake.mp3")
        try Data("this is not audio".utf8).write(to: url)
        await #expect { try await collect(url, chunk: 1) } throws: { isUnsupported($0) }
        await #expect { try await decoder.duration(of: url) } throws: { isUnsupported($0) }
    }

    // MARK: Fixtures (skipped when the gitignored audio is absent)

    @Test func fixtureSpeechDurationAndSampleCount() async throws {
        guard let url = Fixtures.url("en-single-librispeech/en-single-librispeech.wav") else { return }  // fixture absent: skip
        let duration = try await decoder.duration(of: url)
        #expect(abs(duration - 91.98) < 0.02)
        let chunks = try await collect(url, chunk: 30)
        #expect(chunks.count == 4)
        let total = chunks.reduce(0) { $0 + $1.samples.count }
        #expect(abs(Double(total) / 16_000 - 91.98) < 0.02)
    }

    @Test func fixtureVideoContainerDecodes() async throws {
        guard let url = Fixtures.url("video-wikimedia-talk/talk_h264.mp4") else { return }
        let duration = try await decoder.duration(of: url)
        #expect(abs(duration - 283.46) < 0.1)
        let chunks = try await collect(url, chunk: 60)
        let total = chunks.reduce(0) { $0 + $1.samples.count }
        #expect(abs(Double(total) / 16_000 - duration) < 0.1)
        let resumed = try await collect(url, chunk: 60, start: 200)
        #expect(abs((resumed.first?.startSeconds ?? 0) - 200) < 0.1)
    }
}
