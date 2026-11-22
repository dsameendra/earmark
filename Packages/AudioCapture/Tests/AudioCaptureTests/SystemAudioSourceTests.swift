import AppCore
import AudioToolbox
import Foundation
import Testing

@testable import AudioCapture

@Suite(.timeLimit(.minutes(1))) struct SystemAudioSourceTests {
    // AUD-AC-07
    @Test func usesFirstBackendThatStarts() async throws {
        let tap = ScriptedCaptureBackend(sampleRate: 48_000)
        let sck = ScriptedCaptureBackend(sampleRate: 48_000)
        let source = SystemAudioSource(target: .app(bundleID: "us.zoom.xos"), configuration: testConfiguration(), backends: [tap, sck])
        #expect(source.tag == .app(bundleID: "us.zoom.xos"))
        let chunks = Recorder(try await source.start())
        tap.push(sine(count: 9_600, rate: 48_000))
        #expect(await chunks.wait { $0.count >= 1 })
        #expect(chunks.values[0].source == .app(bundleID: "us.zoom.xos"))
        #expect(source.activeBackendName == "scripted")
        #expect(sck.snapshot.startCount == 0)
        await source.stop()
    }

    @Test func fallsBackToSecondBackendWhenTapCannotBeCreated() async throws {
        let tap = ScriptedCaptureBackend()
        tap.failNextStart(with: .deviceUnavailable)
        let sck = ScriptedCaptureBackend()
        let source = SystemAudioSource(target: .system, configuration: testConfiguration(), backends: [tap, sck])
        let chunks = Recorder(try await source.start())
        #expect(tap.snapshot.startCount == 0)
        #expect(sck.snapshot.startCount == 1)
        sck.push(sine(count: 3_200, rate: 16_000))
        #expect(await chunks.wait { $0.count >= 2 })
        #expect(chunks.values[0].source == .system)
        await source.stop()
    }

    @Test func permissionDenialIsNotRetriedOnFallback() async throws {
        let tap = ScriptedCaptureBackend()
        tap.failNextStart(with: .permissionDenied(.systemAudioRecording))
        let sck = ScriptedCaptureBackend()
        let source = SystemAudioSource(target: .system, configuration: testConfiguration(), backends: [tap, sck])
        await #expect(throws: AppError.permissionDenied(.systemAudioRecording)) { try await source.start() }
        #expect(sck.snapshot.startCount == 0)
    }

    @Test func throwsWhenEveryBackendFails() async throws {
        let tap = ScriptedCaptureBackend()
        tap.failNextStart(with: .deviceUnavailable)
        let source = SystemAudioSource(target: .system, configuration: testConfiguration(), backends: [tap])
        await #expect(throws: AppError.deviceUnavailable) { try await source.start() }
    }

    @Test func knownDeniedPermissionFailsFast() async throws {
        let tap = ScriptedCaptureBackend()
        let source = SystemAudioSource(
            target: .system, configuration: testConfiguration(), permissions: StubPermissions(status: .denied), backends: [tap])
        await #expect(throws: AppError.permissionDenied(.systemAudioRecording)) { try await source.start() }
        #expect(tap.snapshot.startCount == 0)
    }

    // AUD-AC-04: the realistic silent-TCC-denial case, a tap that runs but delivers only zeros.
    @Test func tapDeliveringOnlyZerosReportsSilent() async throws {
        let tap = ScriptedCaptureBackend(sampleRate: 48_000)
        let source = SystemAudioSource(target: .system, configuration: testConfiguration(silenceWindow: 0.5), backends: [tap])
        let health = Recorder(source.health)
        let errors = Recorder(source.errors)
        _ = try await source.start()
        tap.pushConstant(0, seconds: 0.6)
        #expect(await health.wait { $0.contains(.silent) })
        #expect(await errors.wait { $0.contains { if case .captureSilent = $0 { true } else { false } } })
        await source.stop()
    }

    @Test func backendEventRestartsTheBackend() async throws {
        let tap = ScriptedCaptureBackend()
        let source = SystemAudioSource(target: .system, configuration: testConfiguration(), backends: [tap])
        let chunks = Recorder(try await source.start())
        tap.emit(.configurationChanged)  // e.g. the default output device switched
        #expect(await chunks.wait { _ in tap.snapshot.startCount == 2 })
        await source.stop()
    }

    @Test func bundleIDMatchingIncludesHelpersButNotLookalikes() {
        // Pure matching rule used for process objects.
        func matches(_ candidate: String, _ bundleID: String) -> Bool { candidate == bundleID || candidate.hasPrefix(bundleID + ".") }
        #expect(matches("us.zoom.xos", "us.zoom.xos"))
        #expect(matches("us.zoom.xos.helper", "us.zoom.xos"))
        #expect(!matches("us.zoom.xosx", "us.zoom.xos"))
    }
}

