import AppCore
import Foundation
import Testing

@testable import Jobs

@Suite("File batch options")
struct FileOptionsTests {
    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("jobs-library-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("FILE-AC-16: referenced media stores a bookmark and is not library-owned")
    func referencedByDefault() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try Harness(libraryRoot: root)
        let file = try h.makeFile("ref.wav")
        let id = try #require(try await h.queue.enqueue(files: [file], settings: JobSettings(), recursive: false).first)
        #expect(await h.waitFor(id, .completed))
        let asset = try await h.asset(of: try await h.transcript(of: try #require(await h.job(id))))
        #expect(!asset.isOwnedByLibrary && asset.libraryRelativePath == nil && asset.bookmark != nil)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Media").path))
    }

    @Test("FILE-AC-16: copy into library copies the file, marks the asset library-owned and drops the bookmark")
    func copiesIntoLibrary() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try Harness(libraryRoot: root)
        let file = try h.makeFile("owned.wav")
        let settings = JobSettings(copyIntoLibrary: true)
        let id = try #require(try await h.queue.enqueue(files: [file], settings: settings, recursive: false).first)
        #expect(await h.waitFor(id, .completed))
        let asset = try await h.asset(of: try await h.transcript(of: try #require(await h.job(id))))
        #expect(asset.isOwnedByLibrary && asset.bookmark == nil)
        let relative = try #require(asset.libraryRelativePath)
        #expect(relative == "Media/\(asset.id.rawValue.uuidString)/owned.wav")
        #expect(try Data(contentsOf: root.appending(path: relative)) == Data("x".utf8))
        #expect(FileManager.default.fileExists(atPath: file.path), "the original is untouched")
    }

    @Test("FILE-AC-16: without a library folder the job still completes and references the original")
    func copyFallsBackToReference() async throws {
        let h = try Harness()
        let file = try h.makeFile("fallback.wav")
        let id = try #require(try await h.queue.enqueue(files: [file], settings: JobSettings(copyIntoLibrary: true), recursive: false).first)
        #expect(await h.waitFor(id, .completed))
        let asset = try await h.asset(of: try await h.transcript(of: try #require(await h.job(id))))
        #expect(!asset.isOwnedByLibrary && asset.bookmark != nil)
    }

    @Test("FILE-AC-04: each request keeps its own settings, expands folders with them and stays one batch")
    func perRequestSettings() async throws {
        let h = try Harness()
        let a = try h.makeFile("a.wav")
        let b = try h.makeFile("sub/b.wav")
        let c = try h.makeFile("sub/c.wav")
        let custom = JobSettings(languageMode: .single(.sinhala), diarize: true)
        let ids = try await h.queue.enqueue(
            requests: [
                FileJobRequest(url: a, settings: JobSettings()),
                FileJobRequest(url: b.deletingLastPathComponent(), settings: custom),
            ], recursive: true)
        #expect(ids.count == 3)
        let jobs = await h.queue.jobs()
        let byName = Dictionary(uniqueKeysWithValues: jobs.compactMap { job in job.input.map { ($0.lastPathComponent, job.settings) } })
        #expect(byName["a.wav"] == JobSettings())
        #expect(byName["b.wav"] == custom && byName["c.wav"] == custom)
        _ = c
    }

    @Test("older journaled settings without copyIntoLibrary still decode")
    func legacyJSONDecodes() throws {
        let encoded = try JSONEncoder().encode(JobSettings(diarize: true))
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "copyIntoLibrary")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(JobSettings.self, from: legacy)
        #expect(decoded.diarize && !decoded.copyIntoLibrary)
    }
}
