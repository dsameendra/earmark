import AppCore
import Foundation

private func utf8(_ text: String) -> Data { Data(text.utf8) }

/// Plain text and Markdown. Timestamps, speakers, merging, grouping and translation follow ``ExportOptions``.
public struct TextExporter: Exporter {
    public init() {}
    public var formats: Set<ExportFormat> { [.txt, .markdown] }

    public func export(_ document: TranscriptDocument, options: ExportOptions) async throws -> ExportArtifact {
        try ExportPipeline.validate(options, supported: formats)
        let entries = ExportPipeline.entries(document, options: options)
        let paragraphs = ExportPipeline.paragraphs(entries, options: options)
        let text = options.format == .markdown ? markdown(document, paragraphs, options) : plain(document, paragraphs, options)
        return makeArtifact(document, options: options, data: utf8(text))
    }

    private func plain(_ document: TranscriptDocument, _ paragraphs: [Paragraph], _ options: ExportOptions) -> String {
        var out = document.transcript.title + "\n"
        for paragraph in paragraphs {
            out += "\n"
            var line = ""
            if let stamp = paragraph.items[0].stamp { line += "[\(Format.stamp(stamp))] " }
            if options.includeSpeakers, let name = paragraph.speaker?.name { line += name + ": " }
            for (index, item) in paragraph.items.enumerated() {
                if index > 0 {
                    line += " "
                    if let stamp = item.stamp { line += "[\(Format.stamp(stamp))] " }
                }
                line += item.entry.text
            }
            out += line + "\n"
            let translations = paragraph.items.compactMap(\.entry.translation)
            if !translations.isEmpty { out += "    " + translations.joined(separator: " ") + "\n" }
        }
        return out
    }

    private func markdown(_ document: TranscriptDocument, _ paragraphs: [Paragraph], _ options: ExportOptions) -> String {
        var out = "# " + Self.escape(document.transcript.title) + "\n"
        for paragraph in paragraphs {
            out += "\n"
            let name = options.includeSpeakers ? paragraph.speaker?.name : nil
            let headStamp = paragraph.items[0].stamp
            var body = ""
            for (index, item) in paragraph.items.enumerated() {
                if index > 0 {
                    body += " "
                    if let stamp = item.stamp { body += "[\(Format.stamp(stamp))] " }
                }
                body += Self.escape(item.entry.text)
            }
            if let name {
                out += "**\(Self.escape(name))**" + (headStamp.map { " [\(Format.stamp($0))]" } ?? "") + "\n\n" + body + "\n"
            } else {
                out += (headStamp.map { "[\(Format.stamp($0))] " } ?? "") + body + "\n"
            }
            let translations = paragraph.items.compactMap(\.entry.translation)
            if !translations.isEmpty { out += "\n> " + Self.escape(translations.joined(separator: " ")) + "\n" }
        }
        return out
    }

    /// Escapes Markdown control characters.
    static func escape(_ text: String) -> String {
        var out = ""
        for ch in text.replacingOccurrences(of: "\n", with: " ") {
            if "\\`*_[]<>".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        if out.hasPrefix("#") { out = "\\" + out }
        return out
    }
}

/// Standalone HTML with per-segment `lang` attributes (EXP-AC-10).
public struct HTMLExporter: Exporter {
    public init() {}
    public var formats: Set<ExportFormat> { [.html] }

    public func export(_ document: TranscriptDocument, options: ExportOptions) async throws -> ExportArtifact {
        try ExportPipeline.validate(options, supported: formats)
        let entries = ExportPipeline.entries(document, options: options)
        let paragraphs = ExportPipeline.paragraphs(entries, options: options)
        let root = ExportPipeline.primaryLanguage(document, entries: entries)
        let fonts = ([options.fontFamily] + ["Helvetica Neue", "Sinhala Sangam MN", "Iskoola Pota", "Noto Sans Sinhala"]).compactMap { $0 }
            .map { "\"\(XML.escape($0))\"" }.joined(separator: ",")
        var html = """
            <!DOCTYPE html>
            <html lang="\(XML.escape(root.rawValue))">
            <head>
            <meta charset="utf-8">
            <title>\(XML.escape(document.transcript.title))</title>
            <style>
            body{font-family:\(fonts),sans-serif;max-width:48rem;margin:2rem auto;line-height:1.6;padding:0 1rem}
            .meta{margin:0;color:#666;font-size:.85em}.speaker{font-weight:600;color:#222}.translation{color:#555;font-style:italic;margin:0 0 1rem}
            </style>
            </head>
            <body>
            <h1>\(XML.escape(document.transcript.title))</h1>

            """
        for paragraph in paragraphs {
            html += "<section class=\"turn\">\n"
            let name = options.includeSpeakers ? paragraph.speaker?.name : nil
            let head = paragraph.items[0].stamp
            if name != nil || head != nil {
                html += "<p class=\"meta\">"
                if let name { html += "<span class=\"speaker\">\(XML.escape(name))</span>" }
                if let head {
                    if name != nil { html += " " }
                    html += Self.time(head)
                }
                html += "</p>\n"
            }
            html += "<p>"
            for (index, item) in paragraph.items.enumerated() {
                if index > 0 {
                    html += " "
                    if let stamp = item.stamp { html += Self.time(stamp) + " " }
                }
                let lang = item.entry.language.map { " lang=\"\(XML.escape($0.rawValue))\"" } ?? ""
                html += "<span\(lang) data-start=\"\(Format.seconds(item.entry.start))\">\(XML.escape(item.entry.text))</span>"
            }
            html += "</p>\n"
            let secondary = paragraph.items.compactMap { item in item.entry.translation.map { (item.entry.translationLanguage, $0) } }
            if !secondary.isEmpty {
                html += "<p class=\"translation\">"
                for (index, pair) in secondary.enumerated() {
                    if index > 0 { html += " " }
                    let lang = pair.0.map { " lang=\"\(XML.escape($0.rawValue))\"" } ?? ""
                    html += "<span\(lang)>\(XML.escape(pair.1))</span>"
                }
                html += "</p>\n"
            }
            html += "</section>\n"
        }
        html += "</body>\n</html>\n"
        return makeArtifact(document, options: options, data: utf8(html))
    }