@Suite struct RenderSinkTests {
    @Test func downmixesStereoInterleavedToMono() {
        let sink = AudioRenderSink(ringCapacity: 1024)
        let stereo: [Float] = [1, 0, 0.5, 0.5, 0, -1]
        stereo.withUnsafeBufferPointer { sink.deliver(interleaved: $0.baseAddress!, frames: 3, channels: 2, hostTime: 42) }
        #expect(sink.ring.read(maxCount: 10) == [0.5, 0.5, -0.5])
        #expect(sink.firstHostTime == 42)
        #expect(sink.deliveredBlocks == 1)
    }

    @Test func downmixesPlanarAudioBufferList() {
        let sink = AudioRenderSink(ringCapacity: 1024)
        var left: [Float] = [1, 1, 1, 1]
        var right: [Float] = [0, 0, 0, 0]
        left.withUnsafeMutableBytes { l in
            right.withUnsafeMutableBytes { r in
                let list = AudioBufferList.allocate(maximumBuffers: 2)
                defer { free(list.unsafeMutablePointer) }
                list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 16, mData: l.baseAddress)
                list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 16, mData: r.baseAddress)
                sink.deliver(audioBufferList: UnsafePointer(list.unsafeMutablePointer), hostTime: 0)
            }
        }
        #expect(sink.ring.read(maxCount: 10) == [0.5, 0.5, 0.5, 0.5])
        #expect(sink.firstHostTime == 0)
    }

    @Test func deliverDropsInsteadOfBlockingWhenFull() {
        let sink = AudioRenderSink(ringCapacity: 8)
        let block = [Float](repeating: 1, count: 100)
        block.withUnsafeBufferPointer { sink.deliver(interleaved: $0.baseAddress!, frames: 100, channels: 1, hostTime: 1) }
        #expect(sink.ring.availableToRead == 8)
        #expect(sink.ring.droppedCount == 92)
    }
}

@Suite struct MixerAndHintTests {
    // AUD-AC-15
    @Test func mixerAlignsByHostTimeWithinTwentyMilliseconds() {
        let ticksPerSecond = 1_000_000.0
        let mic = AudioChunk(
            samples: [Float](repeating: 0.25, count: 1600), hostTime: 1_000_000, startSeconds: 5, source: .mic(deviceUID: nil))
        // Remote started 50 ms (800 samples) later by host time, although its own startSeconds says otherwise.
        let remote = AudioChunk(samples: [Float](repeating: 0.5, count: 1600), hostTime: 1_050_000, startSeconds: 0, source: .system)
        let mixed = AudioChunkMixer.mix(mic, remote, ticksPerSecond: ticksPerSecond)
        #expect(mixed.source == .mixed)
        #expect(mixed.samples.count == 2400)
        #expect(mixed.hostTime == 1_000_000 && mixed.startSeconds == 5)
        #expect(mixed.samples[0] == 0.25)  // only the mic
        #expect(mixed.samples[799] == 0.25)
        #expect(mixed.samples[800] == 0.75)  // overlap begins exactly 800 samples in
        #expect(mixed.samples[1599] == 0.75)
        #expect(mixed.samples[1600] == 0.5)  // only the remote
    }

    @Test func mixerHandlesRemoteStartingEarlier() {
        let ticksPerSecond = 1_000.0
        let mic = AudioChunk(samples: [0.5, 0.5], hostTime: 1_100, startSeconds: 1, source: .mic(deviceUID: nil))
        let remote = AudioChunk(samples: [Float](repeating: 0.5, count: 4), hostTime: 1_000, startSeconds: 1, source: .system)
        let mixed = AudioChunkMixer.mix(mic, remote, ticksPerSecond: ticksPerSecond)  // mic is 100 ms = 1600 samples later
        #expect(mixed.samples.count == 1602)
        #expect(mixed.hostTime == 1_000)
        #expect(mixed.samples[0] == 0.5 && mixed.samples[1600] == 0.5)
    }

