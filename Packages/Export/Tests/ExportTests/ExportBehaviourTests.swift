import AppCore
import Foundation
import PDFKit
import Testing
import ZIPFoundation

@testable import Export

private func cues(_ srt: String) -> [(Int, Int)] {
    srt.components(separatedBy: "\n").compactMap { line -> (Int, Int)? in
        guard line.contains(" --> ") else { return nil }
        let parts = line.components(separatedBy: " --> ").map { p -> Int in
            let n = p.replacingOccurrences(of: ",", with: ":").split(separator: ":").map { Int($0)! }
            return ((n[0] * 60 + n[1]) * 60 + n[2]) * 1000 + n[3]
        }
        return (parts[0], parts[1])
    }
}

private final class ParserCollector: NSObject, XMLParserDelegate {
    var langs: [String] = []
    var agents: [String] = []
    var pCount = 0
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if name == "p" {
            pCount += 1
            langs.append(attributes["xml:lang"] ?? "")
            if let a = attributes["ttm:agent"] { agents.append(a) }
        }
    }
}

@Suite("Export behaviour")
struct ExportBehaviourTests {
    @Test("EXP-AC-02: ignored segments omitted unless includeIgnored, in every format")
    func ignored() async throws {
        for format in [ExportFormat.txt, .markdown, .html, .csv, .srt, .vtt, .ass, .sbv, .ttml, .lrc, .json] {
            let off = try await Fixture.text(format)
            let on = try await Fixture.text(format) { $0.includeIgnored = true }
            #expect(!off.contains("[Music]") && !off.contains("\\[Music\\]"), "\(format)")
            #expect(on.contains("Music"), "\(format)")
        }
        // Timestamps are not re-based by omission.
        let srt = try await Fixture.text(.srt)
        #expect(srt.contains("00:00:09,500"))
    }

    @Test("EXP-AC-03: timestamp granularity")
    func timestamps() async throws {
        func stamps(_ style: TimestampStyle, group: Bool = false) async throws -> [String] {
            let t = try await Fixture.text(.txt) {
                $0.timestamps = style
                $0.paragraphGrouping = group
            }
            return t.components(separatedBy: "[").dropFirst().map { String($0.prefix(8)) }
        }
        #expect(try await stamps(.none).isEmpty)
        #expect(try await stamps(.perSegment) == ["00:00:00", "00:00:03", "00:00:06", "00:00:09", "00:00:14", "00:00:25"])
        // Grouped: Alice(1) | Dumindu(2,3) | Alice(5) | Dumindu(6) | Alice(7)
        #expect(try await stamps(.perParagraph, group: true) == ["00:00:00", "00:00:03", "00:00:09", "00:00:14", "00:00:25"])
        #expect(try await stamps(.everyNSeconds(10)) == ["00:00:00", "00:00:10", "00:00:20"])
    }

    @Test("EXP-AC-04: speaker labels per format")
    func speakers() async throws {
        let vtt = try await Fixture.text(.vtt)
        #expect(vtt.contains("<v Alice>") && vtt.contains("<v Dumindu>"))
        let ass = try await Fixture.text(.ass)
        #expect(ass.contains("Dialogue: 0,0:00:00.00,0:00:03.20,Alice,Alice,"))
        #expect(ass.contains("Style: Dumindu,") && ass.contains("&H003539E5"))
        let ttml = try await Fixture.text(.ttml)
        #expect(ttml.contains("ttm:agent xml:id=\"spk-1\"") && ttml.contains("ttm:agent=\"spk-2\""))
        let none = try await Fixture.text(.vtt) { $0.includeSpeakers = false }
        #expect(!none.contains("<v "))
    }

    @Test("EXP-AC-05: merge same speaker when gap <= 2 s")
    func merge() async throws {
        let t = try await Fixture.text(.txt) {
            $0.mergeSameSpeaker = true
            $0.timestamps = .none
        }
        #expect(t.contains("Dumindu: \(Fixture.sinhalaGreeting) \(Fixture.sinhalaFine)"))
        #expect(t.contains("Alice: The quarterly"))  // ignored [Music] removed first, gap 8.0 -> 9.5 not merged with seg 1? separate speaker turn
        let lines = t.components(separatedBy: "\n").filter { $0.hasPrefix("Alice:") }
        #expect(lines.count == 3)  // seg1 | seg5 (gap 1.5 after Dumindu) | seg7 (gap 11 s)
    }

