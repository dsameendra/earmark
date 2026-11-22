import AppCore
import FeatureSupport
import Foundation
import Observation

/// The sections of the queue list, in display order.
public enum QueueGroup: String, Sendable, CaseIterable, Identifiable {
    case running, pending, paused, failed, finished
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .running: "Working on"
        case .pending: "Waiting"
        case .paused: "Paused"
        case .failed: "Needs attention"
        case .finished: "Finished"
        }
    }

    init(_ state: JobState) {
        switch state {
        case .running: self = .running
        case .pending: self = .pending
        case .paused: self = .paused
        case .failed: self = .failed
        case .completed, .cancelled: self = .finished
        }
    }
}

/// Pure formatting helpers for job rows (FILE-AC-14).
public enum QueueFormatting {
    /// Only actively running work animates. Every other state has a resting, truthful row.
    public static func showsProgress(for state: JobState) -> Bool { state == .running || state == .paused }

    public static func fraction(_ progress: Double) -> Double { progress.isFinite ? min(1, max(0, progress)) : 0 }

    /// "about 3 min left", "about 40 s left"; `nil` when there is no estimate.
    public static func eta(_ seconds: TimeInterval?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        if seconds < 60 { return "about \(max(1, Int(seconds.rounded()))) s left" }
        return "about \(Int((seconds / 60).rounded(.up))) min left"
    }

    /// "EN", "Auto", "EN + SI".
    public static func language(_ mode: LanguageMode) -> String {
        switch mode {
        case .single(let code): code.primary.rawValue.uppercased()
        case .autoDetect: "Auto"
        case .multilingual(let codes): codes.sorted().map { $0.primary.rawValue.uppercased() }.joined(separator: " + ")
        }
    }

    /// Engine, language and ETA summary shown under the file name.
    public static func detail(for job: Job) -> String {
        var parts: [String] = []
        if let engine = job.engine { parts.append(engine.rawValue) } else if job.state == .pending { parts.append("Engine: auto") }
        parts.append(language(job.settings.languageMode))
        if job.state == .running, let eta = eta(job.etaSeconds) { parts.append(eta) }
        return parts.joined(separator: " · ")
    }
}

/// Drives the Queue screen from `JobQueue` (pending / running / paused / failed jobs). Event-driven: no polling.
@MainActor @Observable
public final class QueueModel {
    public private(set) var jobs: [Job] = []
    public private(set) var isLoading = true
    public private(set) var errorMessage: String?
    public private(set) var maxConcurrency = 1
    public private(set) var removingIDs = Set<JobID>()
    public private(set) var isClearing = false
    /// Non-nil while the batch settings sheet is shown.
    public var batch: BatchSettingsModel?

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private var removalErrorID: JobID?
    @ObservationIgnored private var queue: any JobQueue { services.jobQueue }

    public init(services: AppServices) { self.services = services }

    /// Jobs of one section, in queue order.
    public func jobs(in group: QueueGroup) -> [Job] { jobs.filter { QueueGroup($0.state) == group } }

    /// Sections that have at least one job.
    public var visibleGroups: [QueueGroup] { QueueGroup.allCases.filter { !jobs(in: $0).isEmpty } }
    public var hasFinished: Bool { jobs.contains { $0.state == .completed || $0.state == .cancelled } }
    public var hasActive: Bool { jobs.contains { $0.state == .running || $0.state == .pending } }

    /// Subscribes to events first (so nothing is lost), loads jobs, then follows events until cancelled.
    public func run() async {
        let events = queue.events()
        if let stored = await services.settings.value(for: SettingsKey.queueMaxConcurrency, as: Int.self) {
            maxConcurrency = min(4, max(1, stored))
        }
        jobs = await queue.jobs().filter { $0.deletedAt == nil }
        isLoading = false
        for await event in events { apply(event) }
    }

