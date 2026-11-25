import AppCore
import Foundation
import Testing
import TextModelProfiles
@testable import EarmarkTranslation

@Suite("Translation worker failure boundaries", .serialized, .timeLimit(.minutes(1)))
struct WorkerFailureTests {
    private func fixture() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("earmark-translation-worker-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("worker.sh")
        let source = #"""
        #!/bin/sh
        case "$1" in
          */wrong-profile) printf '%s\n' '{"ready":true,"profile":"nllb"}' ;;
          */bool-ready) printf '%s\n' '{"ready":1,"profile":"nllb"}' ;;
          */tokenizer-only) printf '%s\n' '{"ready":true,"profile":"translategemma-4b","architecture":"gemma3","parameters":4000000000,"quantizationType":15,"tokenizerOnly":true}' ;;
          */wrong-variant) printf '%s\n' '{"ready":true,"profile":"translategemma-4b","architecture":"gemma3","parameters":12000000000,"quantizationType":15,"tokenizerOnly":false}' ;;
          */wrong-quantization) printf '%s\n' '{"ready":true,"profile":"translategemma-4b","architecture":"gemma3","parameters":4000000000,"quantizationType":1,"tokenizerOnly":false}' ;;
          *)
            if [ "$3" = "translategemma-4b" ]; then
              printf '{"ready":true,"profile":"%s","architecture":"gemma3","parameters":4000000000,"quantizationType":15,"tokenizerOnly":false}\n' "$3"
            else
              printf '{"ready":true,"profile":"%s"}\n' "$3"
            fi ;;

        esac
        case "$1" in
          */blocked) trap '' TERM; : > "$1.started"; while :; do :; done ;;
        esac
        count=0
        while IFS= read -r request; do
          count=$((count + 1))
          case "$1" in
            */slow) : > "$1.started"; while :; do :; done ;;
            */bool-id) printf '%s\n' '{"id":true,"out":["invalid"]}' ;;
            */blank) printf '{"id":%d,"out":[" "]}\n' "$count" ;;
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

    @Test func generativeProfilesAreBoundAndBooleanIDsAndBlankOutputsFail() async throws {
        let (root, helper) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = CTranslate2WorkerRuntime(nativeExecutable: helper, generativeProfile: .gemma4)
        for folder in ["wrong-profile", "tokenizer-only", "wrong-variant", "wrong-quantization"] {
            await #expect(throws: (any Error).self) { try await runtime.load(modelFolder: root.appendingPathComponent(folder)) }
        }
        try await runtime.load(modelFolder: root.appendingPathComponent("normal"))
        #expect(try await runtime.translate(["hello"], source: "en", target: "de") == ["translated"])
        for folder in ["bool-id", "blank"] {
            try await runtime.load(modelFolder: root.appendingPathComponent(folder))
            await #expect(throws: (any Error).self) { try await runtime.translate(["hello"], source: "en", target: "de") }
        }
        await runtime.unload()
        let ct2 = CTranslate2WorkerRuntime(nativeExecutable: helper)
        await #expect(throws: (any Error).self) { try await ct2.load(modelFolder: root.appendingPathComponent("bool-ready")) }
        await ct2.unload()
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