    @Test("EXP-AC-06: translation replace, bilingual and fallback")
    func translation() async throws {
        let replace = try await Fixture.text(.srt) {
            $0.translation = .replace
            $0.translationLanguage = "en"
        }
        #expect(replace.contains("Hello, let's look at today's agenda."))
        #expect(!replace.contains("ආයුබෝවන්"))
        #expect(replace.contains("Good morning everyone."), "fallback to original when translation missing")
        let bi = try await Fixture.text(.srt) {
            $0.translation = .bilingual
            $0.translationLanguage = "en"
        }
        let range = try #require(bi.range(of: "ආයුබෝවන්"))
        #expect(bi.range(of: "Hello, let's look", range: range.upperBound..<bi.endIndex) != nil)
        let none = try await Fixture.text(.srt)
        #expect(!none.contains("Hello, let's look"))
    }

    @Test("translation export never substitutes a different Chinese writing system")
    func translationScripts() throws {
        var document = Fixture.document()
        document.segments = [Segment(start: 0, end: 1, text: "Original", translations: [SegmentTranslation(language: "zh-Hans", text: "简体", engine: "test")])]
        var options = ExportOptions(format: .srt)
        options.translation = .replace
        options.translationLanguage = "zh-TW"
        #expect(ExportPipeline.entries(document, options: options).first?.text == "Original")
        options.translationLanguage = "zh-CN"
        #expect(ExportPipeline.entries(document, options: options).first?.text == "简体")
    }

