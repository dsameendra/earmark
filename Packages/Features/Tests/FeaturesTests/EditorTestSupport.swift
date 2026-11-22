import AppCore
import FeatureEditor
import FeatureSupport
import Foundation

/// Repository that actually stores segments and bookmarks (InMemoryTranscripts returns no segments).
actor FakeTranscriptRepository: TranscriptRepository {
    private(set) var headers: [TranscriptID: Transcript] = [:]
    private(set) var stored: [TranscriptID: [Segment]] = [:]
    private(set) var savedBookmarks: [BookmarkID: TranscriptBookmark] = [:]
    private(set) var upsertCalls = 0
    private(set) var replaceCalls = 0

    init(transcript: Transcript, segments: [Segment]) {
        headers[transcript.id] = transcript
        stored[transcript.id] = segments
    }

    func list(_ query: LibraryQuery) async throws -> [Transcript] { Array(headers.values) }
    func transcript(_ id: TranscriptID) async throws -> Transcript? { headers[id] }
    func save(_ transcript: Transcript) async throws { headers[transcript.id] = transcript }
    func segments(for id: TranscriptID) async throws -> [Segment] { stored[id] ?? [] }
    func upsertSegments(_ segments: [Segment], for id: TranscriptID) async throws {
        upsertCalls += 1
        var current = stored[id] ?? []
        for segment in segments {
            if let index = current.firstIndex(where: { $0.id == segment.id }) { current[index] = segment } else { current.append(segment) }
        }
        stored[id] = current
    }
    func replaceSegments(_ segments: [Segment], for id: TranscriptID) async throws {
        replaceCalls += 1
        stored[id] = segments
    }
    func search(_ text: String, limit: Int) async throws -> [SearchHit] { [] }
    func softDelete(_ ids: [TranscriptID], at date: Date) async throws {}
    func restore(_ ids: [TranscriptID]) async throws {}
    func purge(_ ids: [TranscriptID]) async throws {}
    func purgeDeleted(before date: Date) async throws -> Int { 0 }
    func bookmarks(for id: TranscriptID) async throws -> [TranscriptBookmark] {
        savedBookmarks.values.filter { $0.transcriptID == id }
    }
    func save(_ bookmark: TranscriptBookmark) async throws { savedBookmarks[bookmark.id] = bookmark }
}

/// Scripted player for deterministic tests.
@MainActor
final class FakePlayer: PlayerControlling {
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 100
    var isPlaying = false
    var onTick: (@MainActor (TimeInterval) -> Void)?
    var onPlayingChanged: (@MainActor (Bool) -> Void)?
    private(set) var seeks: [TimeInterval] = []
    private(set) var speed = 1.0
    private(set) var pauseCount = 0
    private(set) var releaseCount = 0

    func seek(to time: TimeInterval) async {
        seeks.append(time)
        currentTime = time
        onTick?(time)
    }
    func play() {
        isPlaying = true
        onPlayingChanged?(true)
    }
    func pause() {
        pauseCount += 1
        isPlaying = false
        onPlayingChanged?(false)
    }
    func setSpeed(_ speed: Double) { self.speed = speed }
    func release() {
        releaseCount += 1
    }
}

enum Fixtures {
    /// A segment whose words are the whitespace tokens of `text`, one second each starting at `start`.
    static func segment(
        _ text: String, start: TimeInterval, speaker: SpeakerID? = nil, language: LanguageCode? = "en", secondsPerWord: TimeInterval = 1
    ) -> Segment {
        let tokens = text.split(separator: " ").map(String.init)
        var words: [Word] = []
        for (index, token) in tokens.enumerated() {
            let begin = start + Double(index) * secondsPerWord
            words.append(Word(text: token, start: begin, end: begin + secondsPerWord, confidence: 0.9))
        }
        return Segment(
            start: start, end: start + Double(tokens.count) * secondsPerWord, text: text, speakerID: speaker, languageCode: language,
            words: words)
    }

    static let alice = Speaker(name: "Alice", colorHex: "#005FB3")
    static let bob = Speaker(name: "Bob", colorHex: "#B34D00")

    static func transcript(mediaAssetID: MediaAssetID? = nil) -> Transcript {
        Transcript(title: "Test", source: .file, duration: 60, speakers: [alice, bob], mediaAssetID: mediaAssetID)
    }

    static func segments() -> [Segment] {
        [
            segment("hello big world", start: 0, speaker: alice.id),
            segment("this is the second segment", start: 3.5, speaker: bob.id),
            segment("and a third one here", start: 9, speaker: alice.id),
        ]
    }

    @MainActor
    static func model(
        segments: [Segment] = Fixtures.segments(), transcript: Transcript = Fixtures.transcript(),
        settings: any SettingsStore = InMemorySettingsStore(), persistDelay: Duration = .milliseconds(5)
    ) async -> (TranscriptEditorModel, FakeTranscriptRepository) {
        let repo = FakeTranscriptRepository(transcript: transcript, segments: segments)
        let model = TranscriptEditorModel(
            transcriptID: transcript.id, repository: repo, settings: settings, persistDelay: persistDelay,
            engineFactory: { _ in nil })
        await model.load()
        return (model, repo)
    }
}
