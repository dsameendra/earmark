import AppCore
import FeatureSupport
import Foundation
import Observation

/// The notes page of one transcript: written by hand, autosaved, versioned, and (when asked) replaced by a summary.
@MainActor @Observable
public final class NotesModel {
    public enum SummaryState: Equatable {
        case idle
        case running(fraction: Double, detail: String)
        case failed(String)
    }

    public var markdown: String = "" {
        didSet {
            guard markdown != oldValue, isLoaded, !isApplying else { return }
            scheduleSave()
        }
    }
    public private(set) var isLoaded = false
    public private(set) var versions: [NotesVersion] = []
    public private(set) var summaryState: SummaryState = .idle
    /// Parts the system declined to process during the last summary.
    public private(set) var skippedParts: [Int] = []
    /// True from the moment a summary replaced the page until the user dismisses the notice or edits further.
    public private(set) var showsSummaryNotice = false
    public private(set) var summarizedAt: Date?
    public var style: SummaryStyle = .meeting
    public var includeNotes = true
    public var includeFiles = true
    public private(set) var errorMessage: String?

    public let transcriptID: TranscriptID
    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var summaryTask: Task<Void, Never>?
    @ObservationIgnored private var isApplying = false
    @ObservationIgnored private var summaryStyle: SummaryStyle?

    public init(transcriptID: TranscriptID, services: AppServices) {
        self.transcriptID = transcriptID
        self.services = services
    }

    public var isSummarizing: Bool {
        if case .running = summaryState { return true }
        return false
    }

    // MARK: Loading and saving

    public func load() async {
        let stored = try? await services.workspace.notes.notes(for: transcriptID)
        apply(stored?.markdown ?? "")
        summarizedAt = stored?.summarizedAt
        summaryStyle = stored?.summaryStyle
        versions = (try? await services.workspace.notes.versions(for: transcriptID)) ?? []
        if let raw = await services.settings.value(for: SettingsKey.intelligenceSummaryStyle, as: String.self), let value = SummaryStyle(rawValue: raw) {
            style = value
        }
        includeNotes = await services.settings.value(for: SettingsKey.intelligenceIncludeNotes, as: Bool.self) ?? true
        includeFiles = await services.settings.value(for: SettingsKey.intelligenceIncludeFiles, as: Bool.self) ?? true
        isLoaded = true
    }

    /// Picks the summary style a transcript starts with: its stored default, otherwise by where it came from.
    public func suggestStyle(for source: TranscriptSource) async {
        let raw = await services.settings.value(for: SettingsKey.intelligenceSummaryStyle, as: String.self)
        if let raw, let value = SummaryStyle(rawValue: raw) { style = value } else { style = source == .meeting ? .meeting : .general }
    }

    private func apply(_ text: String) {
        isApplying = true
        markdown = text
        isApplying = false
    }

