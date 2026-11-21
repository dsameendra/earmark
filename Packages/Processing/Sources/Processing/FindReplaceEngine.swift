import AppCore
import Foundation

/// Which segments a find/replace operation considers (FR-AC-03).
public enum FindScope: Sendable, Hashable {
    case all
    case selection(Set<SegmentID>)
    /// Segments of one speaker (nil = segments without a speaker).
    case speaker(SpeakerID?)
    /// Segments whose language equals the code (or shares its primary subtag).
    case language(LanguageCode)
}

/// A find request (FR-AC-02).
public struct FindQuery: Sendable, Hashable {
    public var text: String
    public var matchCase: Bool
    public var wholeWord: Bool
    public var isRegex: Bool
    public var scope: FindScope
    /// Ignored segments are excluded unless "Show ignored" is on.
    public var includeIgnored: Bool
    /// Also search translation tracks (off by default).
    public var includeTranslations: Bool

    public init(
        text: String, matchCase: Bool = false, wholeWord: Bool = false, isRegex: Bool = false, scope: FindScope = .all,
        includeIgnored: Bool = false, includeTranslations: Bool = false
    ) {
        self.text = text
        self.matchCase = matchCase
        self.wholeWord = wholeWord
        self.isRegex = isRegex
        self.scope = scope
        self.includeIgnored = includeIgnored
        self.includeTranslations = includeTranslations
    }
}

/// Where in a segment a match lives.
public enum FindField: Sendable, Hashable {
    case text
    case translation(LanguageCode)
}

/// One match. Matches never span segments.
public struct FindMatch: Sendable, Hashable {
    public var segmentID: SegmentID
    public var field: FindField
    /// UTF-16 range in the NFC form of the field's text.
    public var range: NSRange
    public var matched: String
}

/// A before/after pair for the Replace All preview (FR-AC-04).
public struct ReplacePreview: Sendable, Hashable {
    public var segmentID: SegmentID
    public var before: String
    public var after: String
    public var matchCount: Int
}

/// A replacement outcome for one segment, with enough state to undo exactly.
public struct SegmentChange: Sendable, Hashable {
    public var before: Segment
    public var after: Segment
}

/// An undoable set of segment changes. One Replace All is one change set, i.e. one undo step (FR-AC-06).
public struct ChangeSet: Sendable, Hashable {
    public var changes: [SegmentChange]
    public init(changes: [SegmentChange] = []) { self.changes = changes }
    public var isEmpty: Bool { changes.isEmpty }
    /// Number of segments changed.
    public var count: Int { changes.count }

    /// `segments` with every change applied (matched by segment ID).
    public func applied(to segments: [Segment]) -> [Segment] {
        let map = Dictionary(changes.map { ($0.after.id, $0.after) }, uniquingKeysWith: { _, last in last })
        return segments.map { map[$0.id] ?? $0 }
    }

    /// `segments` with every change reverted; restores text, words and flags exactly.
    public func undone(on segments: [Segment]) -> [Segment] {
        let map = Dictionary(changes.map { ($0.before.id, $0.before) }, uniquingKeysWith: { _, last in last })
        return segments.map { map[$0.id] ?? $0 }
    }

    /// The change set that undoes this one (redo is `inverted.inverted`).
    public var inverted: ChangeSet {
        ChangeSet(changes: changes.map { SegmentChange(before: $0.after, after: $0.before) })
    }
}

/// In-transcript find and replace (FR-AC-02...08, 16). Pure and deterministic; run it off the main actor.
public struct FindReplaceEngine: Sendable {
    public let query: FindQuery
    private let pattern: CompiledPattern

    /// - Throws: ``PatternError`` for an empty or invalid pattern (inline error, no search performed).
    public init(query: FindQuery) throws {
        self.query = query
        self.pattern = try CompiledPattern(
            pattern: query.text, matchCase: query.matchCase, wholeWord: query.wholeWord, isRegex: query.isRegex)
    }

