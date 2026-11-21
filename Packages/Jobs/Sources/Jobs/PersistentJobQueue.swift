import AppCore
import Foundation

/// The persistent file-transcription queue (`JobQueue` implementation, T10).
///
/// - **Persistence**: every state change is journaled through `JobRepository`; segments are upserted per chunk with the
///   checkpoint, so a crash resumes from the last chunk (``resumeInterrupted()``, FILE-AC-08).
/// - **Scheduling**: pending jobs run in `priority`-descending, then creation order. The concurrency limit is the user's
///   setting (default by hardware tier), reduced on battery / under thermal pressure (``JobResourcePolicy``). Lowering it
///   never cancels running jobs (FILE-AC-07).
/// - **State machine**: ``JobStateMachine``; illegal commands are ignored and logged.
/// - **Failures**: any error becomes `.failed` with a `failureReason` and can be retried; nothing here traps (FILE-AC-10).
///
/// The per-job pipeline lives in `PersistentJobQueue+Run.swift`.
public actor PersistentJobQueue: JobQueue {
    enum Intent { case pause, cancel }

    struct RunningJob {
        var task: Task<Void, Never>
        var intent: Intent?
    }

    struct BatchState {
        var jobIDs: [JobID]
        var remaining: Set<JobID>
        var completed = 0
        var failed = 0
        var cancelled = 0
    }

    let services: JobQueueServices
    let configuration: JobQueueConfiguration
    let log = AppLog.logger("jobs.queue")
    let bus = JobBroadcaster<JobEvent>()
    let noteBus = JobBroadcaster<JobStatusNote>()

    var store: [JobID: Job] = [:]
    var notes: [JobID: String] = [:]
    var failures: [JobID: AppError] = [:]
    /// Languages reported by the pipeline's language detection while a job runs.
    var detected: [JobID: Set<LanguageCode>] = [:]
    var running: [JobID: RunningJob] = [:]
    var batches: [UUID: BatchState] = [:]
    var batchOf: [JobID: UUID] = [:]
    private var loaded = false
    private var userMaxConcurrency: Int?
    private var thermal: ThermalPressure = .nominal
    private var memoryHoldUntil: Date?
    private var unloadWhenIdle = false
    private var monitors: [Task<Void, Never>] = []

    public init(services: JobQueueServices, configuration: JobQueueConfiguration = JobQueueConfiguration()) {
        self.services = services
        self.configuration = configuration
    }

    // MARK: - JobQueue

    public func enqueue(_ job: Job) async throws -> JobID {
        await loadIfNeeded()
        try await insert(job)
        await schedule()
        return job.id
    }

    public func enqueue(files: [URL], settings: JobSettings, recursive: Bool) async throws -> [JobID] {
        await loadIfNeeded()
        let urls = MediaFileScanner.expand(files, recursive: recursive)
        let base = configuration.now()
        var created: [Job] = []
        for (index, url) in urls.enumerated() {
            // Distinct creation times keep a batch in drop order (ties would fall back to ids).
            created.append(
                Job(kind: .transcribeFile, input: url, settings: settings, createdAt: base.addingTimeInterval(Double(index) * 0.001)))
        }
        if created.count > 1 {
            let batch = UUID()
            let ids = created.map(\.id)
            batches[batch] = BatchState(jobIDs: ids, remaining: Set(ids))
            for id in ids { batchOf[id] = batch }
        }
        for job in created { try await insert(job) }
        await schedule()
        return created.map(\.id)
    }

    public func prioritize(_ id: JobID, to index: Int) async {
        await loadIfNeeded()
        var ordered = sortedJobs()
        guard let from = ordered.firstIndex(where: { $0.id == id }) else { return }
        let moved = ordered.remove(at: from)
        ordered.insert(moved, at: max(0, min(index, ordered.count)))
        // `JobRepository.allJobs` orders by priority descending, so renumber everything from the top.
        for (position, var job) in ordered.enumerated() {
            let priority = ordered.count - position
            guard job.priority != priority else { continue }
            job.priority = priority
            await commit(job)
        }
        await schedule()
    }

    public func pause(_ id: JobID) async {
        await loadIfNeeded()
        guard let job = store[id], JobStateMachine.next(from: job.state, command: .pause) != nil else { return reject(id, .pause) }
        if job.state == .running, running[id] != nil {
            running[id]?.intent = .pause
            running[id]?.task.cancel()  // the run loop records the pause with its latest checkpoint
        } else {
            await apply(id, .pause)
        }
    }

    public func resume(_ id: JobID) async {
        await loadIfNeeded()
        guard await apply(id, .resume) else { return }
        await schedule()
    }

    public func cancel(_ id: JobID) async {
        await loadIfNeeded()
        guard let job = store[id], JobStateMachine.next(from: job.state, command: .cancel) != nil else { return reject(id, .cancel) }
        if job.state == .running, running[id] != nil {
            running[id]?.intent = .cancel
            running[id]?.task.cancel()
        } else {
            await apply(id, .cancel) { $0.etaSeconds = nil }
            await jobReachedFinalState(id)
        }
    }

    public func retry(_ id: JobID) async {
        await loadIfNeeded()
        guard let job = store[id], JobStateMachine.next(from: job.state, command: .retry) != nil else { return reject(id, .retry) }
        let wasFailed = job.state == .failed
        let applied = await apply(id, .retry) {
            $0.failureReason = nil
            $0.etaSeconds = nil
            // A failed run keeps its checkpoint (resume where it stopped); a cancelled one starts over.
            if !wasFailed {
                $0.checkpoint = nil
                $0.progress = 0
            }
        }
        guard applied else { return }
        failures[id] = nil
        setNote(id, nil)
        // A finished batch member that is retried reports on its own again.
        if let batch = batchOf.removeValue(forKey: id) { batches[batch]?.remaining.remove(id) }
        await schedule()
    }

    public func setMaxConcurrency(_ n: Int) async {
        let value = max(1, min(n, 16))
        userMaxConcurrency = value
        await services.settings.set(value, for: JobsSettingsKey.maxConcurrency)
        await schedule()
    }

    public func jobs() async -> [Job] {
        await loadIfNeeded()
        return sortedJobs()
    }

    public nonisolated func events() -> AsyncStream<JobEvent> { bus.stream() }

    public func resumeInterrupted() async {
        await loadIfNeeded()
        // Jobs left `.running` by a crash or quit go back to the queue; their checkpoint is kept.
        for job in store.values where job.state == .running && running[job.id] == nil {
            await apply(job.id, .interrupt)
        }
        await schedule()
    }

    // MARK: - Extras beyond the protocol

    /// Latest status line for a job (download progress, "Identifying speakers", auto-export problems), if any.
    public func statusNote(for id: JobID) -> String? { notes[id] }

    /// Stream of status-line changes.
    public nonisolated func noteChanges() -> AsyncStream<JobStatusNote> { noteBus.stream() }

    /// The error behind a `.failed` job during this session (the persisted `failureReason` is the display text).
    public func failure(for id: JobID) -> AppError? { failures[id] }

    /// Removes a job that is not running from the queue (soft delete in the repository).
    public func remove(_ id: JobID) async {
        await loadIfNeeded()
        guard let job = store[id], job.state != .running else { return }
        store[id] = nil
        notes[id] = nil
        failures[id] = nil
        do { try await services.jobs.remove(id) } catch {
            log.error("Could not remove job: \(String(describing: error), privacy: .public)")
        }
        bus.send(.removed(id))
    }

    /// The media asset id used for a job's input: stable per job, so a missing-file error can be attributed to it.
    public static func mediaAssetID(for job: Job) -> MediaAssetID { MediaAssetID(job.id.rawValue) }

    // MARK: - Store

    func loadIfNeeded() async {
        guard !loaded else { return }
        do {
            for job in try await services.jobs.allJobs() where store[job.id] == nil { store[job.id] = job }
        } catch {
            log.error("Could not load jobs: \(String(describing: error), privacy: .public)")
        }
        loaded = true
    }

    private func insert(_ job: Job) async throws {
        try await services.jobs.save(job)
        store[job.id] = job
        bus.send(.updated(job))
    }

    /// Stores and journals `job`, then broadcasts it. Persistence failures are logged, never thrown.
    func commit(_ job: Job, persist: Bool = true) async {
        store[job.id] = job
        if persist {
            do { try await services.jobs.save(job) } catch {
                log.error("Could not save job: \(String(describing: error), privacy: .public)")
            }
        }
        bus.send(.updated(job))
    }

    /// Changes a stored job and commits it.
    func mutate(_ id: JobID, persist: Bool = true, _ change: (inout Job) -> Void) async {
        guard var job = store[id] else { return }
        change(&job)
        await commit(job, persist: persist)
    }

    /// Applies a state-machine command; returns `false` (and changes nothing) when the transition is illegal.
    @discardableResult
    func apply(_ id: JobID, _ command: JobCommand, _ change: (inout Job) -> Void = { _ in }) async -> Bool {
        guard var job = store[id], let next = JobStateMachine.next(from: job.state, command: command) else {
            reject(id, command)
            return false
        }
        job.state = next
        change(&job)
        await commit(job)
        return true
    }

    private func reject(_ id: JobID, _ command: JobCommand) {
        log.info("Ignored \(String(describing: command), privacy: .public) for job \(id.description, privacy: .public)")
    }

    func setNote(_ id: JobID, _ note: String?) {
        guard notes[id] != note else { return }
        notes[id] = note
        noteBus.send(JobStatusNote(jobID: id, note: note))
    }

    /// Queue order: higher `priority` first, then creation time.
    func sortedJobs() -> [Job] {
        store.values.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.description < rhs.id.description
        }
    }

    // MARK: - Scheduling

    /// Starts pending jobs up to the effective concurrency limit.
    func schedule() async {
        startMonitoringIfNeeded()
        let decision = await currentDecision()
        if let until = memoryHoldUntil, configuration.now() < until { return }
        // No suspension point below: the count check and registration are atomic with respect to other callers.
        while running.count < decision.concurrency {
            guard let next = sortedJobs().first(where: { $0.state == .pending && running[$0.id] == nil }) else { break }
            let id = next.id
            let task = Task(priority: decision.priority) { [self] in await execute(id) }
            running[id] = RunningJob(task: task)
        }
    }

    private func currentDecision() async -> JobResourcePolicy.Decision {
        let settings = services.settings
        let userMax: Int
        if let explicit = userMaxConcurrency {
            userMax = explicit
        } else if let stored = await settings.value(for: JobsSettingsKey.maxConcurrency, as: Int.self) {
            userMax = stored
        } else {
            userMax = JobResourcePolicy.defaultConcurrency(for: services.hardware.profile.tier)
        }
        let low = await settings.value(for: JobsSettingsKey.lowPriorityOnBattery, as: Bool.self) ?? true
        return JobResourcePolicy.decide(
            userMax: userMax, onBattery: services.hardware.isOnBattery(), lowPriorityOnBattery: low, thermal: thermal)
    }

    private func startMonitoringIfNeeded() {
        guard monitors.isEmpty else { return }
        let hardware = services.hardware
        let settings = services.settings
        monitors = [
            Task { [weak self] in
                for await pressure in hardware.thermalPressure() { await self?.thermalChanged(pressure) }
            },
            Task { [weak self] in
                for await _ in hardware.memoryPressure() { await self?.memoryPressureFired() }
            },
            Task { [weak self] in
                for await _ in settings.changes(for: JobsSettingsKey.maxConcurrency) { await self?.settingsChanged() }
            },
            Task { [weak self] in
                for await _ in settings.changes(for: JobsSettingsKey.lowPriorityOnBattery) { await self?.settingsChanged() }
            },
        ]
    }

    private func thermalChanged(_ pressure: ThermalPressure) async {
        thermal = pressure
        await schedule()
    }

    private func settingsChanged() async {
        // A stored value written elsewhere (Settings UI) overrides the cached one.
        userMaxConcurrency = nil
        await schedule()
    }

    /// FILE-AC-15: hold new starts briefly and unload the engines' models as soon as no job is using them. (Models are
    /// only in use while a job runs, so "idle" means "no running job".)
    private func memoryPressureFired() async {
        let hold = configuration.memoryPressureHold
        let seconds = Double(hold.components.seconds) + Double(hold.components.attoseconds) / 1e18
        memoryHoldUntil = configuration.now().addingTimeInterval(seconds)
        unloadWhenIdle = true
        await unloadEnginesIfIdle()
        Task { [weak self] in
            try? await Task.sleep(for: hold)
            await self?.schedule()
        }
    }

    /// Unloads every engine's model once nothing is running. Only done inside the memory-pressure hold, which keeps new
    /// jobs from starting (and loading a model) while the engines unload.
    func unloadEnginesIfIdle() async {
        guard unloadWhenIdle, running.isEmpty else { return }
        unloadWhenIdle = false
        guard let until = memoryHoldUntil, configuration.now() < until else { return }
        for engine in services.engines.values { await engine.unload() }
    }
}
