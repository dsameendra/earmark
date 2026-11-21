import AppCore

/// A request to change a job's state.
public enum JobCommand: Sendable, CaseIterable {
    /// The scheduler picked the job up.
    case start
    case pause
    case resume
    case cancel
    case retry
    /// The run finished successfully.
    case complete
    /// The run threw (not a pause or cancel).
    case fail
    /// The process went away mid-run (crash, quit): the job goes back to the queue and resumes from its checkpoint.
    case interrupt
}

/// The queue state machine (FILE-AC-06): `pending -> running -> (paused | failed | completed | cancelled)` plus the
/// pause/resume/cancel/retry edges. Pure, so the table is unit-testable on its own; the queue rejects every `nil`.
///
/// | From | Allowed commands |
/// |---|---|
/// | pending | start, pause, cancel |
/// | running | pause, cancel, complete, fail, interrupt |
/// | paused | resume, cancel |
/// | failed | retry, cancel |
/// | cancelled | retry |
/// | completed | none |
public enum JobStateMachine {
    /// The state `command` leads to from `state`, or `nil` when the transition is illegal.
    public static func next(from state: JobState, command: JobCommand) -> JobState? {
        switch (state, command) {
        case (.pending, .start): .running
        case (.pending, .pause), (.running, .pause): .paused
        case (.paused, .resume): .pending
        case (.pending, .cancel), (.running, .cancel), (.paused, .cancel), (.failed, .cancel): .cancelled
        case (.failed, .retry), (.cancelled, .retry): .pending
        case (.running, .complete): .completed
        case (.running, .fail): .failed
        case (.running, .interrupt): .pending
        default: nil
        }
    }

    /// `true` for states a job never leaves on its own.
    public static func isTerminal(_ state: JobState) -> Bool {
        state == .completed || state == .failed || state == .cancelled
    }
}
