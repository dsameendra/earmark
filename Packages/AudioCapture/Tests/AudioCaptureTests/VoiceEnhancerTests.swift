import AppCore
import Foundation
import Testing

@testable import AudioCapture

// Benchmark optimized product code. Debug interpreter/collection overhead is
// toolchain and runner dependent; correctness cases still run in both builds.
#if DEBUG
private let optimizedEnhancerBuild = false
#else
private let optimizedEnhancerBuild = true
#endif

/// Deterministic synthetic signals for the enhancer tests.
enum SynthVoice {
    static let rate = 16_000.0

    /// xorshift white noise in [-1, 1].
    static func noise(count: Int, seed: UInt64 = 0x9E37_79B9_7F4A_7C15) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Float(Double(state >> 11) / Double(1 << 53) * 2 - 1)
        }
    }

    /// Speech-like: harmonic series on a gliding pitch, gated in 0.5 s syllables with 0.3 s gaps, scaled to `rmsDB` over the
    /// active parts.
    static func speech(seconds: Double, rmsDB: Float = -20, f0: Double = 130) -> [Float] {
        let count = Int(seconds * rate)
        var out = [Float](repeating: 0, count: count)
        var phase = 0.0
        for i in 0..<count {
            let t = Double(i) / rate
            let pitch = f0 * (1 + 0.1 * sin(2 * Double.pi * 0.7 * t))
            phase += 2 * Double.pi * pitch / rate
            var value = 0.0
            for h in 1...18 { value += sin(Double(h) * phase) / Double(h) }
            let cycle = t.truncatingRemainder(dividingBy: 0.8)
            let gate = cycle < 0.5 ? sin(Double.pi * cycle / 0.5) : 0
            out[i] = Float(value * gate)
        }
        return scaled(out, activeRMSDB: rmsDB)
    }

    /// Scales so the RMS over samples above a small threshold equals `activeRMSDB`.
    static func scaled(_ x: [Float], activeRMSDB: Float) -> [Float] {
        let current = activeRMS(x)
        let gain = pow(10, activeRMSDB / 20) / max(current, 1e-9)
        return x.map { $0 * gain }
    }

    /// RMS over 16 ms blocks that are within 25 dB of the loudest block (the "speech" parts).
    static func activeRMS(_ x: [Float]) -> Float {
        let block = 256
        var powers: [Float] = []
        var i = 0
        while i + block <= x.count {
            var s: Float = 0
            for j in i..<(i + block) { s += x[j] * x[j] }
            powers.append(s / Float(block))
            i += block
        }
        guard let top = powers.max(), top > 0 else { return 0 }
        let active = powers.filter { $0 > top * 0.003 }
        return (active.reduce(0, +) / Float(max(1, active.count))).squareRoot()
    }

    static func rmsDB(_ x: [Float]) -> Float { 20 * log10(max(activeRMS(x), 1e-9)) }

    /// Scale-invariant SNR of `y` against reference `ref` (dB).
    static func snr(_ y: [Float], reference ref: [Float]) -> Float {
        var yr = 0.0, rr = 0.0
        for i in 0..<ref.count {
            yr += Double(y[i]) * Double(ref[i])
            rr += Double(ref[i]) * Double(ref[i])
        }
        let alpha = yr / max(rr, 1e-12)
        var err = 0.0
        for i in 0..<ref.count {
            let e = Double(y[i]) - alpha * Double(ref[i])
            err += e * e
        }
        return Float(10 * log10(alpha * alpha * rr / max(err, 1e-18)))
    }

    static func mix(_ speech: [Float], noiseDB: Float, seed: UInt64 = 1) -> [Float] {
        let n = noise(count: speech.count, seed: seed)
        var rms: Float = 0
        for v in n { rms += v * v }
        rms = (rms / Float(n.count)).squareRoot()
        let gain = pow(10, noiseDB / 20) / rms
        return zip(speech, n).map { $0 + $1 * gain }
    }

    /// The 80 Hz high-pass alone, so SNR can be judged against a reference that has the same (intended) phase response.
    static func highPassed(_ x: [Float], hz: Double = 80) -> [Float] {
        let w0 = 2 * Double.pi * hz / rate
        let alpha = sin(w0) / (2 * 0.70710678)
        let a0 = 1 + alpha
        let b0 = (1 + cos(w0)) / 2 / a0, b1 = -(1 + cos(w0)) / a0, a1 = -2 * cos(w0) / a0, a2 = (1 - alpha) / a0
        var z1 = 0.0, z2 = 0.0
        return x.map { sample in
            let v = Double(sample)
            let y = b0 * v + z1
            z1 = b1 * v - a1 * y + z2
            z2 = b0 * v - a2 * y
            return Float(y)
        }
    }

    static func chunked(_ x: [Float], sizes: [Int], level: VoiceProcessingLevel) -> [Float] {
        let enhancer = VoiceEnhancer(level: level)
        var out: [Float] = []
        var index = 0
        var k = 0
        while index < x.count {
            let size = min(sizes[k % sizes.count], x.count - index)
            out += enhancer.process(Array(x[index..<(index + size)]))
            index += size
            k += 1
        }
        return out + enhancer.finish()
    }
}

