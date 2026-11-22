import AppCore
import CryptoKit
import Foundation
import Testing

@testable import ModelStore

private let small: ModelID = "whisperkit/small"

private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

private func tokenizerURL(_ name: String) -> URL { URL(string: "https://huggingface.co/openai/whisper-small/resolve/main/\(name)")! }

private struct Harness {
    let root = makeTempDirectory()
    let downloader = FakeDownloader()
    let apple = FakeAppleAssets()
    var manifests: [ModelID: [RemoteFile]] = [:]

    init(serveTokenizer: Bool = true) {
        for name in WhisperTokenizerFiles.fileNames where serveTokenizer {
            downloader.serve(tokenizerURL(name), Data("tokenizer:\(name)".utf8))
        }
    }

    func manager() -> ModelManager {
        ModelManager(
            rootDirectory: root, downloader: downloader, manifests: FakeManifests(files: manifests), appleAssets: apple)
    }
}

private func twoFileHarness(serveTokenizer: Bool = true) -> (Harness, Data, Data) {
    var harness = Harness(serveTokenizer: serveTokenizer)
    let a = Data(repeating: 1, count: 600)
    let b = Data(repeating: 2, count: 400)
    harness.downloader.serve(hf("a.bin"), a)
    harness.downloader.serve(hf("sub/b.bin"), b)
    harness.manifests[small] = [
        RemoteFile(relativePath: "a.bin", url: hf("a.bin"), sizeBytes: 600, sha256: sha(a)),
        RemoteFile(relativePath: "sub/b.bin", url: hf("sub/b.bin"), sizeBytes: 400, sha256: sha(b)),
    ]
    return (harness, a, b)
}

@Suite("ModelManager downloads")
struct ModelManagerDownloadTests {
    @Test("progress is monotonic, verifies, and installs atomically")
    func progressAndInstall() async throws {
        let (harness, a, b) = twoFileHarness()
        let manager = harness.manager()
        let events = try await collect(manager.ensureAvailable(small))

        let fractions = events.compactMap { event -> Double? in
            if case .progress(let fraction, _, _) = event { return fraction }
            return nil
        }
        #expect(!fractions.isEmpty)
        #expect(fractions == fractions.sorted())
        #expect(fractions.last == 1)
        #expect(events.contains(.verifying))
        #expect(events.last == .completed)

        guard case .installed(let bytes) = await manager.state(of: small) else {
            Issue.record("not installed")
            return
        }
        #expect(bytes == 1000)
        let location = try await manager.location(of: small)
        #expect(try Data(contentsOf: location.appendingPathComponent("a.bin")) == a)
        #expect(try Data(contentsOf: location.appendingPathComponent("sub/b.bin")) == b)
        #expect(!FileManager.default.fileExists(atPath: harness.root.appendingPathComponent(".partial/whisperkit__small").path))
        #expect(await manager.installedModels().contains(small))
    }

    @Test("ENG-AC-14: the Whisper tokenizer is provisioned in the Hub layout WhisperKit reads")
    func tokenizerProvisioned() async throws {
        let (harness, _, _) = twoFileHarness()
        let manager = harness.manager()
        _ = try await collect(manager.ensureAvailable(small))
        let folder = WhisperTokenizerFiles.folder(repo: "openai/whisper-small", under: manager.tokenizerFolder)
        for name in WhisperTokenizerFiles.fileNames {
            #expect(try Data(contentsOf: folder.appendingPathComponent(name)) == Data("tokenizer:\(name)".utf8))
        }
        #expect(harness.downloader.calls.allSatisfy { $0.url.host == "huggingface.co" })
        #expect(manager.tokenizerFolder.path.hasPrefix(harness.root.path))
    }

