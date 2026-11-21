import AppCore
import Foundation
import ZIPFoundation

/// Script classification for splitting text into runs that need different fonts and `w:lang` values.
enum ScriptRuns {
    static func isSinhala(_ scalar: Unicode.Scalar) -> Bool { (0x0D80...0x0DFF).contains(scalar.value) || scalar.value == 0x200C || scalar.value == 0x200D }

    /// Splits text into maximal runs of Sinhala script vs. everything else. Neutral characters (spaces, punctuation, digits)
    /// stay with the run they follow, so a Sinhala sentence is one run.
    static func split(_ text: String) -> [(sinhala: Bool, text: String)] {
        var runs: [(sinhala: Bool, text: String)] = []
        var pending = ""
        for ch in text {
            let hasSinhala = ch.unicodeScalars.contains(where: isSinhala)
            let neutral = !hasSinhala && !(ch.isLetter)
            if neutral {
                if runs.isEmpty { pending.append(ch) } else { runs[runs.count - 1].text.append(ch) }
                continue
            }
            if let last = runs.last, last.sinhala == hasSinhala {
                runs[runs.count - 1].text.append(ch)
            } else {
                runs.append((hasSinhala, pending + String(ch)))
                pending = ""
            }
        }
        if runs.isEmpty, !pending.isEmpty { runs.append((false, pending)) }
        return runs
    }
}

/// OOXML `.docx` writer (zipped with ZIPFoundation). Sinhala runs declare a complex-script font and `w:lang` (EXP-AC-11).
public struct DOCXExporter: Exporter {
    /// Font declared for Sinhala runs (installed on macOS; Word substitutes where it is missing).
    public static let sinhalaFont = "Sinhala Sangam MN"
    public static let defaultLatinFont = "Helvetica Neue"

    public init() {}
    public var formats: Set<ExportFormat> { [.docx] }

    public func export(_ document: TranscriptDocument, options: ExportOptions) async throws -> ExportArtifact {
        try ExportPipeline.validate(options, supported: formats)
        let entries = ExportPipeline.entries(document, options: options)
        let paragraphs = ExportPipeline.paragraphs(entries, options: options)
        let root = ExportPipeline.primaryLanguage(document, entries: entries)

        var body = "<w:p><w:pPr><w:pStyle w:val=\"Title\"/></w:pPr>\(runs(document.transcript.title, language: nil, style: .init()))</w:p>"
        for paragraph in paragraphs {
            var xml = "<w:p><w:pPr><w:spacing w:after=\"160\"/></w:pPr>"
            if let stamp = paragraph.items[0].stamp {
                xml += runs("[\(Format.stamp(stamp))] ", language: nil, style: .init(color: "7F7F7F"))
            }
            if options.includeSpeakers, let name = paragraph.speaker?.name {
                xml += runs(name + ": ", language: nil, style: .init(bold: true))
            }
            for (index, item) in paragraph.items.enumerated() {
                if index > 0 {
                    xml += runs(" ", language: nil, style: .init())
                    if let stamp = item.stamp { xml += runs("[\(Format.stamp(stamp))] ", language: nil, style: .init(color: "7F7F7F")) }
                }
                xml += runs(item.entry.text, language: item.entry.language, style: .init())
            }
            xml += "</w:p>"
            body += xml
            let translations = paragraph.items.compactMap { item in item.entry.translation.map { ($0, item.entry.translationLanguage) } }
            if !translations.isEmpty {
                body += "<w:p><w:pPr><w:spacing w:after=\"160\"/><w:ind w:left=\"360\"/></w:pPr>"
                for (index, pair) in translations.enumerated() {
                    body += runs((index > 0 ? " " : "") + pair.0, language: pair.1, style: .init(italic: true, color: "595959"))
                }
                body += "</w:p>"
            }
        }

        let ns = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\""
        let documentXML = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document \(ns)><w:body>\(body)<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>\
            <w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134" w:header="708" w:footer="708" w:gutter="0"/>\
            </w:sectPr></w:body></w:document>
            """
        let latin = XML.escape(options.fontFamily ?? Self.defaultLatinFont)
        let stylesXML = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:docDefaults>\
            <w:rPrDefault><w:rPr>\
            <w:rFonts w:ascii="\(latin)" w:hAnsi="\(latin)" w:eastAsia="\(latin)" w:cs="\(Self.sinhalaFont)"/>\
            <w:sz w:val="22"/><w:szCs w:val="22"/>\
            <w:lang w:val="\(Self.langTag(root, sinhalaScript: false))" w:eastAsia="en-US" w:bidi="si-LK"/>\
            </w:rPr></w:rPrDefault></w:docDefaults><w:style w:type="paragraph" w:default="1" w:styleId="Normal">\
            <w:name w:val="Normal"/><w:qFormat/></w:style><w:style w:type="paragraph" w:styleId="Title">\
            <w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr>\
            <w:spacing w:after="240"/></w:pPr><w:rPr><w:b/><w:bCs/><w:sz w:val="40"/><w:szCs w:val="40"/>\
            </w:rPr></w:style></w:styles>
            """
        let contentTypes = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
            <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
            <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
            </Types>
            """
        let rels = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
            <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
            </Relationships>
            """
        let documentRels = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
            </Relationships>
            """
        let core = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/">\
            <dc:title>\(XML.escape(document.transcript.title))</dc:title><dc:creator>Earmark</dc:creator>\
            </cp:coreProperties>
            """
        let data = try Self.zip([
            ("[Content_Types].xml", contentTypes), ("_rels/.rels", rels), ("word/document.xml", documentXML),
            ("word/styles.xml", stylesXML), ("word/_rels/document.xml.rels", documentRels), ("docProps/core.xml", core),
        ])
        return makeArtifact(document, options: options, data: data)
    }

