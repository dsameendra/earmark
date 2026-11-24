import AppCore
import Foundation
import Testing
@testable import EarmarkTranslation

@Suite("Translation worker failure boundaries", .serialized, .timeLimit(.minutes(1)))
struct WorkerFailureTests {
    private func fixture() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("earmark-translation-worker-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("worker.sh")
        let source = #"""
        #!/bin/sh
        printf '{"ready":true,"profile":"%s"}\n' "$3"
        case "$1" in
          */blocked) trap '' TERM; : > "$1.started"; while :; do :; done ;;
        esac
        count=0
        while IFS= read -r request; do
          count=$((count + 1))
          case "$1" in
            */slow) : > "$1.started"; while :; do :; done ;;
            */wrong-id) printf '%s\n' '{"id":999,"error":"do not accept this unrelated error"}' ;;
            */oversized) /usr/bin/head -c 4194305 /dev/zero; while :; do :; done ;;
            *) printf '{"id":%d,"out":["translated"]}\n' "$count" ;;
          esac
        done
        """#
        try source.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (root, executable)
    }

    @Test func deadlineIncludesBlockedPipeWriteAndHealthyReloadWorks() async throws {
        let (root, helper) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = CTranslate2WorkerRuntime(nativeExecutable: helper, requestTimeout: .milliseconds(250))
        try await runtime.load(modelFolder: root.appendingPathComponent("blocked"))
        let started = ContinuousClock.now
        await #expect(throws: (any Error).self) {
            try await runtime.translate([String(repeating: "a", count: 100_000)], source: "eng_Latn", target: "deu_Latn")
        }
        #expect(ContinuousClock.now - started < .seconds(3))
        try await runtime.load(modelFolder: root.appendingPathComponent("normal"))
        #expect(try await runtime.translate(["hello"], source: "eng_Latn", target: "deu_Latn") == ["translated"])
        await runtime.unload()
    }

    @Test func queuedCancellationIsPromptAndDoesNotAbortItsOwner() async throws {
        let (root, helper) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = CTranslate2WorkerRuntime(nativeExecutable: helper)
        try await runtime.load(modelFolder: root.appendingPathComponent("slow"))
        let active = Task { try await runtime.translate(["hello"], source: "en", target: "de") }
        let marker = root.appendingPathComponent("slow.started")
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        let queued = Task { try await runtime.translate(["second"], source: "en", target: "de") }
        try await Task.sleep(for: .milliseconds(20))
        queued.cancel()
        await #expect(throws: CancellationError.self) { try await queued.value }
        active.cancel()
        await #expect(throws: CancellationError.self) { try await active.value }
        await runtime.unload()
    }

    @Test func replySizeAndErrorIdentityAreCheckedBeforeAcceptingOutput() async throws {
        let (root, helper) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = CTranslate2WorkerRuntime(nativeExecutable: helper, requestTimeout: .seconds(5))
        try await runtime.load(modelFolder: root.appendingPathComponent("wrong-id"))
        await #expect(throws: AppError.engineFailure(TranslationEngineIDs.nllb, reason: "Malformed translation worker reply.")) {
            try await runtime.translate(["hello"], source: "en", target: "de")
        }
        try await runtime.load(modelFolder: root.appendingPathComponent("oversized"))
        await #expect(throws: (any Error).self) { try await runtime.translate(["hello"], source: "en", target: "de") }
        await runtime.unload()
    }
}