@Suite struct VoiceEnhancerTests {
    @Test func offIsPassThrough() {
        let x = SynthVoice.noise(count: 5_000)
        #expect(VoiceEnhancer.enhance(x, level: .off) == x)
    }

    @Test func outputLengthMatchesInput() {
        for count in [0, 1, 255, 256, 257, 1000, 16_000, 33_333] {
            let x = SynthVoice.noise(count: count)
            for level in [VoiceProcessingLevel.light, .standard, .strong] {
                #expect(VoiceEnhancer.enhance(x, level: level).count == count)
            }
        }
    }

    @Test func noiseReductionImprovesSNR() {
        let clean = SynthVoice.speech(seconds: 20, rmsDB: -20)
        let noisy = SynthVoice.mix(clean, noiseDB: -30, seed: 7)  // about 10 dB SNR
        let reference = SynthVoice.highPassed(clean)
        let before = SynthVoice.snr(noisy, reference: reference)
        var gains: [VoiceProcessingLevel: Float] = [:]
        for level in [VoiceProcessingLevel.light, .standard, .strong] {
            let out = VoiceEnhancer.enhance(noisy, level: level)
            gains[level] = SynthVoice.snr(out, reference: reference) - before
        }
        print("SNR before \(before) gains \(gains)")
        #expect(gains[.light]! > 6.0)
        #expect(gains[.standard]! > 8.0)
        #expect(gains[.strong]! > 8.0)
        #expect(gains[.strong]! >= gains[.light]!)
    }

    @Test func noisierInputGainsAtLowSNR() {
        let clean = SynthVoice.speech(seconds: 20, rmsDB: -20)
        let noisy = SynthVoice.mix(clean, noiseDB: -22, seed: 3)  // about 2 dB SNR
        let reference = SynthVoice.highPassed(clean)
        let before = SynthVoice.snr(noisy, reference: reference)
        let after = SynthVoice.snr(VoiceEnhancer.enhance(noisy, level: .standard), reference: reference)
        print("low SNR \(before) -> \(after)")
        #expect(after - before > 3.0)
    }

    @Test func cleanSignalIsNotDegraded() {
        let clean = SynthVoice.speech(seconds: 20, rmsDB: -20)
        let withFloor = SynthVoice.mix(clean, noiseDB: -75, seed: 5)  // very clean recording
        for level in [VoiceProcessingLevel.light, .standard, .strong] {
            var parameters = VoiceEnhancer.Parameters.forLevel(level)!
            parameters.highPassHz = 0  // judged without the intended high-pass phase shift
            let enhancer = VoiceEnhancer(parameters: parameters)
            let out = enhancer.process(withFloor) + enhancer.finish()
            let sdr = SynthVoice.snr(out, reference: withFloor)
            print("clean \(level) sdr \(sdr)")
            #expect(sdr > 25, "\(level) changed a clean signal too much (\(sdr) dB)")
            #expect(abs(SynthVoice.rmsDB(out) - SynthVoice.rmsDB(withFloor)) < 0.5)
        }
    }

    @Test func chunkedEqualsWhole() {
        let clean = SynthVoice.speech(seconds: 12, rmsDB: -28)
        let noisy = SynthVoice.mix(clean, noiseDB: -35, seed: 11)
        for level in [VoiceProcessingLevel.light, .standard, .strong] {
            let whole = VoiceEnhancer.enhance(noisy, level: level)
            let pieces = SynthVoice.chunked(noisy, sizes: [1, 7, 255, 256, 257, 4_000, 30 * 16_000, 513], level: level)
            #expect(pieces.count == whole.count)
            #expect(pieces == whole, "\(level): chunk boundaries must not change the output")
        }
    }

