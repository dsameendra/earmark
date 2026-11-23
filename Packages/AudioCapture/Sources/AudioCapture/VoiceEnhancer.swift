import Accelerate
import AppCore
import Foundation

/// Offline speech enhancement for 16 kHz mono Float32 audio (SCR-014).
///
/// Apple's VoiceProcessingIO only exists for live microphone I/O, so this is a small, deterministic, causal chain built on
/// Accelerate that can run over decoded files:
///
/// 1. optional de-click (single-sample spikes, ``VoiceProcessingLevel/strong`` only),
/// 2. high-pass filter (2nd-order Butterworth, 80 Hz, so it shifts the phase of the lowest voice harmonics a little) against rumble and handling noise,
/// 3. STFT noise reduction (512-sample periodic sqrt-Hann frames, hop 256): a per-bin noise floor from minimum statistics
///    (the quietest recent frames), decision-directed Wiener gains with over-estimation and a per-level floor against musical
///    noise, and a **skip-if-clean bypass**: the gains are crossfaded to 1 as the estimated SNR rises above the level's
///    threshold, so clean recordings pass through,
/// 4. a slow speech-gated automatic gain control towards about -20 dBFS speech RMS (boost capped per level, never past a peak
///    ceiling, with a dead band so already well-levelled audio is untouched) and a soft limiter above -1 dBFS.
///
/// The output has exactly as many samples as the input and the same timing (no stretching); the stream is delayed by 256
/// samples internally and ``finish()`` flushes the tail. Everything is causal and sample-streaming, so the result depends only
/// on the concatenated input and never on how it is split into ``process(_:)`` calls. Memory is constant (a few KB).
///
/// Not `Sendable`: it owns an FFT setup and mutable state; keep one instance inside one task or actor.
public final class VoiceEnhancer {
    /// Tunables derived from a ``VoiceProcessingLevel``.
    public struct Parameters: Sendable, Equatable {
        /// Lowest per-bin amplitude gain (limits suppression and musical noise).
        public var gainFloor: Float
        /// Noise-estimate over-subtraction factor.
        public var overEstimate: Float
        /// Largest AGC boost in dB.
        public var maxBoostDB: Float
        /// Largest AGC cut in dB.
        public var maxCutDB: Float = 12
        /// At or above this estimated SNR (dB) noise reduction is bypassed.
        public var bypassSNR: Float
        /// At or below this estimated SNR (dB) noise reduction is fully applied.
        public var fullSNR: Float
        public var declick: Bool
        /// Target speech RMS in dBFS.
        public var targetDB: Float = -20
        /// High-pass cutoff in Hz; 0 disables the filter.
        public var highPassHz: Float = 80

        public static func forLevel(_ level: VoiceProcessingLevel) -> Parameters? {
            switch level {
            case .off: nil
            case .light: Parameters(gainFloor: 0.35, overEstimate: 1.0, maxBoostDB: 9, bypassSNR: 32, fullSNR: 24, declick: false)
            case .standard: Parameters(gainFloor: 0.18, overEstimate: 1.3, maxBoostDB: 15, bypassSNR: 38, fullSNR: 28, declick: false)
            case .strong: Parameters(gainFloor: 0.08, overEstimate: 1.8, maxBoostDB: 20, bypassSNR: 45, fullSNR: 32, declick: true)
            }
        }
    }

    static let frameSize = 512
    static let hopSize = 256
    static let bins = 257
    /// Frames per minimum-statistics sub-window and number of sub-windows kept (about 2.3 s of history).
    private static let subWindowFrames = 24
    private static let subWindowCount = 6
    /// A running minimum of smoothed power under-estimates the mean noise power; this compensates.
    private static let noiseBias: Float = 1.6
    private static let hopSubWindow = 16
    private static let hopSubCount = 12
    private static let sampleRate: Float = 16_000

    private let parameters: Parameters?

    // High-pass biquad (transposed direct form II, Double).
    private var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var z1 = 0.0, z2 = 0.0

    // De-click delay line.
    private var clickCount = 0
    private var clickA: Float = 0
    private var clickB: Float = 0
    private var clickEnv: Float = 0

    // Hop assembly and bookkeeping.
    private let hopBuffer: UnsafeMutablePointer<Float>
    private var hopFill = 0
    private var inputCount = 0
    private var emitted = 0
    private var skipRemaining = VoiceEnhancer.hopSize
    private var output: [Float] = []
    private var frameIndex = 0

