import AppCore
import Foundation

/// One exported unit of text: a segment, or several merged segments, after filtering, translation and time mapping.
struct Entry: Sendable, Hashable {
    var start: TimeInterval
    var end: TimeInterval
    var speakerID: SpeakerID?
    var speaker: Speaker?
    var language: LanguageCode?
    var text: String
    /// Second line of a bilingual export (the translation track).
    var translation: String?
    var translationLanguage: LanguageCode?
    var words: [Word]
}

/// A group of entries rendered together in document formats.
struct Paragraph: Sendable {
    var speaker: Speaker?
    var items: [Item]

    struct Item: Sendable {
        var entry: Entry
        /// When non-nil a timestamp is emitted before this item.
        var stamp: TimeInterval?
    }
}

/// Shared preparation applied identically by every exporter (EXP-AC-02, 03, 05, 06, 08, 19).
enum ExportPipeline {
    /// Consecutive same-speaker segments no further apart than this are merged / grouped (EXP-AC-05).
    static let mergeGap: TimeInterval = 2.0

    static func fail(_ reason: String) -> AppError { .exportFailed(reason: reason) }

    /// Validates options (EXP-AC-19) with user-readable reasons.
    static func validate(_ options: ExportOptions, supported: Set<ExportFormat>) throws {
        guard supported.contains(options.format) else { throw fail("This exporter does not support the \(options.format.rawValue) format.") }
        if options.translation != .none, options.translationLanguage == nil {
            throw fail("Choose a translation language to export a translated or bilingual transcript.")
        }
        if let range = options.timeRange, !(range.end > range.start) || range.start < 0 {
            throw fail("The time range to export is empty or invalid.")
        }
        if case .everyNSeconds(let n) = options.timestamps, n <= 0 {
            throw fail("The timestamp interval must be at least one second.")
        }
        let s = options.subtitle
        if s.maxCharsPerLine < 1 || s.maxLinesPerCue < 1 {
            throw fail("Subtitle limits must allow at least one character and one line.")
        }
        if s.minCueDuration < 0 || s.maxCueDuration <= 0 || s.minCueDuration > s.maxCueDuration || s.minGap < 0 {
            throw fail("Subtitle durations are inconsistent (minimum must not exceed maximum).")
        }
    }

    /// Segments after ignored-filtering, time-range clipping and re-basing, offsetting and sorting. Words move with them.
    static func segments(_ document: TranscriptDocument, options: ExportOptions) -> [Segment] {
        var out: [Segment] = []
        out.reserveCapacity(document.segments.count)
        for original in document.segments {
            if original.isIgnored && !options.includeIgnored { continue }
            var seg = original
            if let range = options.timeRange {
                let intersects = seg.end > range.start && seg.start < range.end || (seg.start == seg.end && seg.start >= range.start && seg.start < range.end)
                guard intersects else { continue }
                seg.start = max(seg.start, range.start) - range.start
                seg.end = min(seg.end, range.end) - range.start
                seg.words = seg.words.map { shifted($0, by: -range.start) }
            }
            if options.timeOffset != 0 {
                seg.start = max(0, seg.start + options.timeOffset)
                seg.end = max(seg.start, seg.end + options.timeOffset)
                seg.words = seg.words.map { shifted($0, by: options.timeOffset) }
            }
            seg.end = max(seg.start, seg.end)
            out.append(seg)
        }
        return out.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
    }

    private static func shifted(_ word: Word, by delta: TimeInterval) -> Word {
        var copy = word
        copy.start = max(0, word.start + delta)
        copy.end = max(copy.start, word.end + delta)
        return copy
    }

    /// Entries for text-oriented formats: translation applied, empty text dropped, same-speaker merging.
    static func entries(_ document: TranscriptDocument, options: ExportOptions) -> [Entry] {
        let speakers = Dictionary(document.transcript.speakers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var entries: [Entry] = []
        for seg in segments(document, options: options) {
            var entry = Entry(
                start: seg.start, end: seg.end, speakerID: seg.speakerID, speaker: seg.speakerID.flatMap { speakers[$0] },
                language: seg.languageCode, text: seg.text, translation: nil, translationLanguage: nil, words: seg.words)
            if options.translation != .none, let target = options.translationLanguage {
                let match = seg.translations.first { $0.language == target } ?? seg.translations.first { $0.language.primary == target.primary }
                switch options.translation {
                case .replace:
                    if let match {
                        entry.text = match.text
                        entry.language = match.language
                        entry.words = []
                    }
                case .bilingual:
                    if let match {
                        entry.translation = match.text
                        entry.translationLanguage = match.language
                    }
                case .none: break
                }
            }
            if entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            entries.append(entry)
        }
        return options.mergeSameSpeaker ? merge(entries) : entries
    }

    /// Merges consecutive same-speaker entries with a gap <= ``mergeGap``. Entries in different languages stay separate
    /// so per-segment `lang` tagging stays accurate.
    static func merge(_ entries: [Entry]) -> [Entry] {
        var out: [Entry] = []
        for entry in entries {
            if var last = out.last, last.speakerID == entry.speakerID, entry.start - last.end <= mergeGap,
                last.language == entry.language || last.language == nil || entry.language == nil
            {
                last.end = max(last.end, entry.end)
                last.text += " " + entry.text
                last.language = last.language ?? entry.language
                if let t = entry.translation { last.translation = last.translation.map { $0 + " " + t } ?? t }
                last.words += entry.words
                out[out.count - 1] = last
            } else {
                out.append(entry)
            }
        }
        return out
    }

    /// Paragraphs with timestamps placed per ``TimestampStyle`` (EXP-AC-03).
    static func paragraphs(_ entries: [Entry], options: ExportOptions) -> [Paragraph] {
        var groups: [[Entry]] = []
        for entry in entries {
            if options.paragraphGrouping, let last = groups.last?.last, last.speakerID == entry.speakerID,
                entry.start - last.end <= mergeGap
            {
                groups[groups.count - 1].append(entry)
            } else {
                groups.append([entry])
            }
        }
        var lastBucket = -1
        return groups.map { group in
            var items: [Paragraph.Item] = []
            for (index, entry) in group.enumerated() {
                var stamp: TimeInterval?
                switch options.timestamps {
                case .none: stamp = nil
                case .perSegment: stamp = entry.start
                case .perParagraph: stamp = index == 0 ? entry.start : nil
                case .everyNSeconds(let n):
                    let bucket = Int((max(0, entry.start) / Double(n)).rounded(.down))
                    if bucket > lastBucket {
                        stamp = Double(bucket * n)
                        lastBucket = bucket
                    }
                }
                items.append(Paragraph.Item(entry: entry, stamp: stamp))
            }
            return Paragraph(speaker: group[0].speaker, items: items)
        }
    }

    /// The document's dominant language (most frequent entry language), else the first transcript language, else English.
    static func primaryLanguage(_ document: TranscriptDocument, entries: [Entry]) -> LanguageCode {
        var counts: [LanguageCode: Int] = [:]
        for entry in entries { if let l = entry.language { counts[l, default: 0] += 1 } }
        if let best = counts.sorted(by: { ($1.value, $0.key) < ($0.value, $1.key) }).first { return best.key }
        return document.transcript.languages.sorted().first ?? .english
    }
}

// MARK: - Formatting helpers

enum Format {
    static func ms(_ seconds: TimeInterval) -> Int { max(0, Int((seconds * 1000).rounded())) }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let s = String(value)
        return String(repeating: "0", count: max(0, width - s.count)) + s
    }

