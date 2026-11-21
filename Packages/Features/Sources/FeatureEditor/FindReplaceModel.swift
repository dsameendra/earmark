import AppCore
import Foundation
import Observation
import Processing

/// Scope choices in the find bar (FR-AC-03).
public enum FindScopeChoice: Hashable, Sendable {
    case all
    case selection
    case speaker(SpeakerID?)
    case language(LanguageCode)
}

/// Result of one background search.
struct FindOutcome: Sendable {
    var matches: [FindMatch] = []
    var errorMessage: String?
    /// Words (by display index) covered by matches, per segment, for highlighting.
    var words: [SegmentID: Set<Int>] = [:]
}

/// In-transcript find (⌘F) and replace (⌥⌘F) backed by `Processing.FindReplaceEngine` (EDIT-AC-11, FR-AC-01...09).
///
/// Matching runs off the main actor and is debounced by 150 ms (FR-AC-09). A Replace All shows a preview first and is a
/// single undo step.
@MainActor @Observable
public final class FindReplaceModel {
    public static let debounce: Duration = .milliseconds(150)

    public private(set) var isVisible = false
    public private(set) var showsReplace = false
    public var text = "" { didSet { if text != oldValue { scheduleSearch() } } }
    public var replacement = ""
    public var matchCase = false { didSet { if matchCase != oldValue { scheduleSearch() } } }
    public var wholeWord = false { didSet { if wholeWord != oldValue { scheduleSearch() } } }
    public var isRegex = false { didSet { if isRegex != oldValue { scheduleSearch() } } }
    public var scope: FindScopeChoice = .all { didSet { if scope != oldValue { scheduleSearch() } } }

    public private(set) var matches: [FindMatch] = []
    public private(set) var currentIndex = 0
    /// Inline error (invalid regex); no search is performed while set (FR-AC-02).
    public private(set) var errorMessage: String?
    public private(set) var preview: [ReplacePreview]?
    public private(set) var matchedWords: [SegmentID: Set<Int>] = [:]

    @ObservationIgnored private let editor: TranscriptEditorModel
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    public init(editor: TranscriptEditorModel) { self.editor = editor }

    public var currentMatch: FindMatch? { matches.indices.contains(currentIndex) ? matches[currentIndex] : nil }
    /// "n of m" text (FR-AC-01).
    public var statusText: String {
        if let errorMessage { return errorMessage }
        if text.isEmpty { return "" }
        return matches.isEmpty ? "No results" : "\(currentIndex + 1) of \(matches.count)"
    }
    public var canReplace: Bool { !editor.isReadOnly && !matches.isEmpty && errorMessage == nil }

    // MARK: Presentation

    /// ⌘F opens find; ⌥⌘F also reveals the replace field.
    public func open(replace: Bool = false) {
        isVisible = true
        if replace { showsReplace = true }
        scheduleSearch(debounce: .zero)
    }

    public func close() {
        isVisible = false
        showsReplace = false
        preview = nil
        searchTask?.cancel()
        matches = []
        matchedWords = [:]
    }

    public func toggleReplace() { showsReplace.toggle() }

    // MARK: Searching

    func makeQuery() -> FindQuery {
        let scopeValue: FindScope =
            switch scope {
            case .all: .all
            case .selection: .selection(editor.selection)
            case .speaker(let id): .speaker(id)
            case .language(let code): .language(code)
            }
        return FindQuery(
            text: text, matchCase: matchCase, wholeWord: wholeWord, isRegex: isRegex, scope: scopeValue,
            includeIgnored: editor.showIgnored)
    }

    /// Re-runs the search after the document or the selection changed.
    public func refresh() {
        guard isVisible else { return }
        scheduleSearch()
    }

