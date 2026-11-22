import AppCore
import Foundation
import Testing

@testable import Transcription

@Suite("StreamSegmenter")
struct StreamSegmenterTests {
    private func tone(_ seconds: Double, amplitude: Float = 0.1) -> [Float] {
        (0..<Int(seconds * 16000)).map { amplitude * sin(Float($0) * 0.2) }
    }
    private func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * 16000)) }

    /// Feeds `samples` in 100 ms chunks starting at `start` media seconds.
    private func feed(_ segmenter: inout StreamSegmenter, _ samples: [Float], from start: Double) {
        var index = 0
        while index < samples.count {
            let end = min(samples.count, index + 1600)
            segmenter.append(
                AudioChunk(samples: Array(samples[index..<end]), startSeconds: start + Double(index) / 16000, source: .mic(deviceUID: nil)))
            index = end
        }
    }

    @Test("long silence keeps memory bounded and does not look like speech")
    func silenceBounded() {
        var segmenter = StreamSegmenter()
        feed(&segmenter, silence(60), from: 10)
        #expect(!segmenter.hasSpeech)
        #expect(segmenter.bufferSeconds < 1)
        #expect(abs(segmenter.endTime - 70) < 0.1)
        #expect(segmenter.finalizationPoint() == nil)
    }

    @Test("a hard pause finalises the utterance and keeps media times")
    func pauseFinalises() throws {
        var segmenter = StreamSegmenter()
        feed(&segmenter, silence(2) + tone(1.5), from: 100)
        #expect(segmenter.hasSpeech)
        #expect(segmenter.finalizationPoint() == nil)
        // 0.5 s of silence is shorter than the hard endpoint and the utterance is short: still open.
        feed(&segmenter, silence(0.5), from: 103.5)
        #expect(segmenter.finalizationPoint() == nil)
        feed(&segmenter, silence(0.4), from: 104)
        let end = try #require(segmenter.finalizationPoint())
        #expect(abs(segmenter.time(at: segmenter.utteranceStart) - 101.7) < 0.1)
        #expect(segmenter.samples(upTo: end).count < Int(2.5 * 16000))
        segmenter.consume(upTo: end)
        #expect(!segmenter.hasSpeech)
        #expect(segmenter.bufferSeconds < 1)
    }

    @Test("a short pause ends a long utterance sooner (soft endpoint)")
    func softEndpoint() {
        var segmenter = StreamSegmenter()
        feed(&segmenter, tone(4), from: 0)
        feed(&segmenter, silence(0.4), from: 4)
        #expect(segmenter.finalizationPoint() != nil)
    }

    @Test("speech without pauses is cut at the quietest frame once the cap is reached")
    func lengthCap() throws {
        var segmenter = StreamSegmenter()
        // 6 s tone, a 0.2 s dip, then more tone: no endpoint, but the cap forces a cut inside the dip.
        feed(&segmenter, tone(6), from: 0)
        feed(&segmenter, tone(0.2, amplitude: 0.02), from: 6)
        feed(&segmenter, tone(2.5), from: 6.2)
        let end = try #require(segmenter.finalizationPoint())
        let cut = segmenter.time(at: end)
        #expect(cut > 5.9 && cut < 6.35, "cut at \(cut)")
        segmenter.consume(upTo: end)
        #expect(segmenter.hasSpeech)  // the remainder is still an open utterance
        #expect(segmenter.bufferStart > 5.9)
    }

    @Test("a blip shorter than the minimum speech is flagged as too short to decode")
    func blip() {
        var segmenter = StreamSegmenter()
        feed(&segmenter, silence(1) + tone(0.1) + silence(1), from: 0)
        #expect(segmenter.hasSpeech)
        #expect(segmenter.speechSeconds < segmenter.config.minSpeech)
    }
}