    // STFT workspace.
    private let fftSetup: FFTSetup
    private let window: UnsafeMutablePointer<Float>
    private let history: UnsafeMutablePointer<Float>
    private let frame: UnsafeMutablePointer<Float>
    private let real: UnsafeMutablePointer<Float>
    private let imag: UnsafeMutablePointer<Float>
    private let overlap: UnsafeMutablePointer<Float>
    private let finalized: UnsafeMutablePointer<Float>
    private let power: UnsafeMutablePointer<Float>
    private let smoothed: UnsafeMutablePointer<Float>
    private let subMin: UnsafeMutablePointer<Float>
    private let minHistory: UnsafeMutablePointer<Float>
    private let noise: UnsafeMutablePointer<Float>
    private let prevClean: UnsafeMutablePointer<Float>
    private var subFrames = 0
    private var historyPos = 0
    private var historyCount = 0

    // Hop-domain trackers (noise level, speech level, AGC).
    private var smoothedHopPower: Float = 0
    private var hopSubMin: Float = 0
    private var hopSubFrames = 0
    private var hopHistory = [Float](repeating: 0, count: VoiceEnhancer.hopSubCount)
    private var hopHistoryPos = 0
    private var hopHistoryCount = 0
    private var speechPower: Float = 0
    private var haveSpeech = false
    private var levelPower: Float = 0
    private var haveLevel = false
    private var levelHops = 0
    private var peakEnvelope: Float = 0
    private var gainDB: Float = 0
    private var bypassMix: Float = 1

    /// Estimated speech-to-noise ratio in dB (0 until speech has been seen). Exposed for diagnostics and tests.
    public private(set) var estimatedSNR: Float = 0

    /// The tracked active-speech level in dBFS (nil until speech has been seen). Diagnostics and tests.
    public var estimatedSpeechLevelDB: Float? { haveLevel ? 10 * log10(max(levelPower, 1e-12)) : nil }

    /// Creates an enhancer. `.off` makes it a pass-through.
    public convenience init(level: VoiceProcessingLevel) {
        self.init(parameters: Parameters.forLevel(level))
    }