    @Test("an installed model without a tokenizer fetches only the tokenizer on ensureAvailable")
    func tokenizerBackfill() async throws {
        let (harness, _, _) = twoFileHarness()
        let manager = harness.manager()
        _ = try await collect(manager.ensureAvailable(small))
        try FileManager.default.removeItem(at: manager.tokenizerFolder)
        let before = harness.downloader.calls.count
        let events = try await collect(manager.ensureAvailable(small))
        #expect(events.last == .completed)
        let newCalls = harness.downloader.calls.dropFirst(before)
        #expect(newCalls.count == WhisperTokenizerFiles.fileNames.count)
        #expect(newCalls.allSatisfy { $0.url.path.contains("openai/whisper-small") })
        guard case .installed = await manager.state(of: small) else {
            Issue.record("model should stay installed")
            return
        }
    }

    @Test("a tokenizer failure after the model downloaded keeps the model installed and retries only the tokenizer")
    func tokenizerFailureDoesNotRedownloadModel() async throws {
        let (harness, _, _) = twoFileHarness(serveTokenizer: false)
        let manager = harness.manager()
        await #expect(throws: AppError.self) { _ = try await collect(manager.ensureAvailable(small)) }
        guard case .installed = await manager.state(of: small) else {
            Issue.record("model must stay installed")
            return
        }
        for name in WhisperTokenizerFiles.fileNames { harness.downloader.serve(tokenizerURL(name), Data("tokenizer:\(name)".utf8)) }
        let before = harness.downloader.calls.count
        let events = try await collect(manager.ensureAvailable(small))
        #expect(events.last == .completed)
        #expect(harness.downloader.calls.count - before == WhisperTokenizerFiles.fileNames.count)
    }

    @Test("tokenizer repos exist for built-in Whisper models only")
    func tokenizerRepos() {
        #expect(WhisperTokenizerFiles.repo(for: "whisperkit/large-v3-v20240930_626MB") == "openai/whisper-large-v3")
        #expect(WhisperTokenizerFiles.repo(for: "whisperkit/small") == "openai/whisper-small")
        #expect(WhisperTokenizerFiles.repo(for: "mlx/qwen3-asr-0.6b-sinhala-8bit") == nil)
        #expect(WhisperTokenizerFiles.repo(for: "custom/abc") == nil)
    }

    @Test("state survives a restart")
    func persistence() async throws {
        let (harness, _, _) = twoFileHarness()
        _ = try await collect(harness.manager().ensureAvailable(small))
        let reborn = harness.manager()
        guard case .installed = await reborn.state(of: small) else {
            Issue.record("not installed after restart")
            return
        }
        // Already installed: no network.
        let callsBefore = harness.downloader.calls.count
        let events = try await collect(reborn.ensureAvailable(small))
        #expect(events == [.completed])
        #expect(harness.downloader.calls.count == callsBefore)
    }

    @Test("checksum mismatch deletes data and throws")
    func checksumFailure() async throws {
        var harness = Harness()
        harness.downloader.serve(hf("a.bin"), Data("hello".utf8))
        harness.manifests[small] = [
            RemoteFile(relativePath: "a.bin", url: hf("a.bin"), sizeBytes: 5, sha256: String(repeating: "0", count: 64))
        ]
        let manager = harness.manager()
        await #expect(throws: AppError.checksumMismatch(small)) { try await collect(manager.ensureAvailable(small)) }
        guard case .failed = await manager.state(of: small) else {
            Issue.record("expected failed state")
            return
        }
        await #expect(throws: AppError.modelNotInstalled(small)) { try await manager.location(of: small) }
        #expect(!FileManager.default.fileExists(atPath: harness.root.appendingPathComponent(".partial/whisperkit__small").path))
    }

    @Test("manifest paths that escape the model folder are rejected before any download (QA B10)")
    func rejectsTraversal() async throws {
        for bad in ["../evil.bin", "sub/../../evil.bin", "/etc/evil.bin", "", "a//b.bin", "./a.bin", "~/x", "a\\b"] {
            var harness = Harness()
            harness.downloader.serve(hf("a.bin"), Data("hello".utf8))
            harness.manifests[small] = [RemoteFile(relativePath: bad, url: hf("a.bin"), sizeBytes: 5)]
            let manager = harness.manager()
            await #expect(throws: AppError.self, "path \(bad)") { try await collect(manager.ensureAvailable(small)) }
            #expect(harness.downloader.calls.isEmpty, "path \(bad)")
        }
        let root = URL(fileURLWithPath: "/tmp/model-root")
        #expect(RemoteFile(relativePath: "sub/b.bin", url: hf("b")).destination(in: root)?.path == "/tmp/model-root/sub/b.bin")
        #expect(RemoteFile(relativePath: "../b.bin", url: hf("b")).destination(in: root) == nil)
    }