    private func scheduleSave() {
        showsSummaryNotice = false
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await self?.save()
        }
    }

    /// Writes the page now (leaving the page, summarising, closing the window).
    public func flush() async {
        saveTask?.cancel()
        saveTask = nil
        guard isLoaded else { return }
        await save()
    }

    private func save() async {
        let notes = TranscriptNotes(
            transcriptID: transcriptID, markdown: markdown, updatedAt: Date(), summarizedAt: summarizedAt, summaryStyle: summaryStyle)
        do {
            try await services.workspace.notes.save(notes)
            services.workspace.events.send(.notesChanged(transcriptID))
        } catch {
            errorMessage = String(describing: error)
        }
    }

    // MARK: Summary

    /// Replaces the page with a summary of the transcript (and, when switched on, the notes already on the page and attached
    /// files). The page as it was is saved as a version first, so nothing the user wrote is lost.
    public func summarize() {
        guard !isSummarizing, let intelligence = services.workspace.intelligence else { return }
        summaryTask?.cancel()
        errorMessage = nil
        skippedParts = []
        summaryState = .running(fraction: 0, detail: "Preparing")
        let request = SummaryRequest(
            transcriptID: transcriptID, style: style, notesMarkdown: markdown, includeNotes: includeNotes, includeFiles: includeFiles)
        let chosen = style
        summaryTask = Task { [weak self] in
            guard let self else { return }
            await flush()
            let before = markdown
            do {
                for try await event in intelligence.summarize(request) {
                    switch event {
                    case .progress(let fraction, let detail): summaryState = .running(fraction: fraction, detail: detail)
                    case .skipped(let part): skippedParts.append(part)
                    case .finished(let result):
                        let version = NotesVersion(transcriptID: transcriptID, markdown: before, reason: .beforeSummary)
                        try await services.workspace.notes.save(version)
                        summarizedAt = Date()
                        summaryStyle = chosen
                        apply(result)
                        await save()
                        versions = (try? await services.workspace.notes.versions(for: transcriptID)) ?? []
                        showsSummaryNotice = true
                        summaryState = .idle
                    }
                }
                if case .running = summaryState { summaryState = .idle }
            } catch IntelligenceError.cancelled {
                summaryState = .idle
            } catch is CancellationError {
                summaryState = .idle
            } catch {
                summaryState = .failed(Self.describe(error))
            }
        }
    }

    public func cancelSummary() {
        summaryTask?.cancel()
        summaryState = .idle
    }

    public func dismissSummaryNotice() { showsSummaryNotice = false }
    public func dismissFailure() { if case .failed = summaryState { summaryState = .idle } }

    /// The page as it was before the last summary.
    public var versionBeforeSummary: NotesVersion? { versions.first { $0.reason == .beforeSummary } }

    public func undoSummary() async {
        guard let version = versionBeforeSummary else { return }
        await restore(version)
        showsSummaryNotice = false
    }

    /// Puts an earlier version back. The page as it is now is kept as a version too.
    public func restore(_ version: NotesVersion) async {
        await flush()
        let current = NotesVersion(transcriptID: transcriptID, markdown: markdown, reason: .beforeRestore)
        try? await services.workspace.notes.save(current)
        apply(version.markdown)
        await save()
        versions = (try? await services.workspace.notes.versions(for: transcriptID)) ?? []
    }

    /// A manual checkpoint of the page.
    public func saveCheckpoint() async {
        await flush()
        try? await services.workspace.notes.save(NotesVersion(transcriptID: transcriptID, markdown: markdown, reason: .checkpoint))
        versions = (try? await services.workspace.notes.versions(for: transcriptID)) ?? []
    }

    static func describe(_ error: any Error) -> String {
        if let known = error as? IntelligenceError {
            switch known {
            case .unavailable(let reason): return IntelligenceCopy.explain(reason)
            case .languageNotSupported(let code): return IntelligenceCopy.languageNotSupported(code)
            case .cancelled: return "Cancelled."
            case .declined: return "The system declined to summarise this text."
            case .failed(let message): return message
            }
        }
        return String(describing: error)
    }

    // MARK: Timestamps

    /// "[12:52]": a link in the notes that jumps playback back to that moment.
    public static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "[%d:%02d:%02d]", h, m, s) : String(format: "[%02d:%02d]", m, s)
    }
}

/// Plain-language wording for what the on-device model needs.
public enum IntelligenceCopy {
    public static func explain(_ reason: IntelligenceAvailability.Reason) -> String {
        switch reason {
        case .deviceNotEligible: "This Mac does not support Apple Intelligence, so summaries and chat are not available. Notes, folders and slides still work."
        case .notEnabled: "Turn on Apple Intelligence in System Settings to summarise and chat. Notes, folders and slides work without it."
        case .modelNotReady: "macOS is still preparing Apple Intelligence. Summaries and chat will be available when it finishes."
        case .osTooOld: "Summaries and chat need macOS 26 with Apple Intelligence."
        case .other(let text): "Apple Intelligence is not available right now (\(text))."
        }
    }

    public static func languageNotSupported(_ code: String) -> String {
        let name = Locale.current.localizedString(forLanguageCode: code) ?? code
        return "Apple's on-device model cannot work with \(name) yet. You can still write notes, attach slides and use the transcript as normal."
    }
}
