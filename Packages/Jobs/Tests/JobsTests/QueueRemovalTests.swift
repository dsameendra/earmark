import AppCore
import Foundation
import Persistence
import Testing

@testable import Jobs

@Suite("Queue history removal")
struct QueueRemovalTests {
    @Test func removingCompletedWorkPreservesLibraryAndDoesNotReturnAfterReload() async throws {
        let h = try Harness()
        let file = try h.makeFile()
        let id = try await h.queue.enqueue(Job(kind: .transcribeFile, input: file))
        #expect(await h.waitFor(id, .completed))
        let job = try #require(await h.job(id))
        let transcript = try await h.transcript(of: job)
        let segments = try await h.segments(of: job)
        try await h.queue.remove(id)
        #expect(await h.queue.jobs().isEmpty)
        #expect(try await h.database.jobs.allJobs().isEmpty)
        #expect(try await h.database.transcripts.transcript(transcript.id) != nil)
        #expect(try await h.database.transcripts.segments(for: transcript.id) == segments)
        #expect(FileManager.default.fileExists(atPath: file.path))
        let restored = try Harness(database: h.database)
        #expect(await restored.queue.jobs().isEmpty)
    }

    @Test func removingRunningWorkJoinsCancellationAndKeepsPartialTranscript() async throws {
        let h = try Harness()
        h.engine.hold(true, afterChunks: 1)
        let id = try await h.queue.enqueue(Job(kind: .transcribeFile, input: try h.makeFile()))
        #expect(await h.until { await h.job(id)?.checkpoint?.mediaTime == 10 })
        let job = try #require(await h.job(id))
        let transcriptID = try #require(job.transcriptID)
        try await h.queue.remove(id)
        #expect(await h.queue.jobs().isEmpty)
        #expect(try await h.database.jobs.allJobs().isEmpty)
        #expect(try await h.database.transcripts.transcript(transcriptID) != nil)
        let segments = try await h.database.transcripts.segments(for: transcriptID)
        #expect(!segments.isEmpty)
        let restored = try Harness(database: h.database)
        #expect(await restored.queue.jobs().isEmpty)
    }

    @Test func persistenceFailureKeepsTheQueueEntryVisibleAndRetryable() async throws {
        let database = try AppDatabase.inMemory()
        let repository = RemovalFailureRepository(base: database.jobs)
        let h = try Harness(database: database, jobRepository: repository)
        let id = try await h.queue.enqueue(Job(kind: .transcribeFile, state: .paused, input: try h.makeFile()))
        do {
            try await h.queue.remove(id)
            Issue.record("Removal should propagate a storage failure")
        } catch { #expect(error is AppError) }
        #expect(await h.job(id)?.state == .paused)
        #expect(try await database.jobs.allJobs().map(\.id) == [id])
        await repository.allowRemoval()
        try await h.queue.remove(id)
        #expect(await h.queue.jobs().isEmpty)
    }
}

private actor RemovalFailureRepository: JobRepository {
    let base: any JobRepository
    private var failsRemoval = true
    init(base: any JobRepository) { self.base = base }
    func allJobs() async throws -> [Job] { try await base.allJobs() }
    func save(_ job: Job) async throws { try await base.save(job) }
    func remove(_ id: JobID) async throws {
        if failsRemoval { throw AppError.persistence(reason: "Storage is read-only") }
        try await base.remove(id)
    }
    func allowRemoval() { failsRemoval = false }
}
