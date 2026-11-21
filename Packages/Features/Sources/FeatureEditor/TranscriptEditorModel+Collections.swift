import AppCore
import DesignSystem
import Foundation

// MARK: - Speakers (EDIT-AC-08)

extension TranscriptEditorModel {
    /// Renames a speaker; every segment references the ID, so the name changes across the transcript.
    public func renameSpeaker(_ id: SpeakerID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutateSpeakers(name: "Rename Speaker") { speakers in
            guard let index = speakers.firstIndex(where: { $0.id == id }), speakers[index].name != trimmed else { return false }
            speakers[index].name = trimmed
            return true
        }
    }

    public func setSpeakerColor(_ id: SpeakerID, hex: String) {
        mutateSpeakers(name: "Change Speaker Colour") { speakers in
            guard let index = speakers.firstIndex(where: { $0.id == id }), speakers[index].colorHex != hex else { return false }
            speakers[index].colorHex = hex
            return true
        }
    }

    /// Adds a speaker with the next palette colour and returns its ID.
    @discardableResult
    public func addSpeaker(named name: String) -> SpeakerID? {
        guard transcript != nil else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let speaker = Speaker(name: trimmed, colorHex: SpeakerColors.hex(forSlot: speakers.count))
        mutateSpeakers(name: "Add Speaker") { list in
            list.append(speaker)
            return true
        }
        return speaker.id
    }

    /// Merges `source` into `target`: its segments are reassigned and the speaker removed (one undo step).
    public func mergeSpeaker(_ source: SpeakerID, into target: SpeakerID) {
        guard source != target, let before = transcript?.speakers, before.contains(where: { $0.id == source }),
            before.contains(where: { $0.id == target })
        else { return }
        let changes = segments.filter { $0.speakerID == source }.map { old -> EditDelta.Replacement in
            var new = old
            new.speakerID = target
            return .init(before: old, after: new)
        }
        perform(
            EditDelta(
                name: "Merge Speakers", replaced: changes,
                speakers: .init(before: before, after: before.filter { $0.id != source })))
    }

    private func mutateSpeakers(name: String, _ change: (inout [Speaker]) -> Bool) {
        guard var list = transcript?.speakers else { return }
        let before = list
        guard change(&list) else { return }
        perform(EditDelta(name: name, speakers: .init(before: before, after: list)))
    }

    /// Number of segments spoken by `id`.
    public func segmentCount(for id: SpeakerID) -> Int { segments.filter { $0.speakerID == id }.count }

    /// Colour spec for a speaker (stored hex, else the palette slot of its position).
    public func color(for id: SpeakerID?) -> SpeakerColorSpec {
        guard let id, let index = speakers.firstIndex(where: { $0.id == id }) else { return .slot(0) }
        return speakers[index].colorHex.isEmpty ? .slot(index) : .hex(speakers[index].colorHex, fallbackSlot: index)
    }
}

/// How to colour a speaker: a stored hex, or the palette slot.
public enum SpeakerColorSpec: Hashable, Sendable {
    case hex(String, fallbackSlot: Int)
    case slot(Int)
}

public enum SpeakerColors {
    /// Light-appearance hex of palette slot `slot` (used as the default `Speaker.colorHex`).
    public static func hex(forSlot slot: Int) -> String {
        let c = SpeakerPalette.entry(forSlot: slot).light
        func byte(_ v: Double) -> Int { Int((v * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c.r), byte(c.g), byte(c.b))
    }

    /// The palette as hex strings for the colour picker.
    public static var paletteHexes: [String] { (0..<SpeakerPalette.entries.count).map(hex(forSlot:)) }

    /// RGB components of `#RRGGBB`, or nil if malformed.
    public static func rgb(hex: String) -> (r: Double, g: Double, b: Double)? {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = Int(text, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }
}

// MARK: - Bookmarks and highlights (EDIT-AC-13)

extension TranscriptEditorModel {
    /// A bookmark at `time` (the playhead by default) with an optional note.
    @discardableResult
    public func addBookmark(at time: TimeInterval? = nil, note: String = "") -> TranscriptBookmark {
        let bookmark = TranscriptBookmark(transcriptID: transcriptID, time: time ?? playback.currentTime, note: note)
        bookmarks.append(bookmark)
        bookmarks.sort { $0.time < $1.time }
        saveBookmark(bookmark)
        return bookmark
    }

    public func updateBookmark(_ id: BookmarkID, note: String) {
        guard let index = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        bookmarks[index].note = note
        saveBookmark(bookmarks[index])
    }

    /// Soft-deletes the bookmark.
    public func removeBookmark(_ id: BookmarkID) {
        guard let index = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        var removed = bookmarks.remove(at: index)
        removed.deletedAt = Date()
        saveBookmark(removed)
    }

    private func saveBookmark(_ bookmark: TranscriptBookmark) {
        let repository = repository
        enqueueIO { [weak self] in
            do { try await repository.save(bookmark) } catch { await self?.setPersistenceError(error.localizedDescription) }
        }
    }

    /// Seeks to a bookmark and scrolls the transcript to it.
    public func go(to bookmark: TranscriptBookmark) {
        playback.seek(to: bookmark.time)
        if let hit = segments.last(where: { $0.start <= bookmark.time }) { reveal(hit.id) }
    }

    @discardableResult
    public func addHighlight(segmentID: SegmentID, wordRange: ClosedRange<Int>? = nil, note: String = "") -> TextHighlight? {
        guard let segment = segment(segmentID) else { return nil }
        var time = segment.start
        if let first = wordRange?.lowerBound, segment.words.indices.contains(first) { time = segment.words[first].start }
        let highlight = TextHighlight(segmentID: segmentID, wordRange: wordRange, note: note, time: time)
        highlights.append(highlight)
        saveHighlights()
        return highlight
    }

    public func updateHighlight(_ id: UUID, note: String) {
        guard let index = highlights.firstIndex(where: { $0.id == id }) else { return }
        highlights[index].note = note
        saveHighlights()
    }

    public func removeHighlight(_ id: UUID) {
        highlights.removeAll { $0.id == id }
        saveHighlights()
    }

    public func highlights(in segmentID: SegmentID) -> [TextHighlight] { highlights.filter { $0.segmentID == segmentID } }

    private func saveHighlights() {
        let value = highlights
        let key = EditorSettingsKey.highlights(transcriptID)
        saveSetting(value, for: key)
    }
}
