import AVFoundation
import AppCore
import Darwin
import Foundation
import OSLog

/// The four output channels of a live source. Created at source init so `levels`/`health` can be read before `start()`.
final class CaptureChannels: Sendable {
    let chunks: AsyncStream<AudioChunk>
    let levels: AsyncStream<Float>
    let health: AsyncStream<AudioSourceHealth>
    let errors: AsyncStream<AppError>
    let chunkContinuation: AsyncStream<AudioChunk>.Continuation
    let levelContinuation: AsyncStream<Float>.Continuation
    let healthContinuation: AsyncStream<AudioSourceHealth>.Continuation
    let errorContinuation: AsyncStream<AppError>.Continuation

    init(chunkBufferCount: Int) {
        (chunks, chunkContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(max(1, chunkBufferCount)))
        (levels, levelContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(4))
        (health, healthContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
        (errors, errorContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
    }

    func finish() {
        chunkContinuation.finish()
        levelContinuation.finish()
        healthContinuation.finish()
        errorContinuation.finish()
    }
}

/// Converts mach host ticks to seconds and back.
enum HostClock {
    static let ticksPerSecond: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return 1e9 * Double(info.denom) / Double(info.numer)
    }()
}

/// Consumer half of a live source. An actor so restart, drain and stop are serialised.
///
/// Data path: backend RT callback -> ``AudioRenderSink`` (mono downmix, lock-free ring) -> `pump()` on a normal task
/// (zero detection, resample to 16 kHz, level meter, chunking) -> bounded `AsyncStream`. Nothing here is on the RT thread.
actor CaptureSession {
    private static let log = Logger(subsystem: "app.earmark", category: "AudioCapture")
    private static let targetRate = AudioChunk.sampleRate

    private let tag: AudioSourceTag
    private let config: CaptureConfiguration
    private let channels: CaptureChannels
    private let sink: AudioRenderSink
    private var backend: (any AudioCaptureBackend)?
    private var pumpTask: Task<Void, Never>?

    private var running = false
    private var stopped = false
    private var restarting = false

    private var nativeRate = 16_000.0
    private var converter: AVAudioConverter?
    private var readBuffer = [Float](repeating: 0, count: 16_384)
    private var pending: [Float] = []
    private var producedSamples = 0
    private var emittedSamples = 0
    private var anchor: (host: UInt64, sampleIndex: Int)?

    private var zeroRun = 0
    private var silentFlagged = false
    private var levelSumSquares: Float = 0
    private var levelCount = 0

    private var droppedChunks = 0
    private var emittedChunks = 0

    init(tag: AudioSourceTag, config: CaptureConfiguration, channels: CaptureChannels) {
        self.tag = tag
        self.config = config
        self.channels = channels
        sink = AudioRenderSink(ringCapacity: Int(192_000 * max(0.25, config.ringSeconds)))
    }

    var isRunning: Bool { running && !stopped }

    func metrics() -> CaptureMetrics {
        CaptureMetrics(ringDroppedSamples: sink.ring.droppedCount, droppedChunks: droppedChunks, emittedChunks: emittedChunks)
    }

    // MARK: Lifecycle

    /// Starts `backend` and the consumer task. Throws the backend's `AppError` (nothing is left running on failure).
    func begin(backend: any AudioCaptureBackend, deviceUID: String?) async throws {
        guard !stopped, !running else { throw AppError.deviceUnavailable }
        sink.resetAnchor()
        let format = try await backend.start(deviceUID: deviceUID, sink: sink)
        guard !stopped else {
            await backend.stop()
            throw AppError.cancelled
        }
        do {
            try configure(format)
        } catch {
            await backend.stop()
            throw error
        }
        self.backend = backend
        running = true
        channels.healthContinuation.yield(.running)
        let interval = config.pollInterval
        pumpTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pump()
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Tears down and re-creates the backend stream (hot-plug / route change) without ending the session. The chunk
    /// timeline (`startSeconds`) continues across the restart.
    func restart(deviceUID: String?) async throws {
        guard running, !stopped, let backend else { throw AppError.deviceUnavailable }
        restarting = true
        defer { restarting = false }
        await backend.stop()
        drainRing()
        sink.resetAnchor()
        anchor = nil
        zeroRun = 0
        let format = try await backend.start(deviceUID: deviceUID, sink: sink)
        guard !stopped else {
            await backend.stop()
            return
        }
        try configure(format)
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        pumpTask?.cancel()
        pumpTask = nil
        await backend?.stop()
        backend = nil
        if running {
            drainRing()
            if !pending.isEmpty {
                emit(pending)
                pending.removeAll()
            }
        }
        running = false
        channels.healthContinuation.yield(.stopped)
        channels.finish()
    }

    // MARK: Consumer

    private func configure(_ format: CaptureFormat) throws {
        nativeRate = format.sampleRate
        if abs(format.sampleRate - Self.targetRate) < 0.5 {
            converter = nil
            return
        }
        guard
            let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false),
            let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.targetRate, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: input, to: output)
        else { throw AppError.deviceUnavailable }
        self.converter = converter
    }

