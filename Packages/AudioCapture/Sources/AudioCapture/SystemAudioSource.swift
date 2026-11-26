import AVFoundation
import AppCore
import CoreAudio
import CoreMedia
import Foundation
import ScreenCaptureKit
import Synchronization

/// What a ``SystemAudioSource`` captures.
public enum SystemAudioTarget: Sendable, Hashable {
    /// Everything the Mac plays (Earmark's own audio excluded).
    case system
    /// One app (and its helper processes) by bundle ID, e.g. `us.zoom.xos`, `com.microsoft.teams2`.
    case app(bundleID: String)
}

/// System or per-app audio (AUD-AC-04, 07, 14). Tries each backend in order: by default a Core Audio process tap first,
/// then ScreenCaptureKit audio if the tap cannot be created. A permission denial is not retried on another backend.
/// Silent TCC denial (the tap runs but delivers zeros) surfaces as `.silent` + `AppError.captureSilent` on the streams.
/// Single use, like ``MicrophoneSource``.
public final class SystemAudioSource: ErrorReportingAudioSource, Sendable {
    public let tag: AudioSourceTag
    public let levels: AsyncStream<Float>
    public let health: AsyncStream<AudioSourceHealth>
    public let errors: AsyncStream<AppError>
    private let controller: SystemAudioController

    /// - Parameters:
    ///   - backends: Injected for tests; defaults to `[ProcessTapBackend, ScreenCaptureKitBackend]`.
    ///   - permissions: Optional; a `.denied` system-audio-recording status fails fast with `permissionDenied`.
    public init(
        target: SystemAudioTarget = .system, configuration: CaptureConfiguration = CaptureConfiguration(),
        permissions: (any PermissionsServicing)? = nil, backends: [any AudioCaptureBackend]? = nil
    ) {
        switch target {
        case .system: tag = .system
        case .app(let bundleID): tag = .app(bundleID: bundleID)
        }
        let channels = CaptureChannels(chunkBufferCount: configuration.chunkBufferCount)
        levels = channels.levels
        health = channels.health
        errors = channels.errors
        controller = SystemAudioController(
            tag: tag, configuration: configuration, channels: channels, permissions: permissions,
            backends: backends ?? [ProcessTapBackend(target: target), ScreenCaptureKitBackend(target: target)])
    }

    /// Name of the backend that is capturing (`"processTap"`, `"screenCaptureKit"`), nil before `start()`.
    public var activeBackendName: String? { controller.activeBackendName }
    public func start() async throws -> AsyncStream<AudioChunk> { try await controller.start() }
    public func stop() async { await controller.stop() }
    public func metrics() async -> CaptureMetrics { await controller.session.metrics() }
}

actor SystemAudioController {
    let session: CaptureSession
    private let channels: CaptureChannels
    private let permissions: (any PermissionsServicing)?
    private let backends: [any AudioCaptureBackend]
    private let activeName = Mutex<String?>(nil)
    private var started = false
    private var watcher: Task<Void, Never>?

    nonisolated var activeBackendName: String? { activeName.withLock { $0 } }

    init(
        tag: AudioSourceTag, configuration: CaptureConfiguration, channels: CaptureChannels, permissions: (any PermissionsServicing)?,
        backends: [any AudioCaptureBackend]
    ) {
        self.channels = channels
        self.permissions = permissions
        self.backends = backends
        session = CaptureSession(tag: tag, config: configuration, channels: channels)
    }

    func start() async throws -> AsyncStream<AudioChunk> {
        guard !started else { throw AppError.deviceUnavailable }
        started = true
        if let permissions, await permissions.status(.systemAudioRecording) == .denied {
            await session.stop()
            throw AppError.permissionDenied(.systemAudioRecording)
        }
        var lastError: any Error = AppError.deviceUnavailable
        for backend in backends {
            do {
                try await session.begin(backend: backend, deviceUID: nil)
                activeName.withLock { $0 = backend.name }
                watch(backend)
                return channels.chunks
            } catch let error as AppError {
                if case .permissionDenied = error {
                    await session.stop()
                    throw error
                }
                lastError = error
            } catch {
                lastError = error
            }
        }
        await session.stop()
        throw lastError
    }

    func stop() async {
        watcher?.cancel()
        watcher = nil
        await session.stop()
    }

    /// Output-device switches and engine failures restart the same backend (AUD edge case: output switching while tapping).
    private func watch(_ backend: any AudioCaptureBackend) {
        watcher = Task { [weak self] in
            for await _ in backend.events {
                guard let self else { return }
                await self.restartBackend()
            }
        }
    }

    private func restartBackend() async {
        do {
            try await session.restart(deviceUID: nil)
        } catch {
            channels.errorContinuation.yield((error as? AppError) ?? .deviceUnavailable)
        }
    }
}

// MARK: - Core Audio process tap backend

/// Core Audio process tap (macOS 14.2+) wrapped in a private aggregate device and read with an IOProc.
/// The tap is unmuted so the user keeps hearing the meeting. Needs the System Audio Recording permission; without it the
/// tap still runs but delivers zeros (detected by the session). Hardware/TCC behaviour is unverified in the default test run.
public final class ProcessTapBackend: AudioCaptureBackend, @unchecked Sendable {
    public let name = "processTap"
    public let events: AsyncStream<AudioBackendEvent>
    private let continuation: AsyncStream<AudioBackendEvent>.Continuation
    private let target: SystemAudioTarget
    private let appWaitTimeout: Duration
    private let queue = DispatchQueue(label: "app.earmark.audio.tap-io", qos: .userInteractive)
    private let listenerQueue = DispatchQueue(label: "app.earmark.audio.tap-events")
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var outputListener: HAL.Listener?

