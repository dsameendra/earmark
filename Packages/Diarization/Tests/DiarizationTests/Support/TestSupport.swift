import AppCore
import Foundation

/// A `ModelManaging` stub that maps model ids to folders (the spike's `.model-cache`), for integration tests.
struct FolderModelManager: ModelManaging {
    var folders: [ModelID: URL]
    func catalog() async -> [ModelDescriptor] { [] }
    func state(of model: ModelID) async -> ModelState { folders[model] == nil ? .notInstalled : .installed(bytesOnDisk: 1) }
    func stateChanges() -> AsyncStream<(ModelID, ModelState)> { AsyncStream { $0.finish() } }
    func installedModels() async -> Set<ModelID> { Set(folders.keys) }
    func ensureAvailable(_ model: ModelID) -> AsyncThrowingStream<ModelDownloadEvent, any Error> {
        AsyncThrowingStream { $0.finish(throwing: AppError.modelNotInstalled(model)) }
    }
    func pauseDownload(_ model: ModelID) async {}
    func resumeDownload(_ model: ModelID) async {}
    func cancelDownload(_ model: ModelID) async {}
    func delete(_ model: ModelID) async throws {}
    func importModel(folder: URL, displayName: String, languages: Set<LanguageCode>) async throws -> ModelDescriptor {
        throw AppError.other("unsupported")
    }
    func diskUsage() async -> DiskUsage { DiskUsage(totalBytes: 0, perModel: [:]) }
    func location(of model: ModelID) async throws -> URL {
        guard let url = folders[model] else { throw AppError.modelNotInstalled(model) }
        return url
    }
}

/// Locates assets that live only in the main checkout (`.model-cache`, gitignored wavs), searching upward from this file.
enum LocalAssets {
    /// `EARMARK_MODEL_CACHE` overrides the search.
    static let modelCache: URL? = {
        if let path = ProcessInfo.processInfo.environment["EARMARK_MODEL_CACHE"] { return URL(fileURLWithPath: path) }
        return searchUp(for: ".model-cache")
    }()

    /// Searches for the wav itself (a worktree has the fixture folder but not the gitignored audio).
    /// `EARMARK_FIXTURES_DIR` overrides the search.
    static func fixture(_ relativePath: String) -> URL? {
        if let dir = ProcessInfo.processInfo.environment["EARMARK_FIXTURES_DIR"] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(relativePath)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        return searchUp(for: "fixtures/" + relativePath)
    }

    static func repoFile(_ relativePath: String) -> URL? { searchUp(for: relativePath) }

    private static func searchUp(for relative: String) -> URL? {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    static let ami240 = "ami-es2004a-4spk-240s/ES2004a_180-420s.wav"

    /// A model manager over the spike's cache, or nil when the models are not present.
    static func spikeModels() -> FolderModelManager? {
        guard let cache = modelCache else { return nil }
        let fm = FileManager.default
        var folders: [ModelID: URL] = [:]
        let offline = cache.appendingPathComponent("fluidaudio")
        let stream = cache.appendingPathComponent("fluidaudio-stream")
        if fm.fileExists(atPath: offline.appendingPathComponent("speaker-diarization/Segmentation.mlmodelc").path) {
            folders["fluidaudio/diarization-community-1"] = offline
        }
        if fm.fileExists(atPath: stream.appendingPathComponent("ls-eend/ami").path) {
            folders["fluidaudio/ls-eend-ami"] = stream.appendingPathComponent("ls-eend")
        }
        if fm.fileExists(atPath: stream.appendingPathComponent("sortformer/v3").path) {
            folders["fluidaudio/sortformer-v2"] = stream.appendingPathComponent("sortformer")
        }
        return FolderModelManager(folders: folders)
    }
}