    func apply(_ event: JobEvent) {
        switch event {
        case .updated(let job):
            if job.deletedAt != nil {
                jobs.removeAll { $0.id == job.id }
                return
            }
            if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job } else { jobs.append(job) }
        case .removed(let id):
            jobs.removeAll { $0.id == id }
        }
    }

    // MARK: Reordering (FILE-AC-07)

    /// Reorders the waiting jobs by drag (`List.onMove` inside the Waiting section).
    public func movePending(from source: IndexSet, to destination: Int) async {
        let pending = jobs(in: .pending)
        guard let from = source.first, pending.indices.contains(from) else { return }
        let moved = pending[from]
        var reordered = pending
        reordered.move(fromOffsets: source, toOffset: destination)
        // The waiting jobs keep their slots in the full order, in their new relative order.
        var iterator = reordered.makeIterator()
        jobs = jobs.map { $0.state == .pending ? (iterator.next() ?? $0) : $0 }
        guard let target = jobs.firstIndex(where: { $0.id == moved.id }) else { return }
        await queue.prioritize(moved.id, to: target)
    }

    /// Reorders all jobs (for callers that use a flat list).
    public func move(from source: IndexSet, to destination: Int) async {
        guard let from = source.first, jobs.indices.contains(from) else { return }
        let id = jobs[from].id
        jobs.move(fromOffsets: source, toOffset: destination)
        await queue.prioritize(id, to: jobs.firstIndex { $0.id == id } ?? destination)
    }

    // MARK: Per-job actions

    public func pause(_ id: JobID) async { await queue.pause(id) }
    public func resume(_ id: JobID) async { await queue.resume(id) }
    public func cancel(_ id: JobID) async { await queue.cancel(id) }
    public func retry(_ id: JobID) async { await queue.retry(id) }

    /// Removes the queue entry only. Saved/partial transcripts and source recordings remain in the Library.
    public func remove(_ id: JobID) async {
        guard removingIDs.insert(id).inserted else { return }
        defer { removingIDs.remove(id) }
        do {
            try await queue.remove(id)
            jobs.removeAll { $0.id == id }
            if removalErrorID == id {
                removalErrorID = nil
                errorMessage = nil
            }
        } catch {
            removalErrorID = id
            let name = jobs.first { $0.id == id }?.input?.lastPathComponent ?? "this queue item"
            let reason: String
            switch error as? AppError {
            case .persistence(let message), .other(let message): reason = message
            default: reason = error.localizedDescription
            }
            errorMessage = "Could not remove \(name). \(reason)"
        }
    }

    /// Clears successful and cancelled history, leaving failures available to retry.
    public func clearFinished() async {
        guard !isClearing else { return }
        isClearing = true
        defer { isClearing = false }
        for id in jobs.filter({ $0.state == .completed || $0.state == .cancelled }).map(\.id) { await remove(id) }
    }

    /// Explicitly cancels active work and removes all queue entries without deleting Library content.
    public func clearQueue() async {
        guard !isClearing else { return }
        isClearing = true
        defer { isClearing = false }
        let queued = jobs
        // Stop waiting work from being started as running jobs finish their cancellation cleanup.
        for job in queued where job.state == .pending { await queue.pause(job.id) }
        for job in queued { await remove(job.id) }
    }

    /// Retries every failed job.
    public func retryAllFailed() async {
        for job in jobs(in: .failed) { await queue.retry(job.id) }
    }

    /// Pauses every running or waiting job.
    public func pauseAll() async {
        for job in jobs where job.state == .running || job.state == .pending { await queue.pause(job.id) }
    }

    /// Resumes every paused job.
    public func resumeAll() async {
        for job in jobs(in: .paused) { await queue.resume(job.id) }
    }

    // MARK: Concurrency (FILE-AC-07)

    /// Applies and persists the concurrency setting; running jobs are not restarted.
    public func setConcurrency(_ value: Int) async {
        let clamped = min(4, max(1, value))
        maxConcurrency = clamped
        await services.settings.set(clamped, for: SettingsKey.queueMaxConcurrency)
        await queue.setMaxConcurrency(clamped)
    }

    // MARK: Batch add (FILE-AC-01/02/04)

    /// Opens the per-batch settings sheet for files and/or folders. The shell may call this for drops.
    public func presentBatch(urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        batch = BatchSettingsModel(urls: files, services: services)
    }

    /// What ``requestAdd(_:)`` did with the files.
    public enum AddOutcome: Sendable, Equatable { case ignored, presented, enqueued, failed(String) }

    /// The one entry point for adding files (window drop, Home drop, Transcribe File, Queue add, folders). With "Ask before
    /// adding files" on (the default) it shows the Transcribe sheet and enqueues nothing yet; with it off it enqueues straight
    /// away using the saved choices, which now include the speaker settings (SCR-013).
    @discardableResult
    public func requestAdd(_ urls: [URL]) async -> AddOutcome {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return .ignored }
        if await FileJobSettings.asksBeforeAdding(in: services.settings) {
            batch = BatchSettingsModel(urls: files, services: services)
            return .presented
        }
        do {
            let defaults = await FileJobSettings.load(from: services.settings, catalog: services.models.catalog())
            _ = try await queue.enqueue(files: files, settings: defaults, recursive: true)
            errorMessage = nil
            return .enqueued
        } catch {
            errorMessage = String(describing: error)
            return .failed(String(describing: error))
        }
    }

    /// Enqueues the batch with its settings and closes the sheet.
    public func submitBatch() async {
        guard let batch else { return }
        if await batch.submit() {
            self.batch = nil
            errorMessage = nil
        } else {
            errorMessage = batch.errorMessage
        }
    }

    public func dismissError() { errorMessage = nil }
}
