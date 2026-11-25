import Foundation
import SpeechNative
import Testing

@Suite("Speech child transport lifecycle", .serialized)
struct SpeechWorkerClientTests {
    @Test func rejectsFalseOverlapReadinessAndMissingInferencePayload() async throws {
        let (root, helper) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = SpeechWorkerClient(executable: helper)
        _ = try await client.start(modelFile: root.appendingPathComponent("normal"), profile: "multitalker-v1")
        await #expect(throws: SpeechWireError.invalid("Unexpected speech response payload.")) {
            try await client.send(SpeechWorkerRequest(id: 0, operation: .run))
        }
        let text = try String(contentsOf: helper, encoding: .utf8)
            .replacingOccurrences(of: "\"canStreamWithSpeakers\":false", with: "\"canStreamWithSpeakers\":true")
        try text.write(to: helper, atomically: false, encoding: .utf8)
        await #expect(throws: SpeechWireError.invalid("The speech helper loaded an unexpected native profile.")) {
            try await client.start(modelFile: root.appendingPathComponent("normal"), profile: "multitalker-v1")
        }
    }

    @Test func oversizedPCMIsRejectedBeforeEncodingAndDoesNotLoseTheHealthyChild() async throws {
        let (root, helper) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = SpeechWorkerClient(executable: helper)
        _ = try await client.start(modelFile: root.appendingPathComponent("normal"), profile: "multitalker-v1")
        await #expect(throws: SpeechWireError.self) {
            try await client.send(SpeechWorkerRequest(id: 0, operation: .feed, pcm: Data(repeating: 0, count: 64_001)))
        }
        #expect(try await client.send(SpeechWorkerRequest(id: 0, operation: .reset)).id == 1)
        await client.stop()
    }
    private func fixture() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("earmark-speech-client-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let helper = root.appendingPathComponent("worker.sh")
        let source = #"""
        #!/bin/sh
        printf '%s\n' '{"id":0,"version":1,"ready":{"architecture":"parakeet","variant":"multitalker-parakeet-streaming-0.6b-v1","backend":"test","languages":["en"],"translationTargets":[],"canDetectLanguage":false,"canStream":true,"canTranslate":false,"canDiarize":true,"canStreamWithSpeakers":false,"nativeVersion":"0.4.2"}}'
        case "$1" in
          */blocked-write) : > "$1.started"; while :; do :; done ;;
        esac
        count=0
        while IFS= read -r request; do
          count=$((count + 1))
          case "$1" in
            */slow) : > "$1.started"; while :; do :; done ;;
            */wrong-id) printf '%s\n' '{"id":999,"version":1}' ;;
            */oversized) /usr/bin/head -c 4194305 /dev/zero; while :; do :; done ;;
            *) printf '{"id":%d,"version":1}\n' "$count" ;;
          esac
        done
        """#
        try Data(source.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        return (root, helper)
    }

    private func waitFor(_ file: URL) async throws {
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: file.path) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SpeechWireError.invalid("The scripted worker never started the request.")
    }

    @Test func cancellingQueuedRequestDoesNotKillItsOwnerAndOwnerCancellationRestarts() async throws {
        let (root, helper) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = SpeechWorkerClient(executable: helper)
        _ = try await client.start(modelFile: root.appendingPathComponent("slow"), profile: "multitalker-v1")
        let owner = Task { try await client.send(SpeechWorkerRequest(id: 0, operation: .run)) }
        try await waitFor(root.appendingPathComponent("slow.started"))
        let queued = Task { try await client.send(SpeechWorkerRequest(id: 0, operation: .reset)) }
        try await Task.sleep(for: .milliseconds(20))
        queued.cancel()
        await #expect(throws: CancellationError.self) { try await queued.value }
        let clock = ContinuousClock(), start = ContinuousClock.now
        owner.cancel()
        await #expect(throws: CancellationError.self) { try await owner.value }
        #expect(clock.now - start < .seconds(1))
        _ = try await client.start(modelFile: root.appendingPathComponent("normal"), profile: "multitalker-v1")
        let reply = try await client.send(SpeechWorkerRequest(id: 999, operation: .reset))
        #expect(reply.id == 1)
        await client.stop()
    }

    @Test func wrongIdentityAndOversizedReplyFailAndAHealthyWorkerCanRestart() async throws {
        let (root, helper) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = SpeechWorkerClient(executable: helper, timeout: .seconds(5))
        let cases: [(String, SpeechWireError)] = [
            ("wrong-id", .invalid("Mismatched speech worker reply.")),
            ("oversized", .invalid("Oversized speech response.")),
        ]
        for (name, expected) in cases {
            _ = try await client.start(modelFile: root.appendingPathComponent(name), profile: "multitalker-v1")
            await #expect(throws: expected) { try await client.send(SpeechWorkerRequest(id: 0, operation: .reset)) }
        }
        _ = try await client.start(modelFile: root.appendingPathComponent("normal"), profile: "multitalker-v1")
        #expect(try await client.send(SpeechWorkerRequest(id: 0, operation: .reset)).id == 1)
        await client.stop()
    }

    @Test func timeoutAlsoInterruptsABlockedPipeWrite() async throws {
        let (root, helper) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = SpeechWorkerClient(executable: helper, timeout: .milliseconds(500))
        _ = try await client.start(modelFile: root.appendingPathComponent("blocked-write"), profile: "multitalker-v1")
        let start = ContinuousClock.now
        await #expect(throws: (any Error).self) {
            try await client.send(SpeechWorkerRequest(id: 0, operation: .run, pcm: Data(repeating: 0, count: 1_024 * 1_024)))
        }
        #expect(ContinuousClock.now - start < .seconds(3))
        await client.stop()
    }
}