    private static func time(_ seconds: TimeInterval) -> String {
        "<time datetime=\"PT\(Format.ms(seconds) / 1000)S\">\(Format.stamp(seconds))</time>"
    }
}

/// RFC-4180 CSV: UTF-8 without BOM, CRLF line endings, quoted when needed (EXP-AC-13).
public struct CSVExporter: Exporter {
    public init() {}
    public var formats: Set<ExportFormat> { [.csv] }

    public func export(_ document: TranscriptDocument, options: ExportOptions) async throws -> ExportArtifact {
        try ExportPipeline.validate(options, supported: formats)
        let entries = ExportPipeline.entries(document, options: options)
        let times = options.timestamps != .none
        let bilingual = options.translation == .bilingual
        var header = ["index"]
        if times { header += ["start", "end"] }
        if options.includeSpeakers { header.append("speaker") }
        header += ["language", "text"]
        if bilingual { header += ["translation_language", "translation"] }
        var rows = [header]
        for (index, entry) in entries.enumerated() {
            var row = [String(index + 1)]
            if times { row += [Format.seconds(entry.start), Format.seconds(entry.end)] }
            if options.includeSpeakers { row.append(entry.speaker?.name ?? "") }
            row += [entry.language?.rawValue ?? "", entry.text]
            if bilingual { row += [entry.translationLanguage?.rawValue ?? "", entry.translation ?? ""] }
            rows.append(row)
        }
        let text = rows.map { $0.map(Self.field).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
        return makeArtifact(document, options: options, data: utf8(text))
    }

    static func field(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// Full-fidelity JSON: segments, words, timings, speakers, languages, confidence and every translation track (EXP-AC-09).
///
/// The output decodes with `JSONDecoder` into an equal ``TranscriptDocument`` (for the same ignored/range/offset selection).
/// Keys are sorted, the transcript's language set is written sorted and dates use the default `Date` coding, so output is deterministic and round-trips with a plain `JSONDecoder`.
public struct JSONExporter: Exporter {
    public init() {}
    public var formats: Set<ExportFormat> { [.json] }

    private struct TranscriptDTO: Encodable {
        var id: TranscriptID
        var title: String
        var source: TranscriptSource
        var duration: TimeInterval
        var languages: [LanguageCode]
        var speakers: [Speaker]
        var tags: [String]
        var folderID: FolderID?
        var mediaAssetID: MediaAssetID?
        var meetingID: MeetingID?
        var revisionOf: TranscriptID?
        var createdAt: Date
        var modifiedAt: Date
        var deletedAt: Date?
    }

    private struct DocumentDTO: Encodable {
        var schemaVersion = 1
        var generator = "Earmark"
        var transcript: TranscriptDTO
        var segments: [Segment]
    }

    public func export(_ document: TranscriptDocument, options: ExportOptions) async throws -> ExportArtifact {
        try ExportPipeline.validate(options, supported: formats)
        let t = document.transcript
        let dto = DocumentDTO(
            transcript: TranscriptDTO(
                id: t.id, title: t.title, source: t.source, duration: t.duration, languages: t.languages.sorted(), speakers: t.speakers,
                tags: t.tags, folderID: t.folderID, mediaAssetID: t.mediaAssetID, meetingID: t.meetingID, revisionOf: t.revisionOf,
                createdAt: t.createdAt, modifiedAt: t.modifiedAt, deletedAt: t.deletedAt),
            segments: ExportPipeline.segments(document, options: options))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(dto)
        data.append(0x0A)
        return makeArtifact(document, options: options, data: data)
    }
}
