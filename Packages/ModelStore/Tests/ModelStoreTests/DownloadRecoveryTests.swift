import AppCore
import Foundation
import os
import Testing

@testable import ModelStore

private func http(_ status: Int) -> DownloadFailedError { DownloadFailedError(underlying: DownloadHTTPError(status: status)) }

private func resumeDirectory(_ root: URL) -> URL { root.appendingPathComponent(".partial/whisperkit__small/resume") }

private func waitForProgress(_ manager: ModelManager) async {
    var changes = manager.stateChanges().makeAsyncIterator()
    while let (id, state) = await changes.next() {
        if id == small, case .downloading(let fraction) = state, fraction > 0 { break }
    }
}

private func failureReason(_ manager: ModelManager) async -> String? {
    if case .failed(let reason) = await manager.state(of: small) { return reason }
    return nil
}

private final class FlakyManifests: ManifestResolving, Sendable {
    private let attempts = OSAllocatedUnfairLock(initialState: 0)
    let errors: [any Error]
    let files: [RemoteFile]
    init(errors: [any Error], files: [RemoteFile]) {
        self.errors = errors
        self.files = files
    }
    var calls: Int { attempts.withLock { $0 } }
    func files(for model: ModelDescriptor) async throws -> [RemoteFile] {
        let index = attempts.withLock { value -> Int in
            value += 1
            return value - 1
        }
        if index < errors.count { throw errors[index] }
        return files
    }
}

@Suite("Download recovery: expired resume URLs, retry with backoff, offline (SCR-011)")
struct DownloadRecoveryTests {
    @Test("an expired signed resume URL (403) is treated as an interruption: stale resume data is deleted and the file restarts cleanly")
    func expiredResumeRestartsCleanly() async throws {
        let (harness, a, _) = twoFileHarness()
        harness.downloader.serve(hf("a.bin"), a, stallOnce: true)
        let manager = harness.manager()
        let consumer = Task { try await collect(manager.ensureAvailable(small)) }
        await waitForProgress(manager)
        await manager.pauseDownload(small)
        #expect(FileManager.default.fileExists(atPath: resumeDirectory(harness.root).path))

        harness.downloader.rejectResumeData(with: http(403))  // the CDN link signed an hour ago is dead
        await manager.resumeDownload(small)
        let events = try await consumer.value
        #expect(events.last == .completed)

        let calls = harness.downloader.calls.filter { $0.url == hf("a.bin") }
        #expect(calls.map { $0.resumeData == nil } == [true, false, true], "fresh, resume rejected, clean restart")
        guard case .installed(let bytes) = await manager.state(of: small) else {
            Issue.record("must finish installed")
            return
        }
        #expect(bytes == 1000)
        #expect(!FileManager.default.fileExists(atPath: harness.root.appendingPathComponent(".partial/whisperkit__small").path))
    }

    @Test("a bad-response failure on resume (not a cancel) no longer leaves stale resume data behind")
    func staleResumeDataIsDeletedOnFailure() async throws {
        let (harness, a, _) = twoFileHarness()
        harness.downloader.serve(hf("a.bin"), a, stallOnce: true)
        let manager = harness.manager()
        let consumer = Task { try await collect(manager.ensureAvailable(small)) }
        await waitForProgress(manager)
        await manager.pauseDownload(small)
        // Both the resume attempt and the clean restart are refused: the failure must not keep the dead resume data.
        harness.downloader.rejectResumeData(with: http(403))
        harness.downloader.fail(hf("a.bin"), with: [http(403)])
        await manager.resumeDownload(small)
        await #expect(throws: AppError.self) { try await consumer.value }
        let resumeFiles = (try? FileManager.default.contentsOfDirectory(atPath: resumeDirectory(harness.root).path)) ?? []
        #expect(resumeFiles.isEmpty)
        #expect(await failureReason(manager)?.contains("HTTP 403") == true)
    }

    @Test("a failed row can be Cancelled (partial data discarded) or Retried (starts clean)")
    func failedRowCancelAndRetry() async throws {
        let (harness, _, _) = twoFileHarness()
        harness.downloader.fail(hf("sub/b.bin"), with: [http(403)])
        let manager = harness.manager()
        await #expect(throws: AppError.self) { _ = try await collect(manager.ensureAvailable(small)) }
        guard case .failed = await manager.state(of: small) else {
            Issue.record("expected failed")
            return
        }
        // Cancel: back to a clean slate.
        await manager.cancelDownload(small)
        #expect(await manager.state(of: small) == .notInstalled)
        #expect(!FileManager.default.fileExists(atPath: harness.root.appendingPathComponent(".partial/whisperkit__small").path))
        #expect(await harness.manager().state(of: small) == .notInstalled, "cancel persists")

        // Retry after another failure: finished files are kept, the rest downloads.
        harness.downloader.fail(hf("sub/b.bin"), with: [http(403)])
        await #expect(throws: AppError.self) { _ = try await collect(manager.ensureAvailable(small)) }
        let events = try await collect(manager.retryDownload(small))
        #expect(events.last == .completed)
        #expect(await manager.state(of: small) == .installed(bytesOnDisk: 1000))
    }