    @Test func silenceStaysSilent() {
        let zeros = [Float](repeating: 0, count: 16_000 * 3)
        for level in [VoiceProcessingLevel.light, .standard, .strong] {
            let out = VoiceEnhancer.enhance(zeros, level: level)
            #expect(out.count == zeros.count)
            #expect(out.allSatisfy { $0 == 0 })
        }
    }

    @Test func loudnessApproachesTarget() {
        let quiet = SynthVoice.speech(seconds: 20, rmsDB: -33)
        let out = VoiceEnhancer.enhance(quiet, level: .standard)
        // Measure after the AGC has settled.
        let settled = Array(out.dropFirst(16_000 * 8))
        let level = SynthVoice.rmsDB(settled)
        print("loudness \(level)")
        #expect(abs(level - (-20)) < 3.0)
        let loud = SynthVoice.speech(seconds: 20, rmsDB: -8)
        let louder = Array(VoiceEnhancer.enhance(loud, level: .standard).dropFirst(16_000 * 8))
        #expect(abs(SynthVoice.rmsDB(louder) - (-20)) < 2.5)
    }

    @Test func boostIsCappedPerLevel() {
        let veryQuiet = SynthVoice.speech(seconds: 15, rmsDB: -50)
        let light = Array(VoiceEnhancer.enhance(veryQuiet, level: .light).dropFirst(16_000 * 8))
        #expect(SynthVoice.rmsDB(light) < -50 + 9.6)
    }

    @Test func peaksStayBelowFullScale() {
        var loud = SynthVoice.speech(seconds: 6, rmsDB: -6)
        loud = loud.map { $0 * 3 }  // hard over-driven input
        for level in [VoiceProcessingLevel.light, .standard, .strong] {
            let out = VoiceEnhancer.enhance(loud.map { max(-1, min(1, $0)) }, level: level)
            #expect(out.allSatisfy { abs($0) <= 1 })
        }
    }

    @Test func noNaNOrInfinityEvenForHostileInput() {
        var x = SynthVoice.noise(count: 20_000)
        x[10] = .nan
        x[500] = .infinity
        x[900] = -.infinity
        x[3000] = 1e30
        for level in [VoiceProcessingLevel.light, .standard, .strong] {
            let out = VoiceEnhancer.enhance(x, level: level)
            #expect(out.count == x.count)
            #expect(out.allSatisfy { $0.isFinite })
        }
    }

    @Test func deClickRemovesIsolatedSpikesInStrongOnly() {
        var x = SynthVoice.speech(seconds: 4, rmsDB: -22)
        let spikes = [20_000, 30_001, 41_234]
        for s in spikes { x[s] += 0.6 }
        let strong = VoiceEnhancer.enhance(x, level: .strong)
        let standard = VoiceEnhancer.enhance(x, level: .standard)
        for s in spikes {
            let around = (s - 3)...(s + 3)
            let strongPeak = around.map { abs(strong[$0]) }.max()!
            let standardPeak = around.map { abs(standard[$0]) }.max()!
            #expect(strongPeak < standardPeak * 0.7, "spike at \(s): \(strongPeak) vs \(standardPeak)")
        }
    }

    @Test("strong enhancement exceeds 20x real time in the optimized build", .enabled(if: optimizedEnhancerBuild))
    func fasterThanRealtime() {
        let x = SynthVoice.mix(SynthVoice.speech(seconds: 60, rmsDB: -22), noiseDB: -35)
        let start = ContinuousClock.now
        let out = VoiceEnhancer.enhance(x, level: .strong)
        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let factor = 60 / seconds
        print("realtime factor \(factor)")
        #expect(out.count == x.count)
        #expect(factor > 20)
    }

    @Test func deterministic() {
        let x = SynthVoice.mix(SynthVoice.speech(seconds: 5, rmsDB: -25), noiseDB: -32, seed: 9)
        #expect(VoiceEnhancer.enhance(x, level: .standard) == VoiceEnhancer.enhance(x, level: .standard))
    }
}