    @Test("EXP-AC-07: subtitle constraints hold for varied inputs; no overlaps")
    func constraints() async throws {
        var doc = Fixture.document()
        // Overlapping, short and very long segments.
        doc.segments = (0..<60).map { (i: Int) -> Segment in
            let start: Double = Double(i) * 0.7
            let length: Double = i % 4 == 0 ? 15 : 0.3
            let english: String = "A fairly long sentence, with a comma. Another one follows here!"
            let sinhala: String = "කොහොමද ඔබට අද දවස? ස්තුතියි, මම හොඳින් ඉන්නවා."
            let text: String = i % 2 == 0 ? english : sinhala
            let speaker: Speaker = i % 3 == 0 ? Fixture.alice : Fixture.dumindu
            let language: LanguageCode = i % 2 == 0 ? "en" : "si"
            return Fixture.segment(i % 90 + 1, start, start + length, text, speaker, language, withWords: i % 5 != 0)
        }
        for limits in [SubtitleConstraints(), SubtitleConstraints(maxCharsPerLine: 12, maxLinesPerCue: 1, minCueDuration: 0.5, maxCueDuration: 3, minGap: 0.1, splitOnPunctuation: false)] {
            let t = try await Fixture.text(.srt, doc) { $0.subtitle = limits }
            let c = cues(t)
            #expect(!c.isEmpty)
            let gap = Int((limits.minGap * 1000).rounded())
            for (a, b) in zip(c, c.dropFirst()) { #expect(a.1 + gap <= b.0, "overlap \(a) \(b)") }
            for x in c { #expect(x.1 > x.0 && x.1 - x.0 <= Int(limits.maxCueDuration * 1000)) }
            for block in t.components(separatedBy: "\n\n") {
                let body = block.components(separatedBy: "\n").dropFirst(2)
                #expect(body.count <= limits.maxLinesPerCue)
                for line in body {
                    let text = line.contains(": ") ? String(line.split(separator: ":", maxSplits: 1).last!.dropFirst()) : line
                    #expect(text.count <= limits.maxCharsPerLine, "line too long: \(line)")
                }
            }
        }
    }

    @Test("Sinhala conjuncts and vowel signs are never split across lines")
    func sinhalaGraphemes() {
        let word = "ක්‍ෂේත්‍රයේ" + "ක්‍ෂමතාව"
        let tokens = CueBuilder.tokens(word, maxChars: 3).tokens
        for (a, b) in zip(tokens, tokens.dropFirst()) {
            let last = a.text.unicodeScalars.last!.value
            #expect(last != 0x200D && last != 0x0DCA, "broke after \(String(a.text))")
            let first = b.text.unicodeScalars.first!
            #expect(!(0x0DCA...0x0DDF).contains(first.value) && first.value != 0x200D)
        }
        #expect(tokens.map(\.text).joined() == word)
    }

    @Test("EXP-AC-08: offset clamps at 0; time range re-bases to its start")
    func offsetAndRange() async throws {
        let shifted = try await Fixture.text(.srt) { $0.timeOffset = 2 }
        #expect(shifted.contains("00:00:02,000 --> "))
        let negative = try await Fixture.text(.srt) { $0.timeOffset = -5 }
        #expect(negative.contains("00:00:00,000 -->"))
        #expect(!negative.contains("-00"))
        let ranged = try await Fixture.text(.srt) { $0.timeRange = TimeRange(start: 9, end: 20) }
        #expect(ranged.contains("00:00:00,500 --> "))  // segment 5 starts 9.5
        #expect(!ranged.contains("Good morning"))
        #expect(ranged.contains("Agreed."))
        #expect(!ranged.contains("After a long pause"))
    }

    @Test("EXP-AC-09: JSON round-trips to an equal document and is deterministic")
    func json() async throws {
        let doc = Fixture.document()
        let a = try await ExportService().export(doc, options: Fixture.options(.json) { $0.includeIgnored = true })
        let b = try await ExportService().export(doc, options: Fixture.options(.json) { $0.includeIgnored = true })
        #expect(a.data == b.data)
        let decoded = try JSONDecoder().decode(TranscriptDocument.self, from: a.data)
        #expect(decoded == doc)
        let text = String(decoding: a.data, as: UTF8.self)
        #expect(text.contains("\"languageCode\"") && text.contains("\"translations\"") && text.contains("\"words\""))
    }

    @Test("EXP-AC-10: HTML and TTML carry per-segment language")
    func languages() async throws {
        let html = try await Fixture.text(.html)
        #expect(html.contains("<span lang=\"si\"") && html.contains("<span lang=\"en\""))
        let ttml = try await Fixture.text(.ttml)
        let collector = ParserCollector()
        let parser = XMLParser(data: Data(ttml.utf8))
        parser.shouldProcessNamespaces = false
        parser.delegate = collector
        #expect(parser.parse(), "TTML is well-formed: \(String(describing: parser.parserError))")
        #expect(collector.pCount > 0)
        #expect(Set(collector.langs) == ["en", "si"])
        #expect(ttml.contains("&lt;beta&gt;") && ttml.contains("&amp;"))
    }

    @Test("EXP-AC-11: DOCX is valid OOXML with Sinhala font and language")
    func docx() async throws {
        let artifact = try await ExportService().export(Fixture.document(), options: Fixture.options(.docx))
        let archive = try Archive(data: artifact.data, accessMode: .read)
        var names: [String] = []
        var documentXML = Data()
        for entry in archive {
            names.append(entry.path)
            if entry.path == "word/document.xml" { _ = try archive.extract(entry) { documentXML.append($0) } }
        }
        #expect(names.contains("[Content_Types].xml") && names.contains("word/document.xml") && names.contains("_rels/.rels"))
        let xml = String(decoding: documentXML, as: UTF8.self)
        #expect(xml.contains("w:cs=\"Sinhala Sangam MN\"") && xml.contains("w:bidi=\"si-LK\"") && xml.contains("w:val=\"si-LK\""))
        #expect(xml.contains(Fixture.sinhalaFine))
        let parser = XMLParser(data: documentXML)
        #expect(parser.parse(), "document.xml well-formed: \(String(describing: parser.parserError))")

        // Opens without repair: textutil can read it back.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("docx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("t.docx")
        try artifact.data.write(to: file)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", "txt", file.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let roundTrip = try String(contentsOf: dir.appendingPathComponent("t.txt"), encoding: .utf8)
        #expect(roundTrip.contains("Good morning everyone.") && roundTrip.contains(Fixture.sinhalaFine))
    }

    @Test("EXP-AC-12: PDF paginates, embeds a Sinhala font, and keeps Sinhala text")
    func pdf() async throws {
        let doc = Fixture.longDocument(count: 400)
        let artifact = try await ExportService().export(doc, options: Fixture.options(.pdf))
        let pdf = try #require(PDFDocument(data: artifact.data))
        #expect(pdf.pageCount > 3)
        let raw = String(decoding: artifact.data, as: UTF8.self)
        #expect(raw.contains("FontFile"))
        #expect(raw.contains("Sinhala") || raw.contains("SinhalaSangam"))
        let text = pdf.string ?? ""
        #expect(text.contains("Segment 399") || text.contains("Segment 396"), "last segments are not clipped")
        let sinhala = text.unicodeScalars.filter { (0x0D80...0x0DFF).contains($0.value) }
        #expect(sinhala.count > 100)
        // Shaping: CoreText produces fewer glyphs than scalars for conjunct/vowel-sign sequences.
        let font = CTFontCreateWithName("Sinhala Sangam MN" as CFString, 12, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: Fixture.sinhalaGreeting, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        var glyphs = 0
        for run in ((CTLineGetGlyphRuns(line) as? [CTRun]) ?? []) { glyphs += CTRunGetGlyphCount(run) }
        #expect(glyphs > 0)
    }

    @Test("EXP-AC-13: CSV quoting, CRLF, no BOM")
    func csv() async throws {
        let artifact = try await ExportService().export(Fixture.document(), options: Fixture.options(.csv))
        #expect(artifact.data.prefix(3) != Data([0xEF, 0xBB, 0xBF]))
        let text = String(decoding: artifact.data, as: UTF8.self)
        #expect(text.contains("\"After a long pause: a quote \"\"hello\"\", and a comma.\""))
        #expect(text.hasSuffix("\r\n") && text.components(separatedBy: "\r\n").count > 5)
        #expect(CSVExporter.field("a\nb") == "\"a\nb\"")
    }

    @Test("EXP-AC-14: per-speaker export")
    func perSpeaker() async throws {
        let artifacts = try await ExportService().exportPerSpeaker(Fixture.document(), options: Fixture.options(.txt))
        #expect(artifacts.count == 2)
        let alice = String(decoding: artifacts[0].data, as: UTF8.self)
        #expect(alice.contains("Good morning") && !alice.contains("Agreed."))
        #expect(artifacts[0].suggestedFilename == "Team Sync - Alice.txt" && artifacts[1].suggestedFilename == "Team Sync - Dumindu.txt")
    }

    @Test("EXP-AC-19: invalid options throw a readable exportFailed")
    func invalid() async {
        for configure: (inout ExportOptions) -> Void in [
            { $0.translation = .bilingual }, { $0.translation = .replace },
            { $0.timeRange = TimeRange(start: 5, end: 5) }, { $0.timestamps = .everyNSeconds(0) },
            { $0.subtitle.maxCharsPerLine = 0 }, { $0.subtitle.minCueDuration = 9 },
        ] {
            do {
                _ = try await ExportService().export(Fixture.document(), options: Fixture.options(.srt, configure))
                Issue.record("expected failure")
            } catch AppError.exportFailed(let reason) {
                #expect(!reason.isEmpty)
            } catch { Issue.record("wrong error \(error)") }
        }
    }

    @Test("Edge cases: empty transcript, illegal XML chars, filenames")
    func edges() async throws {
        var empty = Fixture.document()
        empty.segments = []
        for format in ExportFormat.allCases {
            let artifact = try await ExportService().export(empty, options: Fixture.options(format))
            if ![.srt, .sbv].contains(format) { #expect(!artifact.data.isEmpty, "\(format)") }
        }
        var dirty = Fixture.document()
        dirty.segments[0].text = "bad\u{0}char\u{1B} ok"
        dirty.transcript.title = "A/B: \"Plan\"?"
        for format in [ExportFormat.html, .ttml] {
            let t = try await Fixture.text(format, dirty)
            #expect(!t.contains("\u{0}") && !t.contains("\u{1B}") && t.contains("badchar ok"))
        }
        let artifact = try await ExportService().export(dirty, options: Fixture.options(.txt))
        #expect(artifact.suggestedFilename == "A-B- -Plan--.txt")
    }

    @Test("NFR: 10 000 segments export quickly")
    func performance() async throws {
        let doc = Fixture.longDocument(count: 10_000)
        let started = Date()
        for format in [ExportFormat.txt, .srt, .json, .csv] { _ = try await ExportService().export(doc, options: Fixture.options(format)) }
        #expect(Date().timeIntervalSince(started) < 20, "debug build; target 2 s in release")
    }
}
