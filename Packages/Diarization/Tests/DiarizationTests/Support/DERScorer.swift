import Foundation

/// Frame-based diarization error rate (10 ms frames), mirroring `pyannote.metrics` DER as used by the diarization spike
/// (`spikes/diarization/scripts/score_der.py`). Speaker mapping is the exact optimum over injective maps.
///
/// Protocol A: collar 0, overlap scored (strict). Protocol B: collar 0.25 s (0.125 s either side of every reference
/// boundary), reference-overlap frames skipped (lenient, literature style).
enum DERScorer {
    struct Turn {
        var speaker: String
        var start: Double
        var end: Double
    }

    struct Result {
        var total: Double
        var miss: Double
        var falseAlarm: Double
        var confusion: Double
        var der: Double { total > 0 ? (miss + falseAlarm + confusion) / total : 0 }
        var missRate: Double { total > 0 ? miss / total : 0 }
        var falseAlarmRate: Double { total > 0 ? falseAlarm / total : 0 }
        var confusionRate: Double { total > 0 ? confusion / total : 0 }
    }

    static let frame = 0.01

    static func parseRTTM(_ text: String) -> [Turn] {
        text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ")
            guard f.count >= 8, f[0] == "SPEAKER", let start = Double(f[3]), let dur = Double(f[4]) else { return nil }
            return Turn(speaker: String(f[7]), start: start, end: start + dur)
        }
    }

    static func score(reference: [Turn], hypothesis: [Turn], uem: ClosedRange<Double>, collar: Double, skipOverlap: Bool) -> Result {
        let start = Int((uem.lowerBound / frame).rounded())
        let count = max(0, Int((uem.upperBound / frame).rounded()) - start)
        let refLabels = Array(Set(reference.map(\.speaker))).sorted()
        let hypLabels = Array(Set(hypothesis.map(\.speaker))).sorted()
        func masks(_ turns: [Turn], _ labels: [String]) -> [UInt32] {
            var out = [UInt32](repeating: 0, count: count)
            for turn in turns {
                guard let bit = labels.firstIndex(of: turn.speaker) else { continue }
                let lo = max(0, Int((turn.start / frame).rounded()) - start)
                let hi = min(count, Int((turn.end / frame).rounded()) - start)
                if lo < hi { for i in lo..<hi { out[i] |= 1 << UInt32(bit) } }
            }
            return out
        }
        let ref = masks(reference, refLabels)
        let hyp = masks(hypothesis, hypLabels)
        var scored = [Bool](repeating: true, count: count)
        if collar > 0 {
            for turn in reference {
                for edge in [turn.start, turn.end] {
                    let lo = max(0, Int(((edge - collar / 2) / frame).rounded()) - start)
                    let hi = min(count, Int(((edge + collar / 2) / frame).rounded()) - start)
                    if lo < hi { for i in lo..<hi { scored[i] = false } }
                }
            }
        }
        if skipOverlap { for i in 0..<count where ref[i].nonzeroBitCount > 1 { scored[i] = false } }

        // Co-occurrence of (ref speaker, hyp speaker) over scored frames.
        var co = [[Int]](repeating: [Int](repeating: 0, count: hypLabels.count), count: refLabels.count)
        for i in 0..<count where scored[i] && ref[i] != 0 && hyp[i] != 0 {
            for r in 0..<refLabels.count where ref[i] & (1 << UInt32(r)) != 0 {
                for h in 0..<hypLabels.count where hyp[i] & (1 << UInt32(h)) != 0 { co[r][h] += 1 }
            }
        }
        let mapping = bestMapping(co: co, refCount: refLabels.count, hypCount: hypLabels.count)
        var mappedMask = [UInt32](repeating: 0, count: refLabels.count)  // per ref speaker: bit of mapped hyp (or 0)
        for (r, h) in mapping.enumerated() where h >= 0 { mappedMask[r] = 1 << UInt32(h) }

        var total = 0.0
        var miss = 0.0
        var falseAlarm = 0.0
        var confusion = 0.0
        for i in 0..<count where scored[i] {
            let nr = ref[i].nonzeroBitCount
            let nh = hyp[i].nonzeroBitCount
            var correct = 0
            for r in 0..<refLabels.count where ref[i] & (1 << UInt32(r)) != 0 && mappedMask[r] & hyp[i] != 0 { correct += 1 }
            total += Double(nr)
            miss += Double(max(0, nr - nh))
            falseAlarm += Double(max(0, nh - nr))
            confusion += Double(min(nr, nh) - correct)
        }
        return Result(total: total * frame, miss: miss * frame, falseAlarm: falseAlarm * frame, confusion: confusion * frame)
    }

    /// Exhaustive search over injective ref -> hyp maps (hyp index, or -1 for unmapped) maximising total co-occurrence.
    private static func bestMapping(co: [[Int]], refCount: Int, hypCount: Int) -> [Int] {
        var best = [Int](repeating: -1, count: refCount)
        var bestScore = -1
        var current = [Int](repeating: -1, count: refCount)
        var used = [Bool](repeating: false, count: hypCount)
        func recurse(_ r: Int, _ score: Int) {
            if r == refCount {
                if score > bestScore {
                    bestScore = score
                    best = current
                }
                return
            }
            current[r] = -1
            recurse(r + 1, score)
            for h in 0..<hypCount where !used[h] {
                used[h] = true
                current[r] = h
                recurse(r + 1, score + co[r][h])
                used[h] = false
            }
            current[r] = -1
        }
        recurse(0, 0)
        return best
    }
}
