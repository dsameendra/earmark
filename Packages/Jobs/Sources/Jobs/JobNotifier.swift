import AppCore
import Foundation

/// What a finished single job reports to the notifier.
public struct JobCompletionInfo: Sendable {
    public var job: Job
    /// Title of the saved transcript.
    public var transcriptTitle: String?
    /// File written by auto-export, if any.
    public var exportedTo: URL?
    public init(job: Job, transcriptTitle: String?, exportedTo: URL? = nil) {
        self.job = job
        self.transcriptTitle = transcriptTitle
        self.exportedTo = exportedTo
    }
}

/// Outcome of a multi-file batch once every job in it reached a final state (FILE-AC-11 batch notification).
public struct JobBatchSummary: Sendable, Equatable {
    public var jobIDs: [JobID]
    public var completed: Int
    public var failed: Int
    public var cancelled: Int
    public var total: Int { jobIDs.count }
    public init(jobIDs: [JobID], completed: Int, failed: Int, cancelled: Int) {
        self.jobIDs = jobIDs
        self.completed = completed
        self.failed = failed
        self.cancelled = cancelled
    }
}

/// Completion hook. The package never talks to `UNUserNotificationCenter`; the app supplies an implementation.
///
/// Jobs enqueued together (more than one file) report once through ``batchFinished(_:)``; single jobs report through
/// ``jobCompleted(_:)`` / ``jobFailed(_:)``.
public protocol JobNotifier: Sendable {
    func jobCompleted(_ info: JobCompletionInfo) async
    func jobFailed(_ job: Job) async
    func batchFinished(_ summary: JobBatchSummary) async
}

/// Per-job status line ("Downloading Whisper large-v3 (42%)") that has no field on `Job` (AppCore is frozen).
public struct JobStatusNote: Sendable, Equatable {
    public var jobID: JobID
    /// `nil` clears the note.
    public var note: String?
    public init(jobID: JobID, note: String?) {
        self.jobID = jobID
        self.note = note
    }
}
