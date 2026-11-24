import Foundation
import NativeWorkerKit
import Testing

@Suite("Bounded worker transport", .serialized)
struct WorkerTransportTests {
    private func fixture() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("earmark-worker-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("worker.sh")
        let source = #"""
        #!/bin/sh
        printf '%s\n' '{"ready":true}'
        case "$1" in
          blocked) trap '' TERM; : > "$2"; while :; do :; done ;;
        esac
        while IFS= read -r request; do
          case "$1" in
            oversized) /usr/bin/head -c 4194305 /dev/zero; while :; do :; done ;;
            slow) : > "$2"; while :; do :; done ;;
            *) printf '%s\n' '{"ok":true}' ;;
          esac
        done
        """#
        try source.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (root, executable)
    }

    @Test func blockedWriteDeadlineKillsAChildThatIgnoresTermination() async throws {
        let (root, executable) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = WorkerTransport(executable: executable, arguments: ["blocked", root.appendingPathComponent("started").path], timeout: .milliseconds(250))
        _ = try await transport.start()
        let start = ContinuousClock.now
        await #expect(throws: (any Error).self) { try await transport.request(Data(repeating: 65, count: 1_024 * 1_024)) }
        #expect(ContinuousClock.now - start < .seconds(3))
        await transport.stop()
    }

    @Test func oversizedReplyFailsWithBoundedFraming() async throws {
        let (root, executable) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = WorkerTransport(executable: executable, arguments: ["oversized"], timeout: .seconds(5))
        _ = try await transport.start()
        await #expect(throws: WorkerTransportError.invalid("Oversized worker response.")) { try await transport.request(Data("{}".utf8)) }
        await transport.stop()
    }

    @Test func queuedCancellationDoesNotInterruptActiveOwnerAndTransportRestarts() async throws {
        let (root, executable) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let started = root.appendingPathComponent("started")
        let transport = WorkerTransport(executable: executable, arguments: ["slow", started.path])
        _ = try await transport.start()
        let active = Task { try await transport.request(Data("{}".utf8)) }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: started.path) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(FileManager.default.fileExists(atPath: started.path))
        let queued = Task { try await transport.request(Data("{}".utf8)) }
        try await Task.sleep(for: .milliseconds(20))
        queued.cancel()
        await #expect(throws: CancellationError.self) { try await queued.value }
        active.cancel()
        await #expect(throws: CancellationError.self) { try await active.value }
        #expect(try await transport.start() == Data(#"{"ready":true}"#.utf8))
        await transport.stop()
    }

    @Test func splitUnicodeIsPreservedAndOversizedRequestsDoNotKillAHealthyChild() async throws {
        var framer = WorkerLineFramer()
        let message = Data(#"{"text":"සිංහල 日本語"}"#.utf8)
        var frames: [Data] = []
        for byte in message + Data([10]) { frames += try framer.append(Data([byte])) }
        #expect(frames == [message])
        let (root, executable) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = WorkerTransport(executable: executable, arguments: ["normal"])
        _ = try await transport.start()
        await #expect(throws: WorkerTransportError.self) { try await transport.request(Data(repeating: 1, count: WorkerTransport.maximumMessageBytes + 1)) }
        #expect(try await transport.request(message) == Data(#"{"ok":true}"#.utf8))
        await transport.stop()
    }
}
