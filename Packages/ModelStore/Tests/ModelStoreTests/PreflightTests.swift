import AppCore
import Foundation
import os
import Testing

@testable import ModelStore

private let gib: UInt64 = 1_073_741_824
private let qwen: ModelID = "mlx/qwen3-asr-0.6b-sinhala-8bit"
private let nllb: ModelID = "nllb/200-distilled-600M"

private struct Provider: HardwareTierProviding {
    var tier: HardwareTier
    var profile: HardwareProfile { HardwareProfile(chip: "T", memoryBytes: 8 * gib, performanceCores: 4, tier: tier) }
    func memoryPressure() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    func thermalPressure() -> AsyncStream<ThermalPressure> { AsyncStream { $0.finish() } }
    func isOnBattery() -> Bool { false }
}

private final class RecordingConsent: ModelDownloadConsenting, Sendable {
    private let log = OSAllocatedUnfairLock<[ModelPreflightResult]>(initialState: [])
    let answer: Bool
    let delay: Duration
    init(answer: Bool, delay: Duration = .zero) {
        self.answer = answer
        self.delay = delay
    }
    var asked: [ModelPreflightResult] { log.withLock { $0 } }
    func confirmDownload(_ preflight: ModelPreflightResult) async -> Bool {
        log.withLock { $0.append(preflight) }
        if delay > .zero { try? await Task.sleep(for: delay) }
        return answer
    }
}

private func harnessWithQwenAndNLLB() -> Harness {
    var harness = Harness()
    for id in [qwen, nllb] {
        let url = URL(string: "https://huggingface.co/test/\(id.rawValue)/resolve/main/model.bin")!
        harness.downloader.serve(url, Data(repeating: 7, count: 64))
        harness.manifests[id] = [RemoteFile(relativePath: "model.bin", url: url, sizeBytes: 64)]
    }
    return harness
}

@Suite("Licence / hardware / disk preflight and the consent hook (SCR-011)")
struct PreflightTests {
    @Test("a permissive, small, fitting model has a clear preflight")
    func clear() async {
        let manager = Harness().manager(hardware: Provider(tier: .tier16))
        let result = await manager.preflight(small)
        #expect(result.isClear)
        #expect(result.downloadBytes == 216_000_000)
        #expect(result.freeDiskBytes == Int64.max)
    }

