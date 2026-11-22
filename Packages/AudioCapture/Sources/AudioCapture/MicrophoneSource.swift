import AVFoundation
import AppCore
import CoreAudio
import Foundation
import Synchronization

/// Microphone capture (AUD-AC-01..03, 05, 06, 08, 11, 14).
///
/// - Device selection by Core Audio UID (`deviceUID` nil follows the system default).
/// - Hot-plug: when the selected device disappears the source falls back to the default input; when the default input
///   changes and the source follows the default it restarts on the new device. Both emit `.deviceChanged(to:)`; the
///   session, its streams and the `startSeconds` timeline continue.
/// - Permission: `permissions` (the app's `PermissionsServicing`) is consulted at `start()`, the first use of a mic
///   feature; `notDetermined` triggers a request, anything but granted throws `AppError.permissionDenied(.microphone)`.
///   Without a service the system authorisation status is used directly.
/// - Single use: after `stop()` all streams are finished; create a new source for the next session.
public final class MicrophoneSource: ErrorReportingAudioSource, Sendable {
    public let tag: AudioSourceTag
    public let levels: AsyncStream<Float>
    public let health: AsyncStream<AudioSourceHealth>
    public let errors: AsyncStream<AppError>
    private let controller: MicrophoneController

    /// - Parameters:
    ///   - deviceUID: Preferred input device; nil follows the system default.
    ///   - voiceProcessing: Enables Apple voice processing (noise suppression + echo cancellation) on the mic path only.
    ///     Persisting the choice per feature is the caller's job (`SettingsStore`).
    ///   - backend: Injected for tests; defaults to the AVAudioEngine backend.
    public init(
        deviceUID: String? = nil, voiceProcessing: Bool = false, configuration: CaptureConfiguration = CaptureConfiguration(),
        permissions: (any PermissionsServicing)? = nil, deviceProvider: any AudioDeviceProviding = AudioDeviceProvider(),
        backend: (any AudioCaptureBackend)? = nil
    ) {
        tag = .mic(deviceUID: deviceUID)
        let channels = CaptureChannels(chunkBufferCount: configuration.chunkBufferCount)
        levels = channels.levels
        health = channels.health
        errors = channels.errors
        controller = MicrophoneController(
            preferredUID: deviceUID, tag: tag, configuration: configuration, channels: channels, permissions: permissions,
            provider: deviceProvider, backend: backend ?? AVAudioEngineBackend(voiceProcessing: voiceProcessing))
    }

    public func start() async throws -> AsyncStream<AudioChunk> { try await controller.start() }
    public func stop() async { await controller.stop() }
    public func metrics() async -> CaptureMetrics { await controller.session.metrics() }
}