    @Test("descriptor-level checksum applies to single-file downloads")
    func singleFileDescriptorHash() async throws {
        let harness = Harness()
        let url = hf("only.gguf")
        let data = Data("payload".utf8)
        harness.downloader.serve(url, data)
        let id: ModelID = "madlad/400-3b-mt-q4k"
        var h = harness
        h.manifests[id] = [RemoteFile(relativePath: "only.gguf", url: url, sizeBytes: 7, sha256: sha(data))]
        _ = try await collect(h.manager().ensureAvailable(id))
    }

    @Test("pause keeps resume data, resume continues from it, and paused state persists")
    func pauseResume() async throws {
        let (harness, _, _) = twoFileHarness()
        harness.downloader.serve(hf("a.bin"), Data(repeating: 1, count: 600), stallOnce: true)
        let manager = harness.manager()
        let stream = manager.ensureAvailable(small)
        let consumer = Task { try await collect(stream) }

        var changes = manager.stateChanges().makeAsyncIterator()
        while let (id, state) = await changes.next() {
            if id == small, case .downloading(let fraction) = state, fraction > 0 { break }
        }
        await manager.pauseDownload(small)
        guard case .paused(let fraction) = await manager.state(of: small) else {
            Issue.record("expected paused")
            return
        }
        #expect(fraction > 0)

        // A fresh manager (app restart) still sees the paused download.
        guard case .paused = await harness.manager().state(of: small) else {
            Issue.record("paused state not persisted")
            return
        }

        await manager.resumeDownload(small)
        let events = try await consumer.value
        #expect(events.last == .completed)
        let resumed = harness.downloader.calls.filter { $0.url == hf("a.bin") }
        #expect(resumed.count == 2)
        #expect(resumed.last?.resumeData == Data("offset=300".utf8))
        guard case .installed(let bytes) = await manager.state(of: small) else {
            Issue.record("not installed after resume")
            return
        }
        #expect(bytes == 1000)
    }

    @Test("cancel removes partial data and fails subscribers")
    func cancel() async throws {
        let (harness, _, _) = twoFileHarness()
        harness.downloader.serve(hf("a.bin"), Data(repeating: 1, count: 600), stallOnce: true)
        let manager = harness.manager()
        let consumer = Task { try await collect(manager.ensureAvailable(small)) }
        var changes = manager.stateChanges().makeAsyncIterator()
        while let (id, state) = await changes.next() {
            if id == small, case .downloading(let fraction) = state, fraction > 0 { break }
        }
        await manager.cancelDownload(small)
        await #expect(throws: AppError.cancelled) { try await consumer.value }
        #expect(await manager.state(of: small) == .notInstalled)
        #expect(!FileManager.default.fileExists(atPath: harness.root.appendingPathComponent(".partial/whisperkit__small").path))
    }

    @Test("non-allow-listed hosts are refused before any transfer")
    func hostAllowList() async throws {
        var harness = Harness()
        let evil = URL(string: "https://evil.example.com/a.bin")!
        harness.downloader.serve(evil, Data("x".utf8))
        harness.manifests[small] = [RemoteFile(relativePath: "a.bin", url: evil, sizeBytes: 1)]
        let manager = harness.manager()
        await #expect(throws: AppError.self) { try await collect(manager.ensureAvailable(small)) }
        #expect(harness.downloader.calls.isEmpty)

        #expect(HostAllowList.models.permits(URL(string: "https://huggingface.co/a")!))
        #expect(HostAllowList.models.permits(URL(string: "https://cdn-lfs.hf.co/a")!))
        #expect(!HostAllowList.models.permits(URL(string: "http://huggingface.co/a")!))
        #expect(!HostAllowList.models.permits(URL(string: "https://nothuggingface.co/a")!))
    }

