import AppCore
import Foundation

@testable import Persistence

func makeDB() throws -> AppDatabase { try AppDatabase.inMemory() }

func tempDBURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("earmark-test-\(UUID().uuidString)").appendingPathComponent("db.sqlite")
}

func makeTranscript(
    _ title: String = "Interview", source: TranscriptSource = .file, duration: TimeInterval = 60,
    languages: Set<LanguageCode> = ["en"], tags: [String] = [], folder: FolderID? = nil,
    created: Date = Date(timeIntervalSince1970: 1_000_000)
) -> Transcript {
    Transcript(
        title: title, source: source, duration: duration, languages: languages, tags: tags, folderID: folder,
        createdAt: created, modifiedAt: created)
}

func makeSegment(_ text: String, start: TimeInterval = 0, words: [Word] = [], ignored: Bool = false) -> Segment {
    Segment(start: start, end: start + 2, text: text, isIgnored: ignored, words: words)
}