    private func scheduleSearch(debounce: Duration = FindReplaceModel.debounce) {
        searchTask?.cancel()
        guard !text.isEmpty else {
            apply(FindOutcome(), keepIndex: false)
            return
        }
        let query = makeQuery()
        let segments = editor.segments
        searchTask = Task { [weak self] in
            if debounce > .zero { try? await Task.sleep(for: debounce) }
            guard !Task.isCancelled else { return }
            let outcome = await Task.detached(priority: .userInitiated) { Self.search(query, in: segments) }.value
            guard !Task.isCancelled else { return }
            self?.apply(outcome, keepIndex: true)
        }
    }

    /// Runs the search now and waits for it (used after replacements and by tests).
    public func searchNow() async {
        searchTask?.cancel()
        guard !text.isEmpty else {
            apply(FindOutcome(), keepIndex: false)
            return
        }
        let query = makeQuery()
        let segments = editor.segments
        let outcome = await Task.detached(priority: .userInitiated) { Self.search(query, in: segments) }.value
        apply(outcome, keepIndex: true)
    }

    /// Waits for a debounced search in flight.
    public func waitForSearch() async { await searchTask?.value }

    nonisolated static func search(_ query: FindQuery, in segments: [Segment]) -> FindOutcome {
        let engine: FindReplaceEngine
        do { engine = try FindReplaceEngine(query: query) } catch PatternError.invalid(let message) {
            return FindOutcome(errorMessage: "Invalid regular expression: \(message)")
        } catch {
            return FindOutcome()
        }
        let matches = engine.matches(in: segments)
        var words: [SegmentID: Set<Int>] = [:]
        let byID = Dictionary(segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for match in matches where match.field == .text {
            guard let segment = byID[match.segmentID] else { continue }
            let text = TextNormalizer.nfc(segment.text)
            let display = segment.words.isEmpty ? SegmentOps.synthesizedWords(for: segment) : segment.words
            guard let ranges = SegmentOps.wordRanges(in: text, words: display) else { continue }
            for (index, range) in ranges.enumerated() where NSIntersectionRange(range, match.range).length > 0 {
                words[match.segmentID, default: []].insert(index)
            }
        }
        return FindOutcome(matches: matches, errorMessage: nil, words: words)
    }

    private func apply(_ outcome: FindOutcome, keepIndex: Bool) {
        matches = outcome.matches
        errorMessage = outcome.errorMessage
        matchedWords = outcome.words
        currentIndex = keepIndex ? min(currentIndex, max(0, matches.count - 1)) : 0
    }

    // MARK: Stepping (FR-AC-01)

    public func next() { step(1) }
    public func previous() { step(-1) }

    private func step(_ delta: Int) {
        guard !matches.isEmpty else { return }
        currentIndex = (currentIndex + delta + matches.count) % matches.count
        if let match = currentMatch { editor.reveal(match.segmentID) }
    }

    // MARK: Replace (FR-AC-04...06)

    /// Replaces the current match and advances.
    public func replaceCurrent() async {
        guard canReplace, let match = currentMatch, let engine = try? FindReplaceEngine(query: makeQuery()) else { return }
        let changes = engine.replace(match, in: editor.segments, replacement: replacement)
        guard !changes.isEmpty else { return }
        editor.apply(changeSet: changes, name: "Replace")
        await searchNow()
        if let match = currentMatch { editor.reveal(match.segmentID) }
    }

    /// Computes the before → after list; nothing is applied until ``confirmReplaceAll()``.
    public func requestReplaceAll() async {
        guard canReplace, let engine = try? FindReplaceEngine(query: makeQuery()) else { return }
        let segments = editor.segments
        let replacement = replacement
        preview = await Task.detached { engine.preview(in: segments, replacement: replacement) }.value
    }

    public func cancelPreview() { preview = nil }

    /// Applies Replace All as one undoable step.
    public func confirmReplaceAll() async {
        guard preview != nil, !editor.isReadOnly, let engine = try? FindReplaceEngine(query: makeQuery()) else { return }
        preview = nil
        let changes = engine.replaceAll(in: editor.segments, replacement: replacement)
        editor.apply(changeSet: changes, name: "Replace All")
        await searchNow()
    }
}