    @Test("share-alike, hardware and large-download issues are reported for the Sinhala model on an 8 GB Mac")
    func qwenIssues() async {
        let manager = Harness().manager(hardware: Provider(tier: .tier8))
        let result = await manager.preflight(qwen)
        #expect(
            result.issues.contains {
                if case .licenseNotice(let spdx, let attribution) = $0 { return spdx == "CC-BY-SA-4.0" && attribution != nil }
                return false
            })
        #expect(result.issues.contains(.hardwareTier(required: .tier16, available: .tier8)))
        #expect(result.issues.contains(.largeDownload(bytes: 1_015_560_793)))
        #expect(result.requiresConsent && !result.isBlocking)
    }

    @Test("a non-commercial licence needs consent")
    func nonCommercial() async {
        let result = await Harness().manager(hardware: Provider(tier: .tier16)).preflight(nllb)
        #expect(result.issues.contains(.nonCommercialLicense(spdx: "CC-BY-NC-4.0")))
        #expect(result.requiresConsent)
    }

    @Test("not enough free disk blocks the download before any transfer, using the real (corrected) size")
    func insufficientDisk() async throws {
        let (harness, _, _) = twoFileHarness()
        let manager = harness.manager(freeDisk: { _ in 100_000_000 })
        let result = await manager.preflight(small)
        #expect(result.isBlocking)
        #expect(result.issues.contains(.insufficientDisk(needed: 259_200_000, available: 100_000_000)))

        var failure: AppError?
        do { _ = try await collect(manager.ensureAvailable(small)) } catch let error as AppError { failure = error }
        guard case .modelDownloadFailed(let id, let reason) = failure else {
            Issue.record("expected modelDownloadFailed, got \(String(describing: failure))")
            return
        }
        #expect(id == small && reason.hasPrefix("Not enough free disk space"))
        #expect(harness.downloader.calls.isEmpty, "preflight must run before the network is touched")
        #expect(await manager.state(of: small) == .notInstalled)
    }

    @Test("Apple assets, installed models and unknown models have nothing to confirm")
    func nothingToConfirm() async throws {
        let (harness, _, _) = twoFileHarness()
        let manager = harness.manager(freeDisk: { _ in 1 })
        #expect(await manager.preflight("apple/speech-analyzer").isClear)
        #expect(await manager.preflight("nope/unknown").issues.isEmpty)
        let roomy = harness.manager()
        _ = try await collect(roomy.ensureAvailable(small))
        #expect(await harness.manager(freeDisk: { _ in 1 }).preflight(small).isClear, "already installed")
    }

    @Test("approved consent lets the download proceed, is asked once and is remembered across restarts")
    func consentApproved() async throws {
        let harness = harnessWithQwenAndNLLB()
        let consent = RecordingConsent(answer: true)
        let manager = harness.manager(hardware: Provider(tier: .tier16), consent: consent)
        let events = try await collect(manager.ensureAvailable(qwen))
        #expect(events.last == .completed)
        #expect(consent.asked.count == 1 && consent.asked[0].model == qwen && consent.asked[0].requiresConsent)
        #expect(await manager.hasConsent(for: qwen))

        let reborn = harness.manager(hardware: Provider(tier: .tier16), consent: consent)
        #expect(await reborn.hasConsent(for: qwen), "consent persists")
        try await reborn.delete(qwen)
        _ = try await collect(reborn.ensureAvailable(qwen))
        #expect(consent.asked.count == 1, "not asked again")
    }

    @Test("declined consent aborts with AppError.cancelled and never touches the network")
    func consentDeclined() async throws {
        let harness = harnessWithQwenAndNLLB()
        let consent = RecordingConsent(answer: false)
        let manager = harness.manager(hardware: Provider(tier: .tier16), consent: consent)
        await #expect(throws: AppError.cancelled) { _ = try await collect(manager.ensureAvailable(nllb)) }
        #expect(harness.downloader.calls.isEmpty)
        #expect(await manager.state(of: nllb) == .notInstalled)
        #expect(await manager.hasConsent(for: nllb) == false)
        // Asked again next time, since nothing was granted.
        await #expect(throws: AppError.cancelled) { _ = try await collect(manager.ensureAvailable(nllb)) }
        #expect(consent.asked.count == 2)
    }

    @Test("two simultaneous callers are asked once")
    func consentDeduplicated() async throws {
        let harness = harnessWithQwenAndNLLB()
        let consent = RecordingConsent(answer: true, delay: .milliseconds(80))
        let manager = harness.manager(hardware: Provider(tier: .tier16), consent: consent)
        async let first = collect(manager.ensureAvailable(qwen))
        async let second = collect(manager.ensureAvailable(qwen))
        let (a, b) = try await (first, second)
        #expect(a.last == .completed && b.last == .completed)
        #expect(consent.asked.count == 1)
    }

    @Test("a caller that already confirmed can pre-grant consent; without a hook nothing is gated")
    func grantAndNoHook() async throws {
        let harness = harnessWithQwenAndNLLB()
        let consent = RecordingConsent(answer: false)
        let gated = harness.manager(hardware: Provider(tier: .tier16), consent: consent)
        await gated.grantConsent(for: qwen)
        _ = try await collect(gated.ensureAvailable(qwen))
        #expect(consent.asked.isEmpty)

        let open = harnessWithQwenAndNLLB()
        let events = try await collect(open.manager(hardware: Provider(tier: .tier16)).ensureAvailable(nllb))
        #expect(events.last == .completed)
    }

    @Test("an old state.json without the consent list still loads")
    func oldStateLoads() async throws {
        let harness = Harness()
        try Data(#"{"customModels":[],"installed":{},"paused":{}}"#.utf8).write(to: harness.root.appendingPathComponent("state.json"))
        let manager = harness.manager()
        #expect(await manager.hasConsent(for: qwen) == false)
        await manager.grantConsent(for: qwen)
        #expect(await harness.manager().hasConsent(for: qwen))
    }
}
