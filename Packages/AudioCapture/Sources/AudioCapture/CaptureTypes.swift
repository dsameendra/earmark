import AppCore
import AudioToolbox
import Foundation
import Synchronization

// MARK: - Configuration

/// Tunables shared by every live source. All values have production defaults; tests shrink them.
public struct CaptureConfiguration: Sendable, Equatable {
    /// Length of each yielded ``AudioChunk`` in seconds.
    public var chunkSeconds: TimeInterval
    /// Continuous all-zero audio for this long raises `.silent` + `AppError.captureSilent` (AUD-AC-04: 3 s).
    public var silenceWindowSeconds: TimeInterval
    /// Samples with `abs(x) <= threshold` count as silent. Silent TCC denial yields exact zeros, so the default is 0.
    public var silenceThreshold: Float
    /// Level meter update interval in seconds (AUD-AC-08: at least 15 Hz, so 50 ms gives 20 Hz).
    public var levelIntervalSeconds: TimeInterval
    /// Capacity of the lock-free hand-off buffer in seconds of (up to 192 kHz mono) audio.
    public var ringSeconds: Double
    /// `bufferingNewest` depth of the chunk stream.
    public var chunkBufferCount: Int
    /// Consumer poll interval. The consumer is a normal task; the real-time producer never waits on it.
    public var pollInterval: Duration

    public init(
        chunkSeconds: TimeInterval = 0.1, silenceWindowSeconds: TimeInterval = 3, silenceThreshold: Float = 0,
        levelIntervalSeconds: TimeInterval = 0.05, ringSeconds: Double = 2, chunkBufferCount: Int = 64,
        pollInterval: Duration = .milliseconds(10)
    ) {
        self.chunkSeconds = chunkSeconds
        self.silenceWindowSeconds = silenceWindowSeconds
        self.silenceThreshold = silenceThreshold
        self.levelIntervalSeconds = levelIntervalSeconds
        self.ringSeconds = ringSeconds
        self.chunkBufferCount = chunkBufferCount
        self.pollInterval = pollInterval
    }
}

/// Counters for the "drop oldest and log a metric" requirement.
public struct CaptureMetrics: Sendable, Equatable {
    /// Samples the real-time producer had to reject because the ring was full.
    public var ringDroppedSamples: Int
    /// Chunks the bounded stream dropped because the consumer was slow.
    public var droppedChunks: Int
    public var emittedChunks: Int
}

/// A source that, besides the `AudioSource` surface, reports typed errors (e.g. `AppError.captureSilent`).
public protocol ErrorReportingAudioSource: AudioSource {
    /// Errors raised while capturing (`captureSilent`, `deviceUnavailable`). Does not end the session by itself.
    var errors: AsyncStream<AppError> { get }
}

// MARK: - Backend seam

public struct CaptureFormat: Sendable, Equatable {
    /// Native sample rate of the mono downmix the backend feeds to the sink.
    public var sampleRate: Double
    public init(sampleRate: Double) { self.sampleRate = sampleRate }
}

public enum AudioBackendEvent: Sendable, Equatable {
    /// The hardware configuration changed underneath the backend (engine config change, output device switch); restart.
    case configurationChanged
    case failed(reason: String)
}

/// The hardware-facing half of a source. Everything above this protocol (ring hand-off, resampling, chunking, level
/// meters, silence detection, hot-plug policy) is deterministic and unit-tested with ``ScriptedCaptureBackend``.
///
/// Calls to `start`/`stop` are serialised by the owning session. The backend feeds audio from its real-time thread
/// through the ``AudioRenderSink``.
public protocol AudioCaptureBackend: Sendable {
    /// Short identifier for diagnostics (`"avAudioEngine"`, `"processTap"`, `"screenCaptureKit"`).
    var name: String { get }
    /// Starts delivering to `sink`. `deviceUID` nil means "system default". Throws `AppError`.
    func start(deviceUID: String?, sink: AudioRenderSink) async throws -> CaptureFormat
    func stop() async
    /// Single-consumer stream of hardware events.
    var events: AsyncStream<AudioBackendEvent> { get }
}

// MARK: - Render sink (real-time producer side)

/// Real-time entry point. Every `deliver` method is allocation-free, lock-free and wait-free: it downmixes into a
/// preallocated scratch buffer and writes to the SPSC ring. Call from exactly one thread at a time.
public final class AudioRenderSink: @unchecked Sendable {
    static let scratchFrames = 8192
    let ring: RingBuffer<Float>
    private let scratch: UnsafeMutablePointer<Float>
    private let firstHost = Atomic<UInt64>(0)
    private let blocks = Atomic<Int>(0)

    init(ringCapacity: Int) {
        ring = RingBuffer<Float>(minimumCapacity: ringCapacity)
        scratch = .allocate(capacity: Self.scratchFrames)
        scratch.initialize(repeating: 0, count: Self.scratchFrames)
    }

    deinit { scratch.deallocate() }

    /// Number of blocks delivered so far.
    public var deliveredBlocks: Int { blocks.load(ordering: .relaxed) }

    /// Host time (`mach_absolute_time` units) of the first block since the last reset, or 0.
    var firstHostTime: UInt64 { firstHost.load(ordering: .acquiring) }