    @Test("no network activity without ensureAvailable")
    func noNetworkByDefault() async {
        let harness = Harness()
        let manager = harness.manager()
        _ = await manager.catalog()
        _ = await manager.installedModels()
        _ = await manager.diskUsage()
        for descriptor in await manager.catalog() { _ = await manager.state(of: descriptor.id) }
        #expect(harness.downloader.calls.isEmpty)
    }

    @Test("Apple assets install through the provider hook")
    func appleAssets() async throws {
        let harness = Harness()
        let manager = harness.manager()
        let id: ModelID = "apple/speech-analyzer"
        #expect(await manager.state(of: id) == .notInstalled)
        let events = try await collect(manager.ensureAvailable(id))
        #expect(events.last == .completed)
        #expect(await manager.installedModels().contains(id))
        await #expect(throws: AppError.self) { try await manager.delete(id) }
    }
}

@Suite("ModelManager storage")
struct ModelManagerStorageTests {
    @Test("delete removes files and updates disk usage")
    func delete() async throws {
        let (harness, _, _) = twoFileHarness()
        let manager = harness.manager()
        _ = try await collect(manager.ensureAvailable(small))
        #expect(await manager.diskUsage().totalBytes == 1000)
        #expect(await manager.diskUsage().perModel[small] == 1000)
        let location = try await manager.location(of: small)

        try await manager.delete(small)
        #expect(!FileManager.default.fileExists(atPath: location.path))
        #expect(await manager.state(of: small) == .notInstalled)
        #expect(await manager.diskUsage().totalBytes == 0)
        await #expect(throws: AppError.modelNotInstalled(small)) { try await manager.location(of: small) }
    }

    private func makeWhisperFolder(complete: Bool = true) throws -> URL {
        let dir = makeTempDirectory().appendingPathComponent("my-sinhala")
        let names = complete ? ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"] : ["AudioEncoder.mlmodelc"]
        for name in names {
            let sub = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try Data(repeating: 7, count: 128).write(to: sub.appendingPathComponent("weights.bin"))
        }
        return dir
    }

    @Test("import registers a custom model that persists and can be deleted")
    func importCustom() async throws {
        let harness = Harness()
        let manager = harness.manager()
        let folder = try makeWhisperFolder()
        let descriptor = try await manager.importModel(folder: folder, displayName: "My Sinhala", languages: ["si"])

        #expect(descriptor.isCustom)
        #expect(descriptor.languages == ["si"])
        #expect(descriptor.sizeBytes == 384)
        #expect(await manager.catalog().contains { $0.id == descriptor.id })
        #expect(await manager.state(of: descriptor.id) == .installed(bytesOnDisk: 384))
        #expect(FileManager.default.fileExists(atPath: folder.path), "source folder is copied, not moved")

        let reborn = harness.manager()
        #expect(await reborn.catalog().contains { $0.id == descriptor.id })
        #expect(await reborn.installedModels().contains(descriptor.id))

        try await reborn.delete(descriptor.id)
        #expect(!(await reborn.catalog().contains { $0.id == descriptor.id }))
    }

    @Test("import rejects partial folders, files and empty language sets")
    func importValidation() async throws {
        let manager = Harness().manager()
        let partial = try makeWhisperFolder(complete: false)
        await #expect(throws: AppError.self) { try await manager.importModel(folder: partial, displayName: "x", languages: ["si"]) }
        let missing = partial.appendingPathComponent("nope")
        await #expect(throws: AppError.self) { try await manager.importModel(folder: missing, displayName: "x", languages: ["si"]) }
        let full = try makeWhisperFolder()
        await #expect(throws: AppError.self) { try await manager.importModel(folder: full, displayName: "x", languages: []) }
        #expect(await manager.catalog().count == BuiltInCatalog.models.count)
    }