    /// Whether `segment` is in the query's scope.
    public func isInScope(_ segment: Segment) -> Bool {
        if segment.isIgnored && !query.includeIgnored { return false }
        switch query.scope {
        case .all: return true
        case .selection(let ids): return ids.contains(segment.id)
        case .speaker(let speaker): return segment.speakerID == speaker
        case .language(let code):
            guard let language = segment.languageCode else { return false }
            return language == code || language.primary == code.primary
        }
    }

    /// All matches in scope, in document order.
    public func matches(in segments: [Segment]) -> [FindMatch] {
        var out: [FindMatch] = []
        for segment in segments where isInScope(segment) {
            out += matches(in: segment)
        }
        return out
    }

    private func matches(in segment: Segment) -> [FindMatch] {
        var out: [FindMatch] = []
        let text = TextNormalizer.nfc(segment.text)
        for result in pattern.matches(in: text) {
            out.append(
                FindMatch(
                    segmentID: segment.id, field: .text, range: result.range, matched: (text as NSString).substring(with: result.range)))
        }
        if query.includeTranslations {
            for translation in segment.translations {
                let tText = TextNormalizer.nfc(translation.text)
                for result in pattern.matches(in: tText) {
                    out.append(
                        FindMatch(
                            segmentID: segment.id, field: .translation(translation.language), range: result.range,
                            matched: (tText as NSString).substring(with: result.range)))
                }
            }
        }
        return out
    }

    /// The before → after list shown before Replace All is confirmed.
    public func preview(in segments: [Segment], replacement: String) -> [ReplacePreview] {
        replaceAll(in: segments, replacement: replacement).changes.map { change in
            let count = matches(in: change.before).count
            return ReplacePreview(segmentID: change.before.id, before: change.before.text, after: change.after.text, matchCount: count)
        }
    }

    /// Replaces every in-scope match. `$1`-style capture groups are expanded in regex mode; `$` is literal otherwise.
    public func replaceAll(in segments: [Segment], replacement: String) -> ChangeSet {
        var changes: [SegmentChange] = []
        for segment in segments where isInScope(segment) {
            let all = matches(in: segment)
            guard !all.isEmpty else { continue }
            let updated = replacing(all, in: segment, replacement: replacement)
            if updated != segment { changes.append(SegmentChange(before: segment, after: updated)) }
        }
        return ChangeSet(changes: changes)
    }

    /// Replaces a single match (the current one); the caller then advances to the next match.
    public func replace(_ match: FindMatch, in segments: [Segment], replacement: String) -> ChangeSet {
        guard let segment = segments.first(where: { $0.id == match.segmentID }), isInScope(segment),
            let target = matches(in: segment).first(where: { $0.field == match.field && $0.range == match.range })
        else { return ChangeSet() }
        let updated = replacing([target], in: segment, replacement: replacement)
        return updated == segment ? ChangeSet() : ChangeSet(changes: [SegmentChange(before: segment, after: updated)])
    }

    private func replacing(_ targets: [FindMatch], in segment: Segment, replacement: String) -> Segment {
        var result = segment
        let text = TextNormalizer.nfc(segment.text)
        let textEdits = expand(targets.filter { $0.field == .text }, in: text, replacement: replacement)
        if !textEdits.isEmpty { result = SegmentEditor.apply(textEdits, to: result) }
        for index in result.translations.indices {
            let language = result.translations[index].language
            let mine = targets.filter { $0.field == .translation(language) }
            guard !mine.isEmpty else { continue }
            let tText = TextNormalizer.nfc(result.translations[index].text)
            result.translations[index].text = SegmentEditor.applyToText(expand(mine, in: tText, replacement: replacement), text: tText)
        }
        return result
    }

    private func expand(_ targets: [FindMatch], in text: String, replacement: String) -> [TextEdit] {
        guard !targets.isEmpty else { return [] }
        let wanted = Set(targets.map { RangeKey($0.range) })
        return pattern.matches(in: text).filter { wanted.contains(RangeKey($0.range)) }.map {
            TextEdit(range: $0.range, replacement: pattern.replacement(replacement, for: $0, in: text))
        }
    }

    private struct RangeKey: Hashable {
        var location: Int
        var length: Int
        init(_ range: NSRange) {
            location = range.location
            length = range.length
        }
    }
}
