import Foundation
import SpeechNative
import Testing

private let nativeHelper = ProcessInfo.processInfo.environment["EARMARK_NATIVE_SPEECH_HELPER"]
private let multitalkerModel = ProcessInfo.processInfo.environment["EARMARK_MULTITALKER_MODEL"]

@Suite("Actual isolated speech worker", .serialized, .enabled(if: nativeHelper != nil && multitalkerModel != nil))
struct NativeWorkerTests {
    @Test func reportsRealProfileAndRejectsUnsupportedSpeakerStreamingWithoutFallback() async throws {
        let client = SpeechWorkerClient(executable: URL(fileURLWithPath: try #require(nativeHelper)))
        let model = URL(fileURLWithPath: try #require(multitalkerModel))
        let ready = try await client.start(modelFile: model, profile: "multitalker-v1")
        #expect(ready.variant == "multitalker-parakeet-streaming-0.6b-v1")
        #expect(ready.canDiarize && ready.canStream && !ready.canStreamWithSpeakers)
        await #expect(throws: SpeechWireError.self) {
            try await client.send(SpeechWorkerRequest(id: 0, operation: .begin, language: "en", diarize: true))
        }
        // A rejected model/task combination must release the child and permit a clean restart.
        _ = try await client.start(modelFile: model, profile: "multitalker-v1")
        let reply = try await client.send(SpeechWorkerRequest(id: 0, operation: .reset))
        #expect(reply.id == 1 && reply.error == nil)
        await client.stop()
    }
}
