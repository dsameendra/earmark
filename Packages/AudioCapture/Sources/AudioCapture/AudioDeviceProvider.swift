import AppCore
import CoreAudio
import Foundation
import Synchronization

/// Core Audio implementation of ``AudioDeviceProviding``. Listeners (device list, default input, default output) are
/// installed lazily on the first `changes()` subscription and removed when the provider is released. Idle cost: none.
public final class AudioDeviceProvider: AudioDeviceProviding, @unchecked Sendable {
    private struct State {
        var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]
        var listeners: [HAL.Listener] = []
    }

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "app.earmark.audio.device-changes")

    public init() {}

    public func devices() async -> [AudioDevice] {
        HAL.objectIDs(HAL.system, kAudioHardwarePropertyDevices).compactMap(HAL.audioDevice)
    }

    public func defaultInput() async -> AudioDevice? {
        HAL.defaultInputID.flatMap(HAL.audioDevice)
    }

    public func defaultOutput() async -> AudioDevice? {
        HAL.defaultOutputID.flatMap(HAL.audioDevice)
    }

    /// AUD-AC-12 input: true when the default output is Bluetooth or the built-in headphone jack.
    public func defaultOutputLooksLikeHeadphones() async -> Bool {
        HAL.defaultOutputID.map(HAL.outputLooksLikeHeadphones) ?? false
    }

    public func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        state.withLock { state in
            state.continuations[id] = continuation
            if state.listeners.isEmpty { state.listeners = makeListeners() }
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { state in
                state.continuations[id] = nil
                if state.continuations.isEmpty { state.listeners = [] }
            }
        }
        return stream
    }

    private func makeListeners() -> [HAL.Listener] {
        [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice].map {
            HAL.Listener(HAL.system, $0, queue: queue) { [weak self] in self?.broadcast() }
        }
    }

    private func broadcast() {
        let targets = state.withLock { Array($0.continuations.values) }
        for continuation in targets { continuation.yield() }
    }
}