actor MicrophoneController {
    let session: CaptureSession
    private let preferredUID: String?
    private let channels: CaptureChannels
    private let permissions: (any PermissionsServicing)?
    private let provider: any AudioDeviceProviding
    private let backend: any AudioCaptureBackend
    private var currentUID: String?
    private var started = false
    private var watchers: [Task<Void, Never>] = []

    init(
        preferredUID: String?, tag: AudioSourceTag, configuration: CaptureConfiguration, channels: CaptureChannels,
        permissions: (any PermissionsServicing)?, provider: any AudioDeviceProviding, backend: any AudioCaptureBackend
    ) {
        self.preferredUID = preferredUID
        self.channels = channels
        self.permissions = permissions
        self.provider = provider
        self.backend = backend
        session = CaptureSession(tag: tag, config: configuration, channels: channels)
    }

    func start() async throws -> AsyncStream<AudioChunk> {
        guard !started else { throw AppError.deviceUnavailable }
        started = true
        do {
            try await ensurePermission()
            let target = await resolveTarget()
            guard let target else { throw AppError.deviceUnavailable }
            try await session.begin(backend: backend, deviceUID: backendUID(for: target))
            currentUID = target.uid
            if target.fellBack { channels.healthContinuation.yield(.deviceChanged(to: target.uid)) }
        } catch {
            await session.stop()
            throw error
        }
        watchers = [
            Task { [provider, weak self] in
                for await _ in provider.changes() {
                    guard let self else { return }
                    await self.reevaluate(force: false)
                }
            },
            Task { [backend, weak self] in
                for await event in backend.events {
                    guard let self else { return }
                    switch event {
                    case .configurationChanged: await self.reevaluate(force: true)
                    case .failed: await self.reevaluate(force: true)
                    }
                }
            },
        ]
        return channels.chunks
    }

    func stop() async {
        watchers.forEach { $0.cancel() }
        watchers = []
        await session.stop()
    }

    // MARK: Policy

    private struct Target {
        var uid: String?
        var fellBack: Bool
    }

    private func ensurePermission() async throws {
        let status: PermissionStatus
        if let permissions {
            var current = await permissions.status(.microphone)
            if current == .notDetermined { current = await permissions.request(.microphone) }
            status = current
        } else {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: status = .granted
            case .notDetermined: status = await AVCaptureDevice.requestAccess(for: .audio) ? .granted : .denied
            case .restricted: status = .restricted
            default: status = .denied
            }
        }
        guard status == .granted else { throw AppError.permissionDenied(.microphone) }
    }

    /// Chooses the device to capture from: the preferred one while present, otherwise the default input.
    private func resolveTarget() async -> Target? {
        let inputs = await provider.devices().filter(\.isInput)
        let defaultID = await provider.defaultInput()?.id
        if let preferredUID {
            if inputs.contains(where: { $0.id == preferredUID }) { return Target(uid: preferredUID, fellBack: false) }
            guard let defaultID else { return nil }
            return Target(uid: defaultID, fellBack: true)
        }
        guard let defaultID else { return nil }
        return Target(uid: defaultID, fellBack: false)
    }

    /// The UID handed to the backend: the explicit preferred device while it is present, else nil (system default).
    private func backendUID(for target: Target) -> String? {
        guard let preferredUID, !target.fellBack else { return nil }
        return preferredUID
    }

    private func reevaluate(force: Bool) async {
        guard started, await session.isRunning else { return }
        guard let target = await resolveTarget() else {
            channels.errorContinuation.yield(.deviceUnavailable)
            return
        }
        guard force || target.uid != currentUID else { return }
        do {
            try await session.restart(deviceUID: backendUID(for: target))
            currentUID = target.uid
            channels.healthContinuation.yield(.deviceChanged(to: target.uid))
        } catch {
            channels.errorContinuation.yield((error as? AppError) ?? .deviceUnavailable)
        }
    }
}

// MARK: - AVAudioEngine backend

/// Real microphone backend: `AVAudioEngine` input node tap, device chosen via the input unit's current-device property.
/// The tap callback only downmixes into the ring (no converter, no allocation); resampling happens in the consumer.
/// `start`/`stop` are serialised by the session; hardware behaviour is unverified in the default test run.
public final class AVAudioEngineBackend: AudioCaptureBackend, @unchecked Sendable {
    public let name = "avAudioEngine"
    public let events: AsyncStream<AudioBackendEvent>
    private let continuation: AsyncStream<AudioBackendEvent>.Continuation
    private let voiceProcessing: Bool
    private var engine: AVAudioEngine?
    private var observer: (any NSObjectProtocol)?

    public init(voiceProcessing: Bool = false) {
        self.voiceProcessing = voiceProcessing
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(4))
    }

    public func start(deviceUID: String?, sink: AudioRenderSink) async throws -> CaptureFormat {
        await stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let deviceUID {
            guard var deviceID = HAL.deviceID(forUID: deviceUID), let unit = input.audioUnit else { throw AppError.deviceUnavailable }
            let status = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw AppError.deviceUnavailable }
        }
        if voiceProcessing {
            do { try input.setVoiceProcessingEnabled(true) } catch { throw AppError.deviceUnavailable }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AppError.deviceUnavailable }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, time in
            sink.deliver(audioBufferList: buffer.audioBufferList, hostTime: time.hostTime)
        }
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [continuation] _ in continuation.yield(.configurationChanged) }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            throw AppError.deviceUnavailable
        }
        self.engine = engine
        return CaptureFormat(sampleRate: format.sampleRate)
    }

    public func stop() async {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }
}