    /// Creates an enhancer with explicit parameters (`nil` is a pass-through).
    public init(parameters: Parameters?) {
        self.parameters = parameters
        let n = Self.frameSize, h = Self.hopSize, b = Self.bins
        func alloc(_ count: Int) -> UnsafeMutablePointer<Float> {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: count)
            pointer.initialize(repeating: 0, count: count)
            return pointer
        }
        hopBuffer = alloc(h)
        window = alloc(n)
        history = alloc(n)
        frame = alloc(n)
        real = alloc(h)
        imag = alloc(h)
        overlap = alloc(h)
        finalized = alloc(h)
        power = alloc(b)
        smoothed = alloc(b)
        subMin = alloc(b)
        minHistory = alloc(b * Self.subWindowCount)
        noise = alloc(b)
        prevClean = alloc(b)
        fftSetup = vDSP_create_fftsetup(9, FFTRadix(kFFTRadix2))!
        // Periodic sqrt-Hann: analysis and synthesis windows whose squares sum to 1 at hop N/2.
        for i in 0..<n { window[i] = Float(sin(Double.pi * Double(i) / Double(n))) }
        // Butterworth high-pass (80 Hz by default).
        if let cutoff = parameters?.highPassHz, cutoff > 0 {
            let w0 = 2 * Double.pi * Double(cutoff) / Double(Self.sampleRate)
            let alpha = sin(w0) / (2 * 0.70710678)
            let a0 = 1 + alpha
            b0 = (1 + cos(w0)) / 2 / a0
            b1 = -(1 + cos(w0)) / a0
            b2 = b0
            a1 = -2 * cos(w0) / a0
            a2 = (1 - alpha) / a0
        } else {
            b0 = 1
        }
    }

    deinit {
        for pointer in [
            hopBuffer, window, history, frame, real, imag, overlap, finalized, power, smoothed, subMin, minHistory, noise, prevClean,
        ] { pointer.deallocate() }
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Enhances a whole buffer in one go (equivalent to `process` then `finish`).
    public static func enhance(_ samples: [Float], level: VoiceProcessingLevel) -> [Float] {
        let enhancer = VoiceEnhancer(level: level)
        return enhancer.process(samples) + enhancer.finish()
    }

    // MARK: - Streaming API

    /// Feeds samples and returns the output that is ready (about 256 samples behind the input). Non-finite samples read as 0.
    public func process(_ input: [Float]) -> [Float] {
        guard parameters != nil else { return input }
        inputCount += input.count
        for sample in input { feed(sample.isFinite ? sample : 0) }
        let ready = output
        output.removeAll(keepingCapacity: true)
        emitted += ready.count
        return ready
    }

    /// Flushes the tail so that the total output length equals the total input length. The enhancer should not be reused.
    public func finish() -> [Float] {
        guard parameters != nil else { return [] }
        if clickCount >= 1 { emit(clickB) }
        clickCount = 0
        if hopFill > 0 {
            while hopFill < Self.hopSize {
                hopBuffer[hopFill] = 0
                hopFill += 1
            }
            processHop()
        }
        // One more hop completes the overlap-add of the last real frame.
        for i in 0..<Self.hopSize { hopBuffer[i] = 0 }
        processHop()
        var tail = output
        output.removeAll(keepingCapacity: true)
        let allowed = max(0, inputCount - emitted)
        if tail.count > allowed { tail.removeLast(tail.count - allowed) }
        emitted += tail.count
        return tail
    }

    // MARK: - Pre-stage: de-click and high-pass

    private func feed(_ sample: Float) {
        guard parameters?.declick == true else {
            emit(sample)
            return
        }
        // One-sample delay line: judge the middle sample against its neighbours.
        switch clickCount {
        case 0:
            clickB = sample
            clickCount = 1
        case 1:
            clickA = clickB
            clickB = sample
            clickCount = 2
            emit(clickA)
        default:
            let predicted = (clickA + sample) / 2
            let deviation = abs(clickB - predicted)
            var middle = clickB
            if deviation > 0.04, deviation > 12 * clickEnv { middle = predicted }  // isolated spike: interpolate
            clickEnv = 0.999 * clickEnv + 0.001 * deviation
            clickA = middle
            clickB = sample
            emit(middle)
        }
    }

    private func emit(_ sample: Float) {
        let x = Double(sample)
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        hopBuffer[hopFill] = Float(y)
        hopFill += 1
        if hopFill == Self.hopSize {
            processHop()
            hopFill = 0
        }
    }

    // MARK: - One hop

    private func processHop() {
        guard let p = parameters else { return }
        let h = Self.hopSize, n = Self.frameSize, bins = Self.bins

        // Hop statistics: level, peak and noise floor in the time domain.
        var hopPower: Float = 0
        vDSP_measqv(hopBuffer, 1, &hopPower, vDSP_Length(h))
        var peak: Float = 0
        vDSP_maxmgv(hopBuffer, 1, &peak, vDSP_Length(h))
        let first = frameIndex == 0
        smoothedHopPower = hopPower  // 256 samples already give a stable power estimate; smoothing would hide short pauses
        if first { hopSubMin = smoothedHopPower } else { hopSubMin = min(hopSubMin, smoothedHopPower) }
        hopSubFrames += 1
        if hopSubFrames == Self.hopSubWindow {
            hopHistory[hopHistoryPos] = hopSubMin
            hopHistoryPos = (hopHistoryPos + 1) % Self.hopSubCount
            hopHistoryCount = min(hopHistoryCount + 1, Self.hopSubCount)
            hopSubMin = smoothedHopPower
            hopSubFrames = 0
        }
        var hopFloor = hopSubMin
        for i in 0..<hopHistoryCount { hopFloor = min(hopFloor, hopHistory[i]) }
        let noiseHop = max(hopFloor * 1.3, 1e-12)
        let active = hopPower > 1e-5 && hopPower > 3 * noiseHop
        if active {
            speechPower = haveSpeech ? 0.98 * speechPower + 0.02 * hopPower : hopPower
            haveSpeech = true
            // Speech power with the noise power removed, smoothed in the power domain (quick to rise, slow to fall).
            // Only hops within 20 dB of the running level count, like an active-speech level meter, so soft onsets, decays and
            // breaths do not drag the estimate down.
            let clean = max(hopPower - noiseHop, 0.1 * hopPower)
            if haveLevel, hopPower < 0.01 * levelPower {
                // too soft to be speech at this level
            } else if !haveLevel {
                levelPower = clean
                haveLevel = true
                levelHops = 1
            } else if levelHops < 24 {
                // Start-up: a plain running mean, so the first soft hops cannot swing the gain.
                levelHops += 1
                levelPower += (clean - levelPower) / Float(levelHops)
            } else if clean > levelPower {
                levelPower += 0.05 * (clean - levelPower)
            } else {
                levelPower += 0.02 * (clean - levelPower)
            }
        }
        peakEnvelope = max(peak, peakEnvelope * 0.98)
        estimatedSNR = haveSpeech ? 10 * log10(max(speechPower, 1e-12) / noiseHop) : 0
        let span = max(p.bypassSNR - p.fullSNR, 1)
        let wanted = min(1, max(0, (p.bypassSNR - estimatedSNR) / span))
        bypassMix += 0.05 * (wanted - bypassMix)
        // Warm-up: the noise floor is not trustworthy for the first half second, so start dry.
        let wet = bypassMix * min(1, Float(frameIndex) / 32)

        // STFT analysis.
        for i in 0..<(n - h) { history[i] = history[i + h] }
        for i in 0..<h { history[n - h + i] = hopBuffer[i] }
        vDSP_vmul(history, 1, window, 1, frame, 1, vDSP_Length(n))
        var split = DSPSplitComplex(realp: real, imagp: imag)
        frame.withMemoryRebound(to: DSPComplex.self, capacity: h) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(h)) }
        vDSP_fft_zrip(fftSetup, &split, 1, 9, FFTDirection(FFT_FORWARD))

        power[0] = real[0] * real[0]
        power[bins - 1] = imag[0] * imag[0]
        for k in 1..<(bins - 1) { power[k] = real[k] * real[k] + imag[k] * imag[k] }

        // Noise floor per bin: minimum of smoothed power over recent sub-windows.
        for k in 0..<bins {
            smoothed[k] = first ? power[k] : 0.7 * smoothed[k] + 0.3 * power[k]
            subMin[k] = first ? smoothed[k] : min(subMin[k], smoothed[k])
        }
        subFrames += 1
        if subFrames == Self.subWindowFrames {
            for k in 0..<bins { minHistory[historyPos * bins + k] = subMin[k] }
            historyPos = (historyPos + 1) % Self.subWindowCount
            historyCount = min(historyCount + 1, Self.subWindowCount)
            for k in 0..<bins { subMin[k] = smoothed[k] }
            subFrames = 0
        }
        let scale = Self.noiseBias * p.overEstimate
        let alphaDD: Float = 0.92
        for k in 0..<bins {
            var floorPower = subMin[k]
            for u in 0..<historyCount { floorPower = min(floorPower, minHistory[u * bins + k]) }
            let n_k = max(floorPower * scale, 1e-12)
            noise[k] = n_k
            let gamma = power[k] / n_k
            let xi = alphaDD * prevClean[k] + (1 - alphaDD) * max(gamma - 1, 0)
            let gain = max(p.gainFloor, xi / (1 + xi))
            prevClean[k] = gain * gain * gamma
            // Skip-if-clean: crossfade the gain to 1 as the estimated SNR rises.
            let applied = 1 - wet * (1 - gain)
            if k == 0 {
                real[0] *= applied
            } else if k == bins - 1 {
                imag[0] *= applied
            } else {
                real[k] *= applied
                imag[k] *= applied
            }
        }

        // Synthesis and overlap-add. The forward real FFT is scaled by 2 and the inverse is unscaled, hence 1 / (2 N).
        vDSP_fft_zrip(fftSetup, &split, 1, 9, FFTDirection(FFT_INVERSE))
        frame.withMemoryRebound(to: DSPComplex.self, capacity: h) { vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(h)) }
        var norm = 1 / Float(2 * n)
        vDSP_vsmul(frame, 1, &norm, frame, 1, vDSP_Length(n))
        vDSP_vmul(frame, 1, window, 1, frame, 1, vDSP_Length(n))
        for i in 0..<h {
            finalized[i] = overlap[i] + frame[i]
            overlap[i] = frame[h + i]
        }
        frameIndex += 1

        // Gain control and limiter on the finalized hop.
        var targetDB: Float = 0
        if haveLevel, levelHops >= 24 {
            let error = p.targetDB - 10 * log10(max(levelPower, 1e-12))
            let dead: Float = 1.0
            var wantedDB = error > dead ? error - dead : (error < -dead ? error + dead : 0)
            wantedDB = min(max(wantedDB, -p.maxCutDB), p.maxBoostDB)
            if wantedDB > 0, peakEnvelope > 1e-4 {
                let headroom = 20 * log10(0.89 / peakEnvelope)  // keep boosted peaks under the ceiling
                wantedDB = min(wantedDB, max(headroom, 0))
            }
            targetDB = wantedDB
        }
        let previousGain = pow(10, gainDB / 20)
        gainDB += min(max(targetDB - gainDB, -1.0), 0.5)
        let currentGain = pow(10, gainDB / 20)
        var out = [Float](repeating: 0, count: h)
        let knee: Float = 0.89
        for i in 0..<h {
            let g = previousGain + (currentGain - previousGain) * Float(i + 1) / Float(h)
            var y = finalized[i] * g
            let magnitude = abs(y)
            if magnitude > knee { y = (y < 0 ? -1 : 1) * (knee + (1 - knee) * tanh((magnitude - knee) / (1 - knee))) }
            out[i] = y
        }
        if skipRemaining > 0 {
            let drop = min(skipRemaining, h)
            skipRemaining -= drop
            output.append(contentsOf: out[drop...])
        } else {
            output.append(contentsOf: out)
        }
    }
}