    // MARK: Runs

    struct RunStyle {
        var bold = false
        var italic = false
        var color: String?
    }

    static func langTag(_ language: LanguageCode, sinhalaScript: Bool) -> String {
        if sinhalaScript || language.primary == .sinhala { return "si-LK" }
        return language.rawValue == "en" ? "en-US" : language.rawValue
    }

    private func runs(_ text: String, language: LanguageCode?, style: RunStyle) -> String {
        var xml = ""
        for run in ScriptRuns.split(XML.stripIllegal(text)) {
            var props = ""
            if run.sinhala {
                let f = Self.sinhalaFont
                props += "<w:rFonts w:ascii=\"\(f)\" w:hAnsi=\"\(f)\" w:eastAsia=\"\(f)\" w:cs=\"\(f)\" w:hint=\"cs\"/>"
            }
            if style.bold { props += "<w:b/><w:bCs/>" }
            if style.italic { props += "<w:i/><w:iCs/>" }
            if let color = style.color { props += "<w:color w:val=\"\(color)\"/>" }
            if run.sinhala {
                props += "<w:lang w:val=\"si-LK\" w:bidi=\"si-LK\"/>"
            } else if let language, language.primary != .sinhala {
                props += "<w:lang w:val=\"\(XML.escape(Self.langTag(language, sinhalaScript: false)))\"/>"
            } else {
                props += "<w:lang w:val=\"en-US\"/>"
            }
            xml += "<w:r><w:rPr>\(props)</w:rPr><w:t xml:space=\"preserve\">\(XML.escape(run.text))</w:t></w:r>"
        }
        return xml
    }

    // MARK: Zip

    static func zip(_ parts: [(String, String)]) throws -> Data {
        let archive: Archive
        do {
            archive = try Archive(data: Data(), accessMode: .create)
        } catch {
            throw AppError.exportFailed(reason: "Could not create the .docx archive: \(error.localizedDescription)")
        }
        let fixedDate = Date(timeIntervalSince1970: 315_619_200)  // 1980-01-01, keeps output deterministic
        do {
            for (path, content) in parts {
                let bytes = Data(content.utf8)
                try archive.addEntry(
                    with: path, type: .file, uncompressedSize: Int64(bytes.count), modificationDate: fixedDate, compressionMethod: .deflate
                ) { position, size in
                    bytes.subdata(in: Int(position)..<Int(position) + size)
                }
            }
        } catch {
            throw AppError.exportFailed(reason: "Could not write the .docx archive: \(error.localizedDescription)")
        }
        guard let data = archive.data else { throw AppError.exportFailed(reason: "The .docx archive is empty.") }
        return data
    }
}
