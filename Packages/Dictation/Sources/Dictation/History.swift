import AppCore
import Foundation
import Observation

/// Dictation history on top of `DictationHistoryRepository` (DICT-AC-11). Searchable, limited to the last N, clearable.
public struct DictationHistory: Sendable {
    private let repository: any DictationHistoryRepository
    public init(repository: any DictationHistoryRepository) { self.repository = repository }

    /// Saves an inserted entry unless history is disabled. Returns whether an entry was written.
    @discardableResult
    public func record(_ text: String, language: LanguageCode?, settings: DictationSettings, now: Date = Date()) async -> Bool {
        guard settings.historyEnabled, !text.isEmpty else { return false }
        do {
            try await repository.save(DictationEntry(text: text, language: language, createdAt: now))
            return true
        } catch { return false }
    }

    public func entries(matching query: String?, limit: Int) async -> [DictationEntry] {
        let q = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = (try? await repository.recent(limit: limit, matching: (q?.isEmpty ?? true) ? nil : q)) ?? []
        return rows.filter { $0.deletedAt == nil }
    }

    public func clear() async { try? await repository.clear() }
}

/// View model for the history list: search text in, entries out.
@MainActor @Observable
public final class DictationHistoryModel {
    public var query = ""
    public private(set) var entries: [DictationEntry] = []
    public var limit: Int
    public let emptySystemImage = "waveform"
    private let history: DictationHistory

    public init(history: DictationHistory, limit: Int = 200) {
        self.history = history
        self.limit = limit
    }

    public func reload() async { entries = await history.entries(matching: query, limit: limit) }

    public func clear() async {
        await history.clear()
        entries = []
    }
}
