import Foundation
import Testing
@testable import EarmarkTranslation

@Suite("Cancellable translation admission")
struct TranslationOperationGateTests {
    @Test func cancellingQueuedWorkReturnsPromptlyWithoutInterruptingItsOwner() async throws {
        let gate = TranslationOperationGate()
        let probe = AdmissionProbe()
        let owner = Task {
            try await gate.withLease {
                await probe.started()
                try await Task.sleep(for: .milliseconds(600))
                return "owner completed"
            }
        }
        await probe.waitForStart()
        let queued = Task {
            try await gate.withLease {
                await probe.unexpectedExecution()
                return "must not run"
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        let clock = ContinuousClock()
        let start = clock.now
        queued.cancel()
        do { _ = try await queued.value; Issue.record("Cancelled work was admitted") }
        catch { #expect(error is CancellationError) }
        #expect(clock.now - start < .milliseconds(300))
        #expect(try await owner.value == "owner completed")
        #expect(await !probe.didRunUnexpectedly)
        #expect(try await gate.withLease { "next request" } == "next request")
    }

    @Test func cancellationAfterAdmissionStillReleasesTheLease() async throws {
        let gate = TranslationOperationGate()
        let probe = AdmissionProbe()
        let owner = Task {
            try await gate.withLease {
                await probe.started()
                try await Task.sleep(for: .seconds(30))
            }
        }
        await probe.waitForStart()
        owner.cancel()
        do { try await owner.value; Issue.record("Cancelled owner returned successfully") }
        catch { #expect(error is CancellationError) }
        #expect(try await gate.withLease { 42 } == 42)
    }
}

private actor AdmissionProbe {
    private var hasStarted = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var didRunUnexpectedly = false
    func started() {
        hasStarted = true
        let pending = startedWaiters
        startedWaiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
    func waitForStart() async {
        if hasStarted { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }
    func unexpectedExecution() { didRunUnexpectedly = true }
}
