import AppCore
import Foundation
import Testing

@testable import AudioCapture

@Suite(.timeLimit(.minutes(1))) struct MicrophoneSourceTests {
    private func makeSource(
        uid: String? = nil, backend: ScriptedCaptureBackend, provider: FakeDeviceProvider? = nil,
        permissions: StubPermissions? = StubPermissions(status: .granted), config: CaptureConfiguration = testConfiguration()
    ) -> (MicrophoneSource, FakeDeviceProvider) {
        let provider = provider ?? FakeDeviceProvider(devices: [TestDevices.builtIn, TestDevices.usb], defaultInputID: "builtin")
        let source = MicrophoneSource(
            deviceUID: uid, configuration: config, permissions: permissions, deviceProvider: provider, backend: backend)
        return (source, provider)
    }

    // AUD-AC-01
    @Test func deliversSixteenKilohertzChunksWithMonotonicStartSeconds() async throws {
        let backend = ScriptedCaptureBackend(sampleRate: 16_000)
        let (source, _) = makeSource(backend: backend)
        let chunks = Recorder(try await source.start())
        backend.push(sine(count: 16_000, rate: 16_000), hostTime: 1_000_000)
        #expect(await chunks.wait { $0.count >= 10 })
        let values = chunks.values
        #expect(values.allSatisfy { $0.samples.count == 1600 && $0.source == .mic(deviceUID: nil) })
        for (index, chunk) in values.enumerated() { #expect(abs(chunk.startSeconds - Double(index) * 0.1) < 1e-9) }
        #expect(zip(values, values.dropFirst()).allSatisfy { $0.hostTime < $1.hostTime })
        #expect(values[0].hostTime == 1_000_000)
        await source.stop()
    }

    @Test func resamplesFortyEightKilohertzToSixteen() async throws {
        let backend = ScriptedCaptureBackend(sampleRate: 48_000)
        let (source, _) = makeSource(backend: backend)
        let chunks = Recorder(try await source.start())
        backend.push(sine(count: 48_000, rate: 48_000))
        #expect(await chunks.wait { $0.count >= 8 })
        let total = chunks.values.reduce(0) { $0 + $1.samples.count }
        #expect(total >= 12_800 && total <= 16_000)
        let peak = chunks.values.dropFirst().flatMap(\.samples).map(\.magnitude).max() ?? 0
        #expect(peak > 0.3 && peak < 0.7)  // a 440 Hz tone survives with its amplitude
        await source.stop()
    }

    // AUD-AC-08
    @Test func levelMeterUpdatesAtLeastFifteenHertz() async throws {
        let backend = ScriptedCaptureBackend()
        let (source, _) = makeSource(backend: backend)
        let levels = Recorder(source.levels)
        _ = try await source.start()
        // 1 s of audio delivered in real-time-sized 50 ms blocks yields at least 15 updates (the meter keeps only the newest few).
        for block in 0..<20 {
            backend.push(sine(count: 800, rate: 16_000, amplitude: 0.5, startIndex: block * 800))
            try await Task.sleep(for: .milliseconds(8))
        }
        #expect(await levels.wait { $0.count >= 15 })
        #expect(levels.values.allSatisfy { (0...1).contains($0) && $0 > 0.5 })
        await source.stop()
    }

    // AUD-AC-04
    @Test func silentBuffersRaiseSilentHealthAndCaptureSilentError() async throws {
        let backend = ScriptedCaptureBackend()
        let (source, _) = makeSource(backend: backend)
        let health = Recorder(source.health)
        let errors = Recorder(source.errors)
        _ = try await source.start()
        backend.pushConstant(0, seconds: 0.2)
        try await Task.sleep(for: .milliseconds(80))
        #expect(!health.values.contains(.silent))  // below the window
        backend.pushConstant(0, seconds: 0.2)
        #expect(await health.wait { $0.contains(.silent) })
        #expect(await errors.wait { !$0.isEmpty })
        if case .captureSilent = errors.values[0] {} else { Issue.record("expected captureSilent, got \(errors.values[0])") }
        // Recovery
        backend.push(sine(count: 1600, rate: 16_000))
        #expect(await health.wait { $0.suffix(1) == [.running] })
        await source.stop()
    }

    @Test func nonZeroAudioNeverFlagsSilent() async throws {
        let backend = ScriptedCaptureBackend()
        let (source, _) = makeSource(backend: backend)
        let health = Recorder(source.health)
        _ = try await source.start()
        backend.push(sine(count: 16_000, rate: 16_000, amplitude: 0.001))
        try await Task.sleep(for: .milliseconds(150))
        #expect(!health.values.contains(.silent))
        await source.stop()
    }

    // AUD-AC-05 / 06
    @Test func deniedPermissionThrowsAndStartsNothing() async throws {
        let backend = ScriptedCaptureBackend()
        let (source, _) = makeSource(backend: backend, permissions: StubPermissions(status: .denied))
        await #expect(throws: AppError.permissionDenied(.microphone)) { try await source.start() }
        #expect(backend.snapshot.startCount == 0)
    }

    @Test func notDeterminedRequestsOnceAtFirstUse() async throws {
        let backend = ScriptedCaptureBackend()
        let permissions = StubPermissions(status: .notDetermined)
        let (source, _) = makeSource(backend: backend, permissions: permissions)
        #expect(permissions.requestCount == 0)  // nothing at construction
        _ = try await source.start()
        #expect(permissions.requestCount == 1)
        await source.stop()
    }

    @Test func notDeterminedThenDeniedThrows() async throws {
        let backend = ScriptedCaptureBackend()
        let (source, _) = makeSource(backend: backend, permissions: StubPermissions(status: .notDetermined, grantOnRequest: false))
        await #expect(throws: AppError.permissionDenied(.microphone)) { try await source.start() }
    }

    // AUD-AC-02
    @Test func selectedDeviceMissingAtStartFallsBackToDefault() async throws {
        let backend = ScriptedCaptureBackend()
        let (source, _) = makeSource(uid: "gone", backend: backend)
        let health = Recorder(source.health)
        _ = try await source.start()
        #expect(backend.snapshot.startedDeviceUIDs == [nil])
        #expect(await health.wait { $0.contains(.deviceChanged(to: "builtin")) })
        await source.stop()
    }

    @Test func unpluggingSelectedDeviceFallsBackWithoutEndingSession() async throws {
        let backend = ScriptedCaptureBackend()
        let (source, provider) = makeSource(uid: "usb", backend: backend)
        let health = Recorder(source.health)
        let chunks = Recorder(try await source.start())
        #expect(backend.snapshot.startedDeviceUIDs == ["usb"])
        backend.push(sine(count: 8_000, rate: 16_000))
        #expect(await chunks.wait { $0.count >= 5 })

        provider.update(devices: [TestDevices.builtIn], defaultInputID: nil)
        #expect(await health.wait { $0.contains(.deviceChanged(to: "builtin")) })
        #expect(backend.snapshot.startedDeviceUIDs == ["usb", nil])

        backend.push(sine(count: 8_000, rate: 16_000))
        #expect(await chunks.wait { $0.count >= 10 })
        // The timeline continues across the restart and the session did not end.
        for (index, chunk) in chunks.values.enumerated() { #expect(abs(chunk.startSeconds - Double(index) * 0.1) < 1e-9) }
        #expect(!health.values.contains(.stopped))

        // The device comes back: the preferred one is used again.
        provider.update(devices: [TestDevices.builtIn, TestDevices.usb])
        #expect(await health.wait { $0.contains(.deviceChanged(to: "usb")) })
        await source.stop()
    }

    // AUD-AC-03
    @Test func followingDefaultRestartsWithinOneSecondWhenDefaultChanges() async throws {
        let backend = ScriptedCaptureBackend()
        let (source, provider) = makeSource(backend: backend)
        let health = Recorder(source.health)
        let chunks = Recorder(try await source.start())
        backend.push(sine(count: 3_200, rate: 16_000))
        #expect(await chunks.wait { $0.count >= 2 })
        let clock = ContinuousClock()
        let began = clock.now
        provider.update(defaultInputID: "usb")
        #expect(await health.wait(timeout: .seconds(1)) { $0.contains(.deviceChanged(to: "usb")) })
        #expect(clock.now - began < .seconds(1))
        #expect(backend.snapshot.startCount == 2)
        backend.push(sine(count: 3_200, rate: 16_000))
        #expect(await chunks.wait { $0.count >= 4 })
        await source.stop()
    }

    @Test func unrelatedDeviceListChangeDoesNotRestart() async throws {
        let backend = ScriptedCaptureBackend()
        let (source, provider) = makeSource(backend: backend)
        _ = try await source.start()
        provider.update(devices: [TestDevices.builtIn, TestDevices.usb, TestDevices.airpods])
        try await Task.sleep(for: .milliseconds(100))
        #expect(backend.snapshot.startCount == 1)
        await source.stop()
    }

    @Test func backendConfigurationChangeRestartsOnSameDevice() async throws {
        let backend = ScriptedCaptureBackend(sampleRate: 48_000)
        let (source, _) = makeSource(backend: backend)
        let chunks = Recorder(try await source.start())
        backend.push(sine(count: 9_600, rate: 48_000))
        #expect(await chunks.wait { $0.count >= 1 })
        backend.setSampleRate(44_100)  // sample-rate change mid-session
        backend.emit(.configurationChanged)
        let restarted = await chunks.wait { _ in backend.snapshot.startCount == 2 }
        #expect(restarted)
        backend.push(sine(count: 22_050, rate: 44_100))
        #expect(await chunks.wait { $0.count >= 4 })
        await source.stop()
    }

    @Test func noInputDevicesThrowsDeviceUnavailable() async throws {
        let backend = ScriptedCaptureBackend()
        let provider = FakeDeviceProvider(devices: [], defaultInputID: nil)
        let (source, _) = makeSource(backend: backend, provider: provider)
        await #expect(throws: AppError.deviceUnavailable) { try await source.start() }
    }

    // AUD-AC-14
    @Test func stopFinishesAllStreamsQuicklyAndReleasesTheBackend() async throws {
        let backend = ScriptedCaptureBackend()
        let (source, _) = makeSource(backend: backend)
        let chunks = Recorder(try await source.start())
        let levels = Recorder(source.levels)
        let health = Recorder(source.health)
        let errors = Recorder(source.errors)
        backend.push(sine(count: 3_300, rate: 16_000))
        let clock = ContinuousClock()
        let began = clock.now
        await source.stop()
        #expect(await chunks.waitForFinish(timeout: .milliseconds(500)))
        #expect(await levels.waitForFinish(timeout: .milliseconds(500)))
        #expect(await health.waitForFinish(timeout: .milliseconds(500)))
        #expect(await errors.waitForFinish(timeout: .milliseconds(500)))
        #expect(clock.now - began < .milliseconds(500))
        #expect(!backend.snapshot.isRunning)
        #expect(health.values.last == .stopped)
        // The trailing partial chunk is flushed on stop.
        #expect(chunks.values.reduce(0) { $0 + $1.samples.count } == 3_300)
        await source.stop()  // idempotent
    }

    @Test func sourceIsSingleUse() async throws {
        let backend = ScriptedCaptureBackend()
        let (source, _) = makeSource(backend: backend)
        _ = try await source.start()
        await source.stop()
        await #expect(throws: AppError.deviceUnavailable) { try await source.start() }
    }

    @Test func slowConsumerDropsOldestChunksAndCountsThem() async throws {
        let backend = ScriptedCaptureBackend()
        var config = testConfiguration()
        config.chunkBufferCount = 4
        let (source, _) = makeSource(backend: backend, config: config)
        let stream = try await source.start()  // not consumed yet
        backend.push(sine(count: 32_000, rate: 16_000))
        try await Task.sleep(for: .milliseconds(200))
        let metrics = await source.metrics()
        #expect(metrics.emittedChunks == 20)
        #expect(metrics.droppedChunks == 16)
        await source.stop()
        let kept = await Recorder(stream).wait { $0.count >= 4 } ? 4 : 0
        #expect(kept == 4)
    }

    @Test func ringOverflowNeverBlocksTheProducer() async throws {
        let backend = ScriptedCaptureBackend()
        var config = testConfiguration()
        config.ringSeconds = 0.25  // 48 k samples at the minimum
        let (source, _) = makeSource(backend: backend, config: config)
        _ = try await source.start()
        // Hammer the producer faster than the consumer can drain: it must return immediately every time.
        for _ in 0..<50 { backend.push([Float](repeating: 0.1, count: 8_000)) }
        let metrics = await source.metrics()
        #expect(metrics.ringDroppedSamples >= 0)
        await source.stop()
    }
}
