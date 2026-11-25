import AppCore
import Foundation
import NativeWorkerKit
import Testing
@testable import EarmarkTranslation

@Suite("Confirmed translation shutdown")
struct ConfirmedShutdownTests {
    @Test func unsuccessfulShutdownKeepsItsReservationAndPreventsAReplacement() async throws {
        let control = ShutdownControl()
        let pool = CTranslate2RuntimePool(makeTranslationRuntime: { _ in ShutdownRuntime(control: control) })
        let first = pool.runtime(profile: CTranslate2ModelProfile.nllb)
        let second = pool.runtime(profile: CTranslate2ModelProfile.madlad)
        try await first.load(modelFolder: URL(fileURLWithPath: "/first"))
        await first.unload() // Simulate an owned child that has not exited yet.
        await #expect(throws: AppError.self) { try await second.load(modelFolder: URL(fileURLWithPath: "/second")) }
        #expect(await control.loads == 1)
        #expect(await control.peak == 1)
        await control.allowStopAndLoad()
        try await second.load(modelFolder: URL(fileURLWithPath: "/second"))
        #expect(await control.loads == 2)
        #expect(await control.peak == 1)
        await second.unload()
        #expect(await control.resident == 0)
    }

    @Test func failedStartupIsNotReadyButRetainsAnyStillRunningChild() async throws {
        let control = ShutdownControl(failLoad: true)
        let pool = CTranslate2RuntimePool(makeTranslationRuntime: { _ in ShutdownRuntime(control: control) })
        let first = pool.runtime(profile: CTranslate2ModelProfile.nllb)
        let second = pool.runtime(profile: CTranslate2ModelProfile.marian)
        await #expect(throws: AppError.self) { try await first.load(modelFolder: URL(fileURLWithPath: "/bad")) }
        await #expect(throws: AppError.self) { try await second.load(modelFolder: URL(fileURLWithPath: "/other")) }
        #expect(await control.loads == 1)
        #expect(await control.resident == 1)
        await control.allowStopAndLoad()
        try await second.load(modelFolder: URL(fileURLWithPath: "/other"))
        #expect(await control.peak == 1)
        await second.unload()
        #expect(await control.resident == 0)
    }
}

private actor ShutdownControl {
    private(set) var loads = 0
    private(set) var resident = 0
    private(set) var peak = 0
    private(set) var mayStop = false
    private var failLoad: Bool
    init(failLoad: Bool = false) { self.failLoad = failLoad }
    func loaded() -> Bool { loads += 1; resident += 1; peak = max(peak, resident); return failLoad }
    func stopped() { resident -= 1 }
    func allowStopAndLoad() { mayStop = true; failLoad = false }
}

private actor ShutdownRuntime: NLLBRuntime, WorkerStopping {
    let control: ShutdownControl
    private var started = false
    init(control: ShutdownControl) { self.control = control }
    func load(modelFolder: URL) async throws {
        started = true
        if await control.loaded() { throw AppError.other("Simulated startup failure after creating a child.") }
    }
    func translate(_ texts: [String], source: String, target: String) async throws -> [String] {
        guard started else { throw AppError.other("No model loaded.") }
        return texts
    }
    func unload() async { _ = await stop() }
    @discardableResult func stop() async -> Bool {
        if !started { return true }
        guard await control.mayStop else { return false }
        started = false
        await control.stopped()
        return true
    }
}