    @Test("deleting a resident model unloads it first")
    func deleteEvictsResidency() async throws {
        let (harness, _, _) = twoFileHarness()
        let manager = harness.manager()
        _ = try await collect(manager.ensureAvailable(small))
        let unloaded = UnloadLog()
        await manager.residency.setUnloadHandler { await unloaded.record($0) }
        try await manager.residency.prepareToLoad(small, isHeavy: true)
        try await manager.delete(small)
        #expect(await unloaded.ids == [small])
        #expect(!(await manager.residency.isResident(small)))
    }
}

@Suite("Catalog")
struct CatalogTests {
    @Test("ids unique, required models present, licences flagged per ADR-006")
    func catalog() {
        let models = BuiltInCatalog.models
        #expect(Set(models.map(\.id)).count == models.count)
        let byID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        for id in [
            "apple/speech-analyzer", "whisperkit/large-v3-v20240930_626MB", "whisperkit/large-v3-v20240930_turbo_632MB",
            "whisperkit/small", "mlx/qwen3-asr-0.6b-sinhala-8bit", "coreml/whisper-small-sinhala",
            "fluidaudio/diarization-community-1", "fluidaudio/ls-eend-ami", "fluidaudio/sortformer-v2", "apple/translation",
            "nllb/200-distilled-600M", "madlad/400-3b-mt-q4k", "fluidaudio/parakeet-tdt-v3",
        ] as [ModelID] { #expect(byID[id] != nil, "missing \(id)") }
        #expect(byID["nllb/200-distilled-600M"]?.license.isNonCommercial == true)
        #expect(byID["nllb/200-distilled-600M"]?.license.spdx == "CC-BY-NC-4.0")
        #expect(byID["mlx/qwen3-asr-0.6b-sinhala-8bit"]?.license.spdx == "CC-BY-SA-4.0")
        #expect(byID["mlx/qwen3-asr-0.6b-sinhala-8bit"]?.license.attribution != nil)
        #expect(byID["madlad/400-3b-mt-q4k"]?.license.spdx == "Apache-2.0")
        #expect(byID["whisperkit/large-v3-v20240930_626MB"]?.license.spdx == "MIT")
        #expect(byID["mlx/qwen3-asr-0.6b-sinhala-8bit"]?.languages == ["si"])
        #expect(!(byID["whisperkit/large-v3-v20240930_626MB"]?.languages.contains("si") ?? true), "stock Whisper never covers Sinhala")
        #expect(models.filter { $0.sourceURL != nil }.allSatisfy { HostAllowList.models.permits($0.sourceURL!) })
    }

    @Test("Hugging Face tree JSON becomes files with LFS checksums")
    func manifestParsing() async throws {
        let json = """
            [{"type":"directory","path":"m"},
             {"type":"file","path":"m/config.json","size":10},
             {"type":"file","path":"m/Enc/weights.bin","size":99,"lfs":{"oid":"ABCDEF","size":99}}]
            """
        let resolver = HuggingFaceManifestResolver { url in
            #expect(url.absoluteString == "https://huggingface.co/api/models/o/r/tree/main/m?recursive=true")
            return Data(json.utf8)
        }
        var descriptor = BuiltInCatalog.models[3]
        descriptor.sourceURL = URL(string: "https://huggingface.co/o/r/tree/main/m")
        let files = try await resolver.files(for: descriptor)
        #expect(files.map(\.relativePath) == ["config.json", "Enc/weights.bin"])
        #expect(files[1].sha256 == "abcdef")
        #expect(files[1].url.absoluteString == "https://huggingface.co/o/r/resolve/main/m/Enc/weights.bin")

        descriptor.sourceURL = URL(string: "https://example.com/o/r/tree/main/m")
        await #expect(throws: AppError.self) { try await resolver.files(for: descriptor) }
    }
}

actor UnloadLog {
    private(set) var ids: [ModelID] = []
    func record(_ id: ModelID) { ids.append(id) }
}