    @Test("transient server errors are retried with backoff and succeed")
    func transientRetries() async throws {
        let (harness, _, _) = twoFileHarness()
        harness.downloader.fail(hf("a.bin"), with: [http(503), DownloadFailedError(underlying: URLError(.timedOut))])
        let manager = harness.manager()
        let events = try await collect(manager.ensureAvailable(small))
        #expect(events.last == .completed)
        #expect(harness.downloader.calls.filter { $0.url == hf("a.bin") }.count == 3)
    }

    @Test("retries are bounded and the last failure explains itself")
    func retriesExhausted() async throws {
        let (harness, _, _) = twoFileHarness()
        harness.downloader.fail(hf("a.bin"), with: [http(503), http(503), http(502), http(503)])
        let manager = harness.manager()
        await #expect(throws: AppError.self) { _ = try await collect(manager.ensureAvailable(small)) }
        #expect(harness.downloader.calls.filter { $0.url == hf("a.bin") }.count == 3)
        #expect(await failureReason(manager)?.contains("temporarily unavailable") == true)
    }

    @Test("offline gives a clear message and is not retried")
    func offline() async throws {
        let (harness, _, _) = twoFileHarness()
        harness.downloader.fail(hf("a.bin"), with: [URLError(.notConnectedToInternet)])
        let manager = harness.manager()
        await #expect(throws: AppError.modelDownloadFailed(small, reason: DownloadMessage.offline)) {
            _ = try await collect(manager.ensureAvailable(small))
        }
        #expect(harness.downloader.calls.filter { $0.url == hf("a.bin") }.count == 1)
        #expect(await failureReason(manager) == DownloadMessage.offline)
        // Back online: Retry works.
        let events = try await collect(manager.retryDownload(small))
        #expect(events.last == .completed)
    }

    @Test("manifest requests are retried on 429/5xx and report offline clearly")
    func manifestRetries() async throws {
        let (harness, a, b) = twoFileHarness()
        let files = [
            RemoteFile(relativePath: "a.bin", url: hf("a.bin"), sizeBytes: 600, sha256: sha(a)),
            RemoteFile(relativePath: "sub/b.bin", url: hf("sub/b.bin"), sizeBytes: 400, sha256: sha(b)),
        ]
        let flaky = FlakyManifests(errors: [DownloadHTTPError(status: 429), DownloadHTTPError(status: 503)], files: files)
        let events = try await collect(harness.manager(manifests: flaky).ensureAvailable(small))
        #expect(events.last == .completed)
        #expect(flaky.calls == 3)

        let offlineHarness = Harness()
        let down = FlakyManifests(errors: [URLError(.notConnectedToInternet)], files: files)
        await #expect(throws: AppError.modelDownloadFailed(small, reason: DownloadMessage.offline)) {
            _ = try await collect(offlineHarness.manager(manifests: down).ensureAvailable(small))
        }
        #expect(down.calls == 1)
    }

    @Test("failures are classified")
    func classification() {
        #expect(DownloadFailureKind(classifying: URLError(.notConnectedToInternet)) == .offline)
        #expect(DownloadFailureKind(classifying: DownloadFailedError(underlying: URLError(.dataNotAllowed))) == .offline)
        #expect(DownloadFailureKind(classifying: URLError(.timedOut)) == .network)
        #expect(DownloadFailureKind(classifying: URLError(.networkConnectionLost)) == .network)
        #expect(DownloadFailureKind(classifying: DownloadHTTPError(status: 429)) == .server(status: 429))
        #expect(DownloadFailureKind(classifying: DownloadHTTPError(status: 502)) == .server(status: 502))
        #expect(DownloadFailureKind(classifying: DownloadHTTPError(status: 403)) == .refused(status: 403))
        #expect(DownloadFailureKind.server(status: 500).isTransient && DownloadFailureKind.network.isTransient)
        #expect(!DownloadFailureKind.offline.isTransient && !DownloadFailureKind.refused(status: 403).isTransient)
        #expect(DownloadFailureKind.offline.message == DownloadMessage.offline)
    }

    @Test("backoff doubles and is capped; the policy never allows zero attempts")
    func backoff() {
        let policy = RetryPolicy(maxAttempts: 5, baseDelay: .seconds(1))
        #expect(policy.delay(afterAttempt: 1) == .seconds(1))
        #expect(policy.delay(afterAttempt: 2) == .seconds(2))
        #expect(policy.delay(afterAttempt: 3) == .seconds(4))
        #expect(policy.delay(afterAttempt: 20) == .seconds(30))
        #expect(RetryPolicy(maxAttempts: 0).maxAttempts == 1)
        #expect(RetryPolicy.none.maxAttempts == 1)
    }
}
