import AppCore
import Foundation
import Testing

@testable import Jobs

@Suite("Injected job handlers")
struct JobHandlerTests {
    @Test("a .finalizeMeeting job runs the injected handler, reports progress and completes with the transcript")
    func finalizeMeeting() async throws {
        let tid = TranscriptID()
        let seen = Box<URL?>(nil)
        let harness = try Harness(handlers: [
            .finalizeMeeting: { context in
                seen.value = context.job.input
                await context.progress(0.5)
                return JobHandlerResult(transcriptID: tid, title: "Weekly sync")
            }
        ])
        let folder = harness.folder.appendingPathComponent("rec", isDirectory: true)
        let id = try await harness.queue.enqueue(Job(kind: .finalizeMeeting, input: folder))
        #expect(await harness.waitFor(id, .completed))
        let job = try #require(await harness.job(id))
        #expect(job.transcriptID == tid && job.progress == 1)
        #expect(seen.value == folder)
        #expect(await harness.until { harness.notifier.completed.first?.transcriptTitle == "Weekly sync" })
    }

    @Test("a handler error fails the job with its description")
    func handlerFails() async throws {
        let harness = try Harness(handlers: [.translate: { _ in throw AppError.other("boom") }])
        let id = try await harness.queue.enqueue(Job(kind: .translate, transcriptID: TranscriptID()))
        #expect(await harness.waitFor(id, .failed))
        #expect(try #require(await harness.job(id)).failureReason == "boom")
    }

    @Test("a kind without a handler fails instead of hanging")
    func missingHandler() async throws {
        let harness = try Harness()
        let id = try await harness.queue.enqueue(Job(kind: .finalizeMeeting, input: harness.folder))
        #expect(await harness.waitFor(id, .failed))
    }

    @Test("translateTo on a file job runs the translate handler after saving segments")
    func translateAfterTranscription() async throws {
        let ran = Box<[TranscriptID?]>([])
        let harness = try Harness(handlers: [
            .translate: { context in
                ran.value.append(context.job.transcriptID)
                return JobHandlerResult()
            }
        ])
        let file = try harness.makeFile()
        let id = try await harness.queue.enqueue(
            Job(kind: .transcribeFile, input: file, settings: JobSettings(translateTo: "si")))
        #expect(await harness.waitFor(id, .completed))
        let job = try #require(await harness.job(id))
        #expect(ran.value == [job.transcriptID])
    }
}

final class Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