    func pump() {
        guard running, !stopped, !restarting else { return }
        drainRing()
    }

    private func drainRing() {
        while true {
            let count = readBuffer.withUnsafeMutableBufferPointer { sink.ring.read(into: $0) }
            if count == 0 { return }
            process(count)
        }
    }

    private func process(_ count: Int) {
        if anchor == nil {
            let host = sink.firstHostTime
            if host != 0 { anchor = (host, producedSamples) }
        }
        trackSilence(count)
        let output = resample(count)
        guard !output.isEmpty else { return }
        producedSamples += output.count
        updateLevel(output)
        pending.append(contentsOf: output)
        let chunkSize = max(1, Int(config.chunkSeconds * Self.targetRate))
        while pending.count >= chunkSize {
            emit(Array(pending.prefix(chunkSize)))
            pending.removeFirst(chunkSize)
        }
    }

    private func trackSilence(_ count: Int) {
        let threshold = config.silenceThreshold
        var sawSignal = false
        readBuffer.withUnsafeBufferPointer { buffer in
            for index in 0..<count {
                if buffer[index].magnitude <= threshold {
                    zeroRun += 1
                } else {
                    zeroRun = 0
                    sawSignal = true
                }
            }
        }
        let windowSamples = Int(config.silenceWindowSeconds * nativeRate)
        if !silentFlagged, zeroRun >= windowSamples {
            silentFlagged = true
            channels.healthContinuation.yield(.silent)
            channels.errorContinuation.yield(
                .captureSilent(
                    reason: "Only silence for \(Int(config.silenceWindowSeconds)) s: check the audio recording permission"))
            Self.log.notice("capture silent for \(self.config.silenceWindowSeconds, privacy: .public) s (possible TCC denial)")
        } else if silentFlagged, sawSignal {
            silentFlagged = false
            channels.healthContinuation.yield(.running)
        }
    }

    private func resample(_ count: Int) -> [Float] {
        guard let converter else { return Array(readBuffer[0..<count]) }
        guard let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(count)),
            let data = input.floatChannelData
        else { return [] }
        input.frameLength = AVAudioFrameCount(count)
        readBuffer.withUnsafeBufferPointer { data[0].update(from: $0.baseAddress!, count: count) }
        let capacity = AVAudioFrameCount(Double(count) * Self.targetRate / nativeRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return [] }
        let supplied = SuppliedFlag()
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied.value {
                status.pointee = .noDataNow
                return nil
            }
            supplied.value = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, let out = output.floatChannelData, output.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: out[0], count: Int(output.frameLength)))
    }

    private func updateLevel(_ samples: [Float]) {
        let block = max(1, Int(config.levelIntervalSeconds * Self.targetRate))
        for sample in samples {
            levelSumSquares += sample * sample
            levelCount += 1
            if levelCount >= block {
                let rms = (levelSumSquares / Float(levelCount)).squareRoot()
                levelCount = 0
                levelSumSquares = 0
                channels.levelContinuation.yield(Self.meterLevel(rms: rms))
            }
        }
    }

    /// Maps RMS amplitude to a 0...1 meter value on a 60 dB scale.
    static func meterLevel(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        return min(1, max(0, (20 * log10(rms) + 60) / 60))
    }

    private func emit(_ samples: [Float]) {
        let startIndex = emittedSamples
        emittedSamples += samples.count
        var hostTime: UInt64 = 0
        if let anchor {
            let deltaSeconds = Double(startIndex - anchor.sampleIndex) / Self.targetRate
            let ticks = deltaSeconds * HostClock.ticksPerSecond
            hostTime = ticks >= 0 ? anchor.host &+ UInt64(ticks) : anchor.host &- min(anchor.host, UInt64(-ticks))
        }
        let chunk = AudioChunk(samples: samples, hostTime: hostTime, startSeconds: Double(startIndex) / Self.targetRate, source: tag)
        emittedChunks += 1
        if case .dropped = channels.chunkContinuation.yield(chunk) {
            droppedChunks += 1
            Self.log.notice("chunk stream full: dropped oldest chunk (total \(self.droppedChunks, privacy: .public))")
        }
    }
}

/// Mutable flag for the converter's input block, which may not capture a `var`.
private final class SuppliedFlag: @unchecked Sendable {
    var value = false
}
