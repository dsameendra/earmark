import AppCore
import Foundation
import Testing

@testable import EarmarkTranslation

private let nativePath = ProcessInfo.processInfo.environment["EARMARK_NATIVE_NLLB_HELPER"]
private let nativeModel = ProcessInfo.processInfo.environment["EARMARK_NLLB_MODEL_DIR"]

@Suite("Native worker integration", .serialized, .enabled(if: nativePath != nil && nativeModel != nil))
struct NativeWorkerTests {
    @Test func translatesCancelsAndRestartsWithoutPython() async throws {
        let helper = try #require(nativePath)
        let folder = try #require(nativeModel)
        let runtime = CTranslate2WorkerRuntime(nativeExecutable: URL(fileURLWithPath: helper))
        try await runtime.load(modelFolder: URL(fileURLWithPath: folder))
        let output = try await runtime.translate(["Good morning everyone."], source: "eng_Latn", target: "sin_Sinh")
        #expect(output == ["සුබ උදෑසනක් හැමෝටම."])
        let pending = Task {
            try await runtime.translate(
                Array(repeating: String(repeating: "The meeting starts in five minutes. ", count: 15), count: 8), source: "eng_Latn",
                target: "sin_Sinh")
        }
        try await Task.sleep(for: .milliseconds(100))
        let clock = ContinuousClock()
        let start = clock.now
        pending.cancel()
        do {
            _ = try await pending.value
            Issue.record("A cancelled native request returned translations")
        } catch { #expect(error is CancellationError) }
        #expect(clock.now - start < .seconds(1), "Cancellation must release the native request promptly")
        let again = try await runtime.translate(["Good morning everyone."], source: "eng_Latn", target: "sin_Sinh")
        #expect(again == output, "Cancellation must not poison subsequent requests")
        await runtime.unload()
    }
}