    func resetAnchor() { firstHost.store(0, ordering: .releasing) }

    /// Delivers an `AudioBufferList` of Float32 data (interleaved and/or one buffer per channel); all channels are averaged.
    public func deliver(audioBufferList list: UnsafePointer<AudioBufferList>, hostTime: UInt64) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        var totalChannels = 0
        var frames = Int.max
        for buffer in buffers {
            let channels = Int(buffer.mNumberChannels)
            guard buffer.mData != nil, channels > 0 else { continue }
            totalChannels += channels
            frames = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels))
        }
        guard totalChannels > 0, frames > 0, frames != Int.max else { return }
        let scale = 1 / Float(totalChannels)
        var offset = 0
        while offset < frames {
            let count = min(Self.scratchFrames, frames - offset)
            scratch.update(repeating: 0, count: count)
            for buffer in buffers {
                let channels = Int(buffer.mNumberChannels)
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self), channels > 0 else { continue }
                for frame in 0..<count {
                    var sum: Float = 0
                    let base = (offset + frame) * channels
                    for channel in 0..<channels { sum += data[base + channel] }
                    scratch[frame] += sum
                }
            }
            for frame in 0..<count { scratch[frame] *= scale }
            ring.write(UnsafeBufferPointer(start: scratch, count: count))
            offset += count
        }
        noteBlock(hostTime)
    }

    /// Delivers interleaved Float32 frames; channels are averaged.
    public func deliver(interleaved samples: UnsafePointer<Float>, frames: Int, channels: Int, hostTime: UInt64) {
        guard frames > 0, channels > 0 else { return }
        if channels == 1 {
            ring.write(UnsafeBufferPointer(start: samples, count: frames))
            noteBlock(hostTime)
            return
        }
        let scale = 1 / Float(channels)
        var offset = 0
        while offset < frames {
            let count = min(Self.scratchFrames, frames - offset)
            for frame in 0..<count {
                var sum: Float = 0
                let base = (offset + frame) * channels
                for channel in 0..<channels { sum += samples[base + channel] }
                scratch[frame] = sum * scale
            }
            ring.write(UnsafeBufferPointer(start: scratch, count: count))
            offset += count
        }
        noteBlock(hostTime)
    }

    private func noteBlock(_ hostTime: UInt64) {
        if hostTime != 0, firstHost.load(ordering: .relaxed) == 0 {
            firstHost.store(hostTime, ordering: .releasing)
        }
        blocks.add(1, ordering: .relaxed)
    }
}

// MARK: - Scripted backend (test seam, also usable by downstream UI/orchestrator tests)

/// A deterministic ``AudioCaptureBackend``: no hardware. Tests (and downstream modules' tests) push samples and fire
/// events by hand.
public final class ScriptedCaptureBackend: AudioCaptureBackend, @unchecked Sendable {
    public struct State: Sendable {
        public var startedDeviceUIDs: [String?] = []
        public var startCount = 0
        public var stopCount = 0
        public var isRunning = false
        public var nextStartError: AppError?
        public var format: CaptureFormat
    }

    public let name = "scripted"
    public let events: AsyncStream<AudioBackendEvent>
    private let continuation: AsyncStream<AudioBackendEvent>.Continuation
    private let state: Mutex<State>
    private let sinkBox = Mutex<AudioRenderSink?>(nil)

    public init(sampleRate: Double = 16_000) {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
        state = Mutex(State(format: CaptureFormat(sampleRate: sampleRate)))
    }

    public var snapshot: State { state.withLock { $0 } }
    public func failNextStart(with error: AppError) { state.withLock { $0.nextStartError = error } }
    public func setSampleRate(_ rate: Double) { state.withLock { $0.format = CaptureFormat(sampleRate: rate) } }
    public func emit(_ event: AudioBackendEvent) { continuation.yield(event) }

    public func start(deviceUID: String?, sink: AudioRenderSink) async throws -> CaptureFormat {
        let format = try state.withLock { state -> CaptureFormat in
            if let error = state.nextStartError {
                state.nextStartError = nil
                throw error
            }
            state.startCount += 1
            state.startedDeviceUIDs.append(deviceUID)
            state.isRunning = true
            return state.format
        }
        sinkBox.withLock { $0 = sink }
        return format
    }

    public func stop() async {
        state.withLock {
            $0.stopCount += 1
            $0.isRunning = false
        }
        sinkBox.withLock { $0 = nil }
    }

    /// Pushes mono samples at the backend's native rate, as the hardware callback would. Returns false when not running.
    @discardableResult
    public func push(_ samples: [Float], hostTime: UInt64 = 0) -> Bool {
        guard let sink = sinkBox.withLock({ $0 }) else { return false }
        samples.withUnsafeBufferPointer {
            if let base = $0.baseAddress { sink.deliver(interleaved: base, frames: $0.count, channels: 1, hostTime: hostTime) }
        }
        return true
    }

    /// Pushes `seconds` of a constant value (0 for silence) at the native rate.
    @discardableResult
    public func pushConstant(_ value: Float, seconds: Double, hostTime: UInt64 = 0) -> Bool {
        let rate = state.withLock { $0.format.sampleRate }
        return push([Float](repeating: value, count: Int(seconds * rate)), hostTime: hostTime)
    }
}