    /// - Parameter appWaitTimeout: How long `start` waits for the target app to appear (audio process objects only exist
    ///   while an app is running audio). Ignored for `.system`.
    public init(target: SystemAudioTarget, appWaitTimeout: Duration = .seconds(5)) {
        self.target = target
        self.appWaitTimeout = appWaitTimeout
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(4))
    }

    public func start(deviceUID: String?, sink: AudioRenderSink) async throws -> CaptureFormat {
        await stop()
        let description = try await makeDescription()
        description.uuid = UUID()
        description.name = "Earmark tap"
        description.muteBehavior = .unmuted
        description.isPrivate = true

        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr else { throw AppError.deviceUnavailable }
        tapID = tap
        do {
            let format = try createAggregateAndStart(description: description, sink: sink)
            // Rebuild when the default output changes: the aggregate is clocked by the output device.
            let events = continuation
            outputListener = HAL.Listener(HAL.system, kAudioHardwarePropertyDefaultOutputDevice, queue: listenerQueue) {
                events.yield(.configurationChanged)
            }
            return format
        } catch {
            await stop()
            throw error
        }
    }

    private func makeDescription() async throws -> CATapDescription {
        switch target {
        case .system:
            let own = HAL.ownProcessObject().map { [$0] } ?? []
            return CATapDescription(stereoGlobalTapButExcludeProcesses: own)
        case .app(let bundleID):
            let deadline = ContinuousClock.now + appWaitTimeout
            while true {
                let objects = HAL.processObjects(bundleID: bundleID)
                if !objects.isEmpty { return CATapDescription(stereoMixdownOfProcesses: objects) }
                if ContinuousClock.now >= deadline { throw AppError.deviceUnavailable }
                try await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func createAggregateAndStart(description: CATapDescription, sink: AudioRenderSink) throws -> CaptureFormat {
        let tapFormat = HAL.get(tapID, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
        var dictionary: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Earmark tap aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]
            ],
        ]
        if let output = HAL.defaultOutputID, let uid = HAL.string(output, kAudioDevicePropertyDeviceUID) {
            dictionary[kAudioAggregateDeviceMainSubDeviceKey] = uid
            dictionary[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: uid]]
        }
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(dictionary as CFDictionary, &aggregate) == noErr else { throw AppError.deviceUnavailable }
        aggregateID = aggregate
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue) { _, input, inputTime, _, _ in
            sink.deliver(audioBufferList: input, hostTime: inputTime.pointee.mHostTime)
        }
        guard status == noErr, let proc else { throw AppError.deviceUnavailable }
        procID = proc
        guard AudioDeviceStart(aggregate, proc) == noErr else { throw AppError.deviceUnavailable }
        let tapRate = tapFormat?.mSampleRate ?? 0
        let rate = tapRate > 0 ? tapRate : 48_000
        return CaptureFormat(sampleRate: rate)
    }

    public func stop() async {
        outputListener = nil
        if aggregateID != kAudioObjectUnknown, let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }
}

// MARK: - ScreenCaptureKit fallback backend

/// ScreenCaptureKit audio capture (needs Screen Recording permission). Fallback when a process tap cannot be created.
/// Hardware/TCC behaviour is unverified in the default test run.
public final class ScreenCaptureKitBackend: AudioCaptureBackend, @unchecked Sendable {
    public let name = "screenCaptureKit"
    public let events: AsyncStream<AudioBackendEvent>
    private let continuation: AsyncStream<AudioBackendEvent>.Continuation
    private let target: SystemAudioTarget
    private var stream: SCStream?
    private var output: SCKAudioOutput?

    public init(target: SystemAudioTarget) {
        self.target = target
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(4))
    }

    public func start(deviceUID: String?, sink: AudioRenderSink) async throws -> CaptureFormat {
        await stop()
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw AppError.permissionDenied(.screenRecording)
        }
        guard let display = content.displays.first else { throw AppError.deviceUnavailable }
        let filter: SCContentFilter
        switch target {
        case .system:
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        case .app(let bundleID):
            let apps = content.applications.filter {
                let id = $0.bundleIdentifier.lowercased()
                let target = bundleID.lowercased()
                return id == target || id.hasPrefix(target + ".")
            }
            guard !apps.isEmpty else { throw AppError.deviceUnavailable }
            filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
        }
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        // Video cannot be disabled; keep it to a 2x2 frame once per second.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let output = SCKAudioOutput(sink: sink, events: continuation)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        do {
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue(label: "app.earmark.audio.sck"))
            try await stream.startCapture()
        } catch {
            throw AppError.deviceUnavailable
        }
        self.stream = stream
        self.output = output
        return CaptureFormat(sampleRate: 48_000)
    }

    public func stop() async {
        let stream = self.stream
        self.stream = nil
        output = nil
        try? await stream?.stopCapture()
    }
}

private final class SCKAudioOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let sink: AudioRenderSink
    private let events: AsyncStream<AudioBackendEvent>.Continuation

    init(sink: AudioRenderSink, events: AsyncStream<AudioBackendEvent>.Continuation) {
        self.sink = sink
        self.events = events
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        // SCK delivers on its own dispatch queue (not a real-time thread); host time is taken at delivery.
        let host = mach_absolute_time()
        try? sampleBuffer.withAudioBufferList { list, _ in
            sink.deliver(audioBufferList: list.unsafePointer, hostTime: host)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        events.yield(.failed(reason: error.localizedDescription))
    }
}
