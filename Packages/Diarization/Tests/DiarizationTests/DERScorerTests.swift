import Foundation
import Testing

@Suite("DER scorer") struct DERScorerTests {
    @Test func perfectHypothesisHasZeroError() {
        let ref = [DERScorer.Turn(speaker: "a", start: 0, end: 5), DERScorer.Turn(speaker: "b", start: 5, end: 10)]
        let hyp = [DERScorer.Turn(speaker: "x", start: 0, end: 5), DERScorer.Turn(speaker: "y", start: 5, end: 10)]
        let result = DERScorer.score(reference: ref, hypothesis: hyp, uem: 0...10, collar: 0, skipOverlap: false)
        #expect(result.der < 1e-9)
    }

    @Test func componentsAddUp() {
        let ref = [DERScorer.Turn(speaker: "a", start: 0, end: 10)]
        // 2 s missed (0-2), 1 s confused (9-10 given to another cluster), 1 s false alarm after the reference ends (10-11).
        let hyp = [
            DERScorer.Turn(speaker: "x", start: 2, end: 9), DERScorer.Turn(speaker: "y", start: 9, end: 10),
            DERScorer.Turn(speaker: "x", start: 10, end: 11),
        ]
        let result = DERScorer.score(reference: ref, hypothesis: hyp, uem: 0...12, collar: 0, skipOverlap: false)
        #expect(abs(result.miss - 2) < 0.02)
        #expect(abs(result.falseAlarm - 1) < 0.02)
        #expect(abs(result.confusion - 1) < 0.02)
        #expect(abs(result.total - 10) < 0.02)
    }

    /// Gate for trusting the Swift scorer: reproduces the spike's pyannote.metrics numbers for FluidAudio offline on the
    /// full ES2004a meeting (protocol A: DER 22.2 = miss 16.2 + fa 2.9 + conf 3.1; protocol B: DER 9.8).
    @Test func reproducesSpikePyannoteNumbers() throws {
        guard let cache = LocalAssets.modelCache,
            let hypURL = LocalAssets.repoFile("spikes/diarization/results/fluid-ES2004a.rttm")
        else { return }
        let refURL = cache.appendingPathComponent("datasets/ami/ref/ES2004a.rttm")
        guard FileManager.default.fileExists(atPath: refURL.path) else { return }
        let ref = DERScorer.parseRTTM(try String(contentsOf: refURL, encoding: .utf8))
        let hyp = DERScorer.parseRTTM(try String(contentsOf: hypURL, encoding: .utf8))
        let uem = 0.0...1049.354687
        let a = DERScorer.score(reference: ref, hypothesis: hyp, uem: uem, collar: 0, skipOverlap: false)
        let b = DERScorer.score(reference: ref, hypothesis: hyp, uem: uem, collar: 0.25, skipOverlap: true)
        print("SCORER-CHECK A: DER \(a.der * 100) miss \(a.missRate * 100) fa \(a.falseAlarmRate * 100) conf \(a.confusionRate * 100)")
        print("SCORER-CHECK B: DER \(b.der * 100)")
        #expect(abs(a.der * 100 - 22.2) < 0.3)
        #expect(abs(a.missRate * 100 - 16.2) < 0.3)
        #expect(abs(a.falseAlarmRate * 100 - 2.9) < 0.3)
        #expect(abs(a.confusionRate * 100 - 3.1) < 0.3)
        #expect(abs(b.der * 100 - 9.8) < 0.3)
    }
}
