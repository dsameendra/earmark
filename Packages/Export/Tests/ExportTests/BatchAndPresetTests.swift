import AppCore
import Foundation
import Testing
import ZIPFoundation

@testable import Export

private actor PresetStub: PresetRepository {
    var export: [ExportPreset]
    init(_ presets: [ExportPreset] = []) { export = presets }
    func captionPresets() async throws -> [CaptionPreset] { [] }
    func save(_ preset: CaptionPreset) async throws {}
    func exportPresets() async throws -> [ExportPreset] { export }
    func save(_ preset: ExportPreset) async throws { export.append(preset) }
    func softDeletePreset(_ id: PresetID) async throws {}
}

private actor SettingsStub: SettingsStore {
    var values: [String: Data] = [:]
    func value<T: Codable & Sendable>(for key: String, as: T.Type) async -> T? {
        values[key].flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
    func set<T: Codable & Sendable>(_ value: T, for key: String) async { values[key] = try? JSONEncoder().encode(value) }
    nonisolated func changes(for key: String) -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("Batch, presets, auto-export")
struct BatchAndPresetTests {
    @Test("EXP-AC-15: folder batch uses collision-free names, also against existing files")
    func folder() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let docs = [Fixture.document(), Fixture.document(), Fixture.document()]
        let names = try await BatchExporter().export(docs, options: Fixture.options(.txt), to: .folder(dir))
        #expect(names == ["Team Sync.txt", "Team Sync (2).txt", "Team Sync (3).txt"])
        let again = try await BatchExporter().export([Fixture.document()], options: Fixture.options(.txt), to: .folder(dir))
        #expect(again == ["Team Sync (4).txt"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 4)
    }

    @Test("EXP-AC-15: zip batch is a valid archive")
    func zip() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("out.zip")
        let names = try await BatchExporter().export([Fixture.document(), Fixture.document()], options: Fixture.options(.srt), to: .zip(url))
        #expect(names == ["Team Sync.srt", "Team Sync (2).srt"])
        let archive = try Archive(url: url, accessMode: .read)
        #expect(archive.map(\.path) == names)
        var data = Data()
        _ = try archive.extract(try #require(archive["Team Sync.srt"])) { data.append($0) }
        #expect(String(decoding: data, as: UTF8.self).hasPrefix("1\n00:00:00,000"))
    }

    @Test("EXP-AC-16: auto-export writes to the watch folder; failures are returned, not thrown")
    func autoExport() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let preset = ExportPreset(name: "Subs", options: Fixture.options(.vtt))
        let writer = AutoExportWriter(folder: dir.appendingPathComponent("watch"), presets: PresetStub([preset]))
        let started = Date()
        let outcome = await writer.exportCompleted(Fixture.document(), presetID: preset.id)
        #expect(Date().timeIntervalSince(started) < 5)
        guard case .written(let url) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(url.lastPathComponent == "Team Sync.vtt" && FileManager.default.fileExists(atPath: url.path))
        #expect(await writer.exportCompleted(Fixture.document(), presetID: PresetID()) == .failed(reason: "The auto-export preset no longer exists."))
        #expect(await writer.exportCompleted(Fixture.document(), presetID: nil) == .skipped(reason: "No auto-export preset configured"))
        let bad = AutoExportWriter(folder: URL(fileURLWithPath: "/dev/null/nope"), presets: PresetStub([preset]))
        if case .failed = await bad.exportCompleted(Fixture.document(), presetID: preset.id) {} else { Issue.record("expected failure") }
    }

    @Test("EXP-AC-17: last-used preset is preselected; deleted or unknown falls back")
    func presets() async throws {
        let settings = SettingsStub()
        let repo = PresetStub()
        let mine = ExportPreset(name: "Mine", options: Fixture.options(.docx))
        try await repo.save(mine)
        #expect(await ExportPresets.preselected(settings: settings, repository: repo)?.id == mine.id)
        let builtIn = ExportPresets.builtIn[3]
        await ExportPresets.recordLastUsed(builtIn.id, in: settings)
        #expect(await ExportPresets.preselected(settings: settings, repository: repo)?.id == builtIn.id)
        var deleted = builtIn
        deleted.deletedAt = Date()
        #expect(ExportPresets.preselect(from: [deleted, mine], lastUsedID: builtIn.id)?.id == mine.id)
        #expect(Set(ExportPresets.builtIn.map(\.id)).count == ExportPresets.builtIn.count)
    }
}
