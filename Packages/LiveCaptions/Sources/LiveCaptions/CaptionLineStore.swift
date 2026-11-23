import AppCore
import Foundation

/// The volatile to final line state machine behind `LiveSessionControlling.lines()`.
///
/// Each capture lane owns at most one volatile line. When that lane's text finalizes, the same entry (same `id`) is
/// updated in place, so earlier lines never reflow (LIVE-AC-07). Pure value type; unit-tested without audio.
struct CaptionLineStore: Sendable {
    struct Entry: Sendable {
        var line: CaptionLine
        var lane: Int
        var start: TimeInterval
        var end: TimeInterval
        var segmentID: SegmentID?
        var laneLabel: String?
    }

    /// Characters kept for a single volatile line (very long unpunctuated speech shows a rolling tail).
    static let volatileCharacterLimit = 320

    private(set) var entries: [Entry] = []
    let maxRetained: Int

    init(maxRetained: Int = 200) { self.maxRetained = max(1, maxRetained) }

    /// Rolling-window tail on a word boundary.
    static func rollingTail(_ text: String, limit: Int = volatileCharacterLimit) -> String {
        guard text.count > limit else { return text }
        let tail = text.suffix(limit)
        if let space = tail.firstIndex(of: " ") {
            return String(tail[tail.index(after: space)...])
        }
        return String(tail)
    }

    private func volatileIndex(lane: Int) -> Int? {
        entries.lastIndex { $0.lane == lane && $0.line.isVolatile }
    }

    /// Creates or updates the lane's volatile line. Returns its stable id.
    @discardableResult
    mutating func setVolatile(
        lane: Int, text: String, start: TimeInterval, language: LanguageCode?, laneLabel: String?
    ) -> UUID {
        let shown = Self.rollingTail(text)
        if let i = volatileIndex(lane: lane) {
            if entries[i].line.text != shown { entries[i].line.translation = nil }
            entries[i].line.text = shown
            entries[i].line.language = language ?? entries[i].line.language
            return entries[i].line.id
        }
        let line = CaptionLine(text: shown, speakerLabel: laneLabel, language: language, isVolatile: true)
        entries.append(Entry(line: line, lane: lane, start: start, end: start, segmentID: nil, laneLabel: laneLabel))
        trim()
        return line.id
    }

    /// Finalizes the lane's volatile line in place, or appends a new final line when none was open.
    @discardableResult
    mutating func finalize(
        lane: Int, text: String, start: TimeInterval, end: TimeInterval, language: LanguageCode?,
        segmentID: SegmentID, laneLabel: String?, reuseVolatile: Bool = true
    ) -> UUID {
        if reuseVolatile, let i = volatileIndex(lane: lane) {
            if entries[i].line.text != text { entries[i].line.translation = nil }
            entries[i].line.text = text
            entries[i].line.isVolatile = false
            entries[i].line.language = language ?? entries[i].line.language
            entries[i].start = start
            entries[i].end = end
            entries[i].segmentID = segmentID
            return entries[i].line.id
        }
        let line = CaptionLine(text: text, speakerLabel: laneLabel, language: language, isVolatile: false)
        entries.append(Entry(line: line, lane: lane, start: start, end: end, segmentID: segmentID, laneLabel: laneLabel))
        trim()
        return line.id
    }

    /// Removes the lane's volatile line (ignored/empty finals are hidden, never shown).
    mutating func removeVolatile(lane: Int) {
        if let i = volatileIndex(lane: lane) { entries.remove(at: i) }
    }

    func volatileEntry(lane: Int) -> Entry? { volatileIndex(lane: lane).map { entries[$0] } }

    mutating func setTranslation(_ text: String?, forLine id: UUID) {
        if let i = entries.firstIndex(where: { $0.line.id == id }) { entries[i].line.translation = text }
    }

    mutating func updateEntries(_ body: (inout Entry) -> Void) {
        for i in entries.indices { body(&entries[i]) }
    }

    var lines: [CaptionLine] { entries.map(\.line) }

    private mutating func trim() {
        if entries.count > maxRetained { entries.removeFirst(entries.count - maxRetained) }
    }
}

/// Live speaker labelling: maps engine-local diarizer slots to display speakers in first-appearance order, caps at
/// `maxLiveSpeakers`, and labels extras "More speakers" until the offline pass (LIVE-AC-12).
struct LiveSpeakerTimeline: Sendable {
    static let overflowLabel = "More speakers"
    private(set) var turns: [SpeakerTurn] = []
    private var order: [Int] = []  // engine slots in order of first appearance
    private(set) var limitReached = false

    /// Applies a (possibly revised) turn; a new turn supersedes older turns of the same slot that it overlaps.
    mutating func apply(_ turn: SpeakerTurn) {
        turns.removeAll { $0.slot == turn.slot && $0.range.overlap(with: turn.range) > 0 }
        turns.append(turn)
        if !order.contains(turn.slot) {
            order.append(turn.slot)
            if order.count > maxLiveSpeakers { limitReached = true }
        }
    }

    mutating func noteLimitReached() { limitReached = true }

    /// Display index (0-based) for an engine slot; `nil` for the overflow bucket.
    func displayIndex(forSlot slot: Int) -> Int? {
        guard let i = order.firstIndex(of: slot), i < maxLiveSpeakers else { return nil }
        return i
    }

    /// Slot with the greatest overlap with `range`, if any.
    func slot(for range: TimeRange) -> Int? {
        let probe = range.duration > 0 ? range : TimeRange(start: range.start, end: range.start + 1)
        var best: (slot: Int, overlap: TimeInterval)?
        for t in turns {
            let o = t.range.overlap(with: probe)
            if o > 0, o > (best?.overlap ?? 0) { best = (t.slot, o) }
        }
        return best?.slot
    }

    struct Label: Equatable, Sendable {
        var name: String
        /// Palette slot; `nil` for the overflow bucket.
        var index: Int?
    }

    static func name(forIndex index: Int) -> String { "Speaker \(index + 1)" }

    func label(for range: TimeRange) -> Label? {
        guard let s = slot(for: range) else { return nil }
        if let i = displayIndex(forSlot: s) { return Label(name: Self.name(forIndex: i), index: i) }
        return Label(name: Self.overflowLabel, index: nil)
    }

    /// Live to offline slot mapping for reconciliation once the offline pass exists (`SpeakerReconciler`).
    func reconciliation(offline: [SpeakerTurn]) -> [Int: Int] {
        SpeakerReconciler.mapLiveSlots(live: turns, offline: offline)
    }
}