    /// `HH:MM:SS` plus `sep` and milliseconds.
    static func clock(ms: Int, separator: String, hourWidth: Int = 2) -> String {
        "\(pad(ms / 3_600_000, hourWidth)):\(pad(ms / 60_000 % 60, 2)):\(pad(ms / 1000 % 60, 2))\(separator)\(pad(ms % 1000, 3))"
    }
    static func srt(_ ms: Int) -> String { clock(ms: ms, separator: ",") }
    static func vtt(_ ms: Int) -> String { clock(ms: ms, separator: ".") }
    static func sbv(_ ms: Int) -> String { clock(ms: ms, separator: ".", hourWidth: 1) }

    /// ASS `H:MM:SS.cc`.
    static func ass(_ ms: Int) -> String {
        let cs = (ms + 5) / 10
        return "\(cs / 360_000):\(pad(cs / 6000 % 60, 2)):\(pad(cs / 100 % 60, 2)).\(pad(cs % 100, 2))"
    }

    /// LRC `mm:ss.xx` (minutes are not capped at 59).
    static func lrc(_ ms: Int) -> String {
        let cs = (ms + 5) / 10
        return "\(pad(cs / 6000, 2)):\(pad(cs / 100 % 60, 2)).\(pad(cs % 100, 2))"
    }

    /// Whole-second `HH:MM:SS` for documents.
    static func stamp(_ seconds: TimeInterval) -> String {
        let total = ms(seconds) / 1000
        return "\(pad(total / 3600, 2)):\(pad(total / 60 % 60, 2)):\(pad(total % 60, 2))"
    }

    /// Seconds with exactly three decimals, via integer maths (locale independent).
    static func seconds(_ seconds: TimeInterval) -> String {
        let v = ms(seconds)
        return "\(v / 1000).\(pad(v % 1000, 3))"
    }
}

enum XML {
    /// Removes characters that are illegal in XML 1.0.
    static func stripIllegal(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for s in text.unicodeScalars {
            switch s.value {
            case 0x9, 0xA, 0xD, 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF: scalars.append(s)
            default: continue
            }
        }
        return String(scalars)
    }

    static func escape(_ text: String) -> String {
        var out = ""
        for ch in stripIllegal(text) {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(ch)
            }
        }
        return out
    }
}

enum FileNames {
    /// A filesystem-safe name derived from `title`.
    static func sanitize(_ title: String, fallback: String = "Transcript") -> String {
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters).union(.newlines)
        var name = title.unicodeScalars.map { illegal.contains($0) ? "-" : String($0) }.joined()
        name = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespaces)
        if name.count > 120 { name = String(name.prefix(120)).trimmingCharacters(in: .whitespaces) }
        return name.isEmpty ? fallback : name
    }
}

extension ExportFormat {
    var fileExtension: String {
        switch self {
        case .markdown: "md"
        default: rawValue
        }
    }

    var mimeType: String {
        switch self {
        case .txt: "text/plain"
        case .markdown: "text/markdown"
        case .docx: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case .html: "text/html"
        case .pdf: "application/pdf"
        case .json: "application/json"
        case .csv: "text/csv"
        case .srt: "application/x-subrip"
        case .vtt: "text/vtt"
        case .ass: "text/x-ssa"
        case .sbv: "text/plain"
        case .ttml: "application/ttml+xml"
        case .lrc: "text/plain"
        }
    }
}

func makeArtifact(_ document: TranscriptDocument, options: ExportOptions, data: Data) -> ExportArtifact {
    ExportArtifact(
        suggestedFilename: "\(FileNames.sanitize(document.transcript.title)).\(options.format.fileExtension)",
        mimeType: options.format.mimeType, data: data)
}