    @Test func mixerFallsBackToStartSecondsWithoutHostTime() {
        let a = AudioChunk(samples: [1, 1], startSeconds: 0, source: .file)
        let b = AudioChunk(samples: [-0.5], startSeconds: 1.0 / 16_000, source: .file)
        #expect(AudioChunkMixer.mix(a, b).samples == [1, 0.5])
    }

    @Test func mixerClampsToUnitRange() {
        let a = AudioChunk(samples: [0.9], startSeconds: 0, source: .file)
        #expect(AudioChunkMixer.mix(a, a).samples == [1])
    }

    // AUD-AC-12
    @Test func headphoneHintShownOnceOnSpeakers() {
        #expect(CaptureHints.shouldShowHeadphoneHint(capturingMicAndSystem: true, outputLooksLikeHeadphones: false, alreadyShown: false))
        #expect(!CaptureHints.shouldShowHeadphoneHint(capturingMicAndSystem: true, outputLooksLikeHeadphones: true, alreadyShown: false))
        #expect(!CaptureHints.shouldShowHeadphoneHint(capturingMicAndSystem: true, outputLooksLikeHeadphones: false, alreadyShown: true))
        #expect(!CaptureHints.shouldShowHeadphoneHint(capturingMicAndSystem: false, outputLooksLikeHeadphones: false, alreadyShown: false))
    }

    // AUD-AC-13
    @Test func bluetoothDefaultSuggestsBuiltInMic() {
        let all = [TestDevices.airpods, TestDevices.usb, TestDevices.builtIn]
        #expect(CaptureHints.suggestedMicrophone(defaultInput: TestDevices.airpods, devices: all) == TestDevices.builtIn)
        #expect(CaptureHints.suggestedMicrophone(defaultInput: TestDevices.builtIn, devices: all) == nil)
        #expect(CaptureHints.suggestedMicrophone(defaultInput: nil, devices: all) == nil)
    }
}

@Suite struct DeviceProviderTests {
    /// Core Audio device enumeration needs no TCC permission, so this runs in the default suite.
    @Test func realProviderEnumeratesWithoutCrashing() async {
        let provider = AudioDeviceProvider()
        let devices = await provider.devices()
        if let input = await provider.defaultInput() { #expect(devices.contains { $0.id == input.id } && input.isInput) }
        _ = await provider.defaultOutputLooksLikeHeadphones()
    }

    @Test func changesStreamTerminatesWhenCancelled() async {
        let provider = AudioDeviceProvider()
        let task = Task { for await _ in provider.changes() {} }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await task.value  // would hang (time limit) if cancellation did not end the stream
    }
}

/// Opt-in hardware smoke tests: `EARMARK_HW_SMOKE=1 swift test --filter HardwareSmoke`. Needs TCC permission for the
/// host process (Terminal); skipped by default so the normal run never touches hardware or prompts.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["EARMARK_HW_SMOKE"] == "1"), .timeLimit(.minutes(1)))
struct HardwareSmoke {
    @Test func realMicDeliversChunks() async throws {
        let source = MicrophoneSource()
        let chunks = Recorder(try await source.start())
        let health = Recorder(source.health)
        _ = await chunks.wait(timeout: .seconds(4)) { $0.count >= 10 }
        await source.stop()
        let peak = chunks.values.flatMap(\.samples).map(\.magnitude).max() ?? 0
        print("HW mic chunks:", chunks.values.count, "peak:", peak, "health:", health.values)
        #expect(chunks.values.count >= 10)
    }

    @Test func realSystemTapRuns() async throws {
        let source = SystemAudioSource(target: .system)
        let chunks = Recorder(try await source.start())
        _ = await chunks.wait(timeout: .seconds(4)) { $0.count >= 10 }
        let peak = chunks.values.flatMap(\.samples).map(\.magnitude).max() ?? 0
        print("HW tap backend:", source.activeBackendName ?? "nil", "chunks:", chunks.values.count, "peak:", peak)
        await source.stop()
        #expect(chunks.values.count >= 10)
    }
}
