import AppCore
import Foundation
import Observation
import FeatureSupport
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
    /// UTF-16 ranges (in the NFC translation text) of matches inside the shown translation, per segment.
    var translationRanges: [SegmentID: [NSRange]] = [:]
}

/// Which text the find bar searches: what the transcript currently shows (original, translation, or both).
struct FindViewScope: Sendable, Hashable {
    var mode: TranslationDisplayMode = .original
    var target: LanguageCode?
    static let original = FindViewScope()
    var includesTranslations: Bool { mode != .original && target != nil }
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
    /// Matches inside the shown translation, for drawing (translated and bilingual modes).
    public private(set) var translationRanges: [SegmentID: [NSRange]] = [:]

    @ObservationIgnored private let editor: TranscriptEditorModel
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    public init(editor: TranscriptEditorModel) { self.editor = editor }

    public var currentMatch: FindMatch? { matches.indices.contains(currentIndex) ? matches[currentIndex] : nil }
    /// The current match's range when it lies in the translation of segment `id`; nil for original-text matches.
    public func currentTranslationRange(in id: SegmentID) -> NSRange? {
        guard let match = currentMatch, match.segmentID == id, case .translation = match.field else { return nil }
        return match.range
    }

    /// "n of m" text (FR-AC-01).
    public var statusText: String {
        if let errorMessage { return errorMessage }
        if text.isEmpty { return "" }
        return matches.isEmpty ? "No results" : "\(currentIndex + 1) of \(matches.count)"
    }
    /// Replace only ever edits the original text, so it needs an original match and a mode that shows the original.
    public var canReplace: Bool {
        !editor.isReadOnly && errorMessage == nil && matches.contains { $0.field == .text } && !replaceNeedsOriginalView
    }
    /// In Translated mode the originals are hidden; replacing them blind would edit text the user cannot see.
    public var replaceNeedsOriginalView: Bool { editor.translationChoice.mode == .translated && editor.translationChoice.target != nil }
    var viewScope: FindViewScope { FindViewScope(mode: editor.translationChoice.mode, target: editor.translationChoice.target) }

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
        translationRanges = [:]
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
            includeIgnored: editor.showIgnored, includeTranslations: viewScope.includesTranslations)
    }

    /// The query used to replace: never touches translation tracks.
    func makeReplaceQuery() -> FindQuery {
        var query = makeQuery()
        query.includeTranslations = false
        return query
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
        let scope = viewScope
        let segments = editor.segments
        searchTask = Task { [weak self] in
            if debounce > .zero { try? await Task.sleep(for: debounce) }
            guard !Task.isCancelled else { return }
            let outcome = await Task.detached(priority: .userInitiated) { Self.search(query, in: segments, view: scope) }.value
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
        let scope = viewScope
        let segments = editor.segments
        let outcome = await Task.detached(priority: .userInitiated) { Self.search(query, in: segments, view: scope) }.value
        apply(outcome, keepIndex: true)
    }

    /// Waits for a debounced search in flight.
    public func waitForSearch() async { await searchTask?.value }

    nonisolated static func search(_ query: FindQuery, in segments: [Segment], view: FindViewScope = .original) -> FindOutcome {
        let engine: FindReplaceEngine
        do { engine = try FindReplaceEngine(query: query) } catch PatternError.invalid(let message) {
            return FindOutcome(errorMessage: "Invalid regular expression: \(message)")
        } catch {
            return FindOutcome()
        }
        var matches = engine.matches(in: segments)
        if view.includesTranslations, let target = view.target {
            // Search what is shown: the translation track of the target language, plus the original where the mode shows it.
            let translated = Set(
                segments.filter { s in s.translations.contains { $0.language.primary == target.primary } }.map(\.id))
            matches = matches.filter { match in
                switch match.field {
                case .translation(let language): return language.primary == target.primary
                case .text: return view.mode == .bilingual || !translated.contains(match.segmentID)
                }
            }
        }
        var words: [SegmentID: Set<Int>] = [:]
        var ranges: [SegmentID: [NSRange]] = [:]
        for match in matches { if case .translation = match.field { ranges[match.segmentID, default: []].append(match.range) } }
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
        return FindOutcome(matches: matches, errorMessage: nil, words: words, translationRanges: ranges)
    }

    private func apply(_ outcome: FindOutcome, keepIndex: Bool) {
        matches = outcome.matches
        errorMessage = outcome.errorMessage
        matchedWords = outcome.words
        translationRanges = outcome.translationRanges
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
        guard canReplace, let match = currentMatch else { return }
        guard match.field == .text else {  // a translation match is read-only: move on to the next one
            next()
            return
        }
        guard let engine = try? FindReplaceEngine(query: makeReplaceQuery()) else { return }
        let changes = engine.replace(match, in: editor.segments, replacement: replacement)
        guard !changes.isEmpty else { return }
        editor.apply(changeSet: changes, name: "Replace")
        await searchNow()
        if let match = currentMatch { editor.reveal(match.segmentID) }
    }

    /// Computes the before → after list; nothing is applied until ``confirmReplaceAll()``.
    public func requestReplaceAll() async {
        guard canReplace, let engine = try? FindReplaceEngine(query: makeReplaceQuery()) else { return }
        let segments = editor.segments
        let replacement = replacement
        preview = await Task.detached { engine.preview(in: segments, replacement: replacement) }.value
    }

    public func cancelPreview() { preview = nil }

    /// Applies Replace All as one undoable step.
    public func confirmReplaceAll() async {
        guard preview != nil, !editor.isReadOnly, let engine = try? FindReplaceEngine(query: makeReplaceQuery()) else { return }
        preview = nil
        let changes = engine.replaceAll(in: editor.segments, replacement: replacement)
        editor.apply(changeSet: changes, name: "Replace All")
        await searchNow()
    }
}
