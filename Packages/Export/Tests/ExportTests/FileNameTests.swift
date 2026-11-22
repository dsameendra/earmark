import Foundation
import Testing

@testable import Export

@Suite("Export file names") struct FileNameTests {
    @Test func longMultiByteTitlesStayUnderTheFileSystemLimit() {
        for scalar in ["සිංහල", "日本語", "🎙️"] {
            let title = String(repeating: scalar, count: 80)
            let name = FileNames.sanitize(title)
            #expect(name.utf8.count <= FileNames.maxBytes, "\(scalar) title is \(name.utf8.count) bytes")
            #expect("\(name).markdown".utf8.count <= 255)
            #expect(!name.isEmpty && title.hasPrefix(name))
        }
    }

    @Test func illegalAndEmptyTitlesFallBack() {
        #expect(FileNames.sanitize("a/b:c") == "a-b-c")
        #expect(FileNames.sanitize("...") == "Transcript")
        #expect(FileNames.sanitize("  ") == "Transcript")
    }
}
