import AppCore
import AppCoreTesting
import AudioCapture
import Foundation
import Models
import Persistence
import Testing
import Transcription

@testable import Jobs

/// Locates the small Whisper model, its tokenizer and the LibriSpeech fixture on this machine. Nothing is ever downloaded:
/// the test is skipped unless all three already exist locally.
enum WhisperIntegrationEnvironment {
    private static var fm: FileManager { .default }
    private static var home: URL { fm.homeDirectoryForCurrentUser }

    static var modelFolder: URL? {
        candidates(
            env: "EARMARK_WHISPER_SMALL_FOLDER",
            [home.appendingPathComponent("Library/Application Support/Earmark/Models/whisperkit__small")]
        ).first { fm.fileExists(atPath: $0.appendingPathComponent("AudioEncoder.mlmodelc").path) }
    }

    /// A folder with `models/openai/whisper-small/tokenizer.json` (the layout the Models package provisions).
    static var tokenizerFolder: URL? {
        candidates(
            env: "EARMARK_TOKENIZER_FOLDER",
            [
                home.appendingPathComponent("Library/Application Support/Earmark/Models/Tokenizers"),
                home.appendingPathComponent("Documents/huggingface"),
            ]
        ).first {
            fm.fileExists(
                atPath: WhisperTokenizerFiles.folder(repo: "openai/whisper-small", under: $0).appendingPathComponent("tokenizer.json").path)
        }
    }

    /// Searches upward from this file, then the main checkout when running from a git worktree (large audio is untracked).
    static var fixtureDirectory: URL? {
        var roots: [URL] = []
        if let env = ProcessInfo.processInfo.environment["EARMARK_FIXTURES"] { roots.append(URL(fileURLWithPath: env)) }
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            roots.append(dir.appendingPathComponent("fixtures"))
            if let range = dir.path.range(of: "/.claude/worktrees/") {
                roots.append(URL(fileURLWithPath: String(dir.path[..<range.lowerBound])).appendingPathComponent("fixtures"))
            }
            dir.deleteLastPathComponent()
        }
        return roots.map { $0.appendingPathComponent("en-single-librispeech") }.first {
            fm.fileExists(atPath: $0.appendingPathComponent("en-single-librispeech.wav").path)
        }
    }

    static var isAvailable: Bool { modelFolder != nil && tokenizerFolder != nil && fixtureDirectory != nil }

    private static func candidates(env: String, _ defaults: [URL]) -> [URL] {
        (ProcessInfo.processInfo.environment[env].map { [URL(fileURLWithPath: $0)] } ?? []) + defaults
    }
}

@Suite("Whisper integration")
struct WhisperIntegrationTests {
    @Test(
        "T10 integration: en-single-librispeech through the queue with the local whisper small model",
        .enabled(if: WhisperIntegrationEnvironment.isAvailable, "needs a local whisper small model, tokenizer and fixture"),
        .timeLimit(.minutes(10)))
    func transcribesFixture() async throws {
        let modelFolder = try #require(WhisperIntegrationEnvironment.modelFolder)
        let tokenizer = try #require(WhisperIntegrationEnvironment.tokenizerFolder)
        let fixture = try #require(WhisperIntegrationEnvironment.fixtureDirectory)
        let reference = try String(contentsOf: fixture.appendingPathComponent("en-single-librispeech.txt"), encoding: .utf8)

        let small = RoutingTargets.whisperSmall
        let engine = WhisperKitEngine(locate: { _ in modelFolder }, tokenizerFolder: tokenizer)
        let db = try AppDatabase.inMemory()
        let decoder = AVFileDecoder()
        let queue = PersistentJobQueue(
            services: JobQueueServices(
                jobs: db.jobs, transcripts: db.transcripts, media: db.media, rules: db.rules, settings: db.makeSettingsStore(),
                models: MockModelManager(descriptors: BuiltInCatalog.models, installed: [small]), hardware: TestHardware(),
                engines: [engine.id: engine], pipeline: { _ in FileTranscriptionPipeline(decoder: decoder) }, decoder: decoder))

        let id = try await queue.enqueue(
            Job(
                kind: .transcribeFile, input: fixture.appendingPathComponent("en-single-librispeech.wav"),
                settings: JobSettings(modelID: small)))
        let deadline = ContinuousClock.now + Duration.seconds(480)
        while ContinuousClock.now < deadline, let state = await queue.jobs().first?.state, !JobStateMachine.isTerminal(state) {
            try await Task.sleep(for: .milliseconds(200))
        }
        let job = try #require(await queue.jobs().first { $0.id == id })
        #expect(job.state == .completed, "\(job.failureReason ?? "no failure reason")")
        let segments = try await db.transcripts.segments(for: try #require(job.transcriptID))
        #expect(!segments.isEmpty)

        func words(_ text: String) -> [String] {
            text.lowercased().split { !$0.isLetter && $0 != "'" }.map(String.init)
        }
        let heard = Set(words(segments.map(\.text).joined(separator: " ")))
        let expected = words(reference)
        let hits = expected.filter { heard.contains($0) }.count
        #expect(Double(hits) / Double(max(1, expected.count)) > 0.7, "only \(hits)/\(expected.count) reference words were transcribed")
    }
}
