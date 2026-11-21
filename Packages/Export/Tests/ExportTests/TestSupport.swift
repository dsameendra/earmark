import AppCore
import Foundation
import Testing

@testable import Export

enum Fixture {
    static let alice = Speaker(id: SpeakerID(UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!), name: "Alice", colorHex: "#1E88E5")
    static let dumindu = Speaker(id: SpeakerID(UUID(uuidString: "00000000-0000-4000-8000-0000000000D1")!), name: "Dumindu", colorHex: "#E53935")
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    /// Words spread evenly over `[start, end]`, one per whitespace token.
    static func words(_ text: String, _ start: Double, _ end: Double) -> [Word] {
        let tokens = text.split(separator: " ").map(String.init)
        let step = (end - start) / Double(tokens.count)
        return tokens.enumerated().map {
            Word(text: $1, start: start + Double($0) * step, end: start + Double($0 + 1) * step, confidence: 0.9)
        }
    }

    static func segment(
        _ n: Int, _ start: Double, _ end: Double, _ text: String, _ speaker: Speaker?, _ lang: LanguageCode?,
        translation: (LanguageCode, String)? = nil, ignored: Bool = false, withWords: Bool = true
    ) -> Segment {
        Segment(
            id: SegmentID(UUID(uuidString: "10000000-0000-4000-8000-0000000000\(n < 10 ? "0" : "")\(n)")!), start: start, end: end,
            text: text, speakerID: speaker?.id, languageCode: lang, languageConfidence: 0.95, confidence: 0.88, noSpeechProbability: 0.02,
            isIgnored: ignored, words: withWords ? words(text, start, end) : [],
            translations: translation.map { [SegmentTranslation(language: $0.0, text: $0.1, engine: "mock.translate")] } ?? [])
    }

    static let sinhalaGreeting = "ආයුබෝවන්, අද රැස්වීමේ කාර්ය සූචිය බලමු."
    static let sinhalaFine = "මම හොඳින්, ස්තුතියි."

    /// Deterministic bilingual English + Sinhala, two speakers, one ignored marker, a long line, a pause, and escaping hazards.
    static func document() -> TranscriptDocument {
        let transcript = Transcript(
            id: TranscriptID(UUID(uuidString: "20000000-0000-4000-8000-000000000001")!), title: "Team Sync", source: .meeting,
            duration: 30, languages: ["en", "si"], speakers: [alice, dumindu], tags: ["weekly"], createdAt: epoch, modifiedAt: epoch)
        let segments = [
            segment(
                1, 0.0, 3.2, "Good morning everyone. Let's start the weekly sync.", alice, "en",
                translation: ("si", "සැමට සුභ උදෑසනක්. අපි සතිපතා රැස්වීම ආරම්භ කරමු.")),
            segment(2, 3.5, 6.0, sinhalaGreeting, dumindu, "si", translation: ("en", "Hello, let's look at today's agenda.")),
            segment(3, 6.2, 8.0, sinhalaFine, dumindu, "si", translation: ("en", "I'm fine, thank you.")),
            segment(4, 8.5, 9.0, "[Music]", alice, "en", ignored: true),
            segment(
                5, 9.5, 14.0,
                "The quarterly numbers look good, but we need to improve the Sinhala transcription accuracy, especially for names.",
                alice, "en"),
            segment(6, 14.5, 18.0, "Agreed. I'll review the rules with Zoom & Teams <beta> next week.", dumindu, "en", withWords: false),
            segment(7, 25.0, 28.0, "After a long pause: a quote \"hello\", and a comma.", alice, "en"),
        ]
        return TranscriptDocument(transcript: transcript, segments: segments)
    }

    static func longDocument(count: Int) -> TranscriptDocument {
        var doc = document()
        doc.segments = (0..<count).map { i in
            segment(
                i % 90 + 1, Double(i) * 4, Double(i) * 4 + 3.5,
                i % 3 == 0 ? "මම හොඳින්, ස්තුතියි. කොහොමද ඔබට අද දවස? Segment \(i) text for pagination." : "Plain English segment number \(i) with enough words to wrap a little across the line.",
                i % 2 == 0 ? alice : dumindu, i % 3 == 0 ? "si" : "en", withWords: false)
        }
        doc.transcript.duration = Double(count) * 4
        return doc
    }

    static func options(_ format: ExportFormat, _ configure: (inout ExportOptions) -> Void = { _ in }) -> ExportOptions {
        var o = ExportOptions(format: format)
        configure(&o)
        return o
    }

    static func text(_ format: ExportFormat, _ doc: TranscriptDocument = document(), _ configure: (inout ExportOptions) -> Void = { _ in }) async throws -> String {
        let artifact = try await ExportService().export(doc, options: options(format, configure))
        return String(decoding: artifact.data, as: UTF8.self)
    }
}

enum Golden {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Golden")

    /// Compares against `Golden/<format>/<name>.golden` byte for byte. Regenerate with `UPDATE_GOLDENS=1`.
    static func check(_ data: Data, format: String, name: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let url = root.appendingPathComponent(format).appendingPathComponent("\(name).golden")
        if ProcessInfo.processInfo.environment["UPDATE_GOLDENS"] == "1" {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return
        }
        guard let expected = try? Data(contentsOf: url) else {
            Issue.record("Missing golden \(format)/\(name).golden; run with UPDATE_GOLDENS=1", sourceLocation: sourceLocation)
            return
        }
        #expect(data == expected, "Golden mismatch for \(format)/\(name)", sourceLocation: sourceLocation)
    }
}
