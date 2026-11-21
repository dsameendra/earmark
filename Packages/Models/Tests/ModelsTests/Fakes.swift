import AppCore
import Foundation
import os

@testable import Models

/// Scripted downloader: serves in-memory payloads, optionally stalling mid-transfer until the task is cancelled.
final class FakeDownloader: Downloading, Sendable {
    struct Call: Sendable, Equatable {
        var url: URL
        var resumeData: Data?
    }
    private struct State {
        var payloads: [URL: Data] = [:]
        var stallOnce: Set<URL> = []
        var calls: [Call] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func serve(_ url: URL, _ data: Data, stallOnce: Bool = false) {
        state.withLock {
            $0.payloads[url] = data
            if stallOnce { $0.stallOnce.insert(url) }
        }
    }

    var calls: [Call] { state.withLock { $0.calls } }

    func download(from url: URL, resumeData: Data?, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL {
        let (data, stall) = state.withLock { state -> (Data?, Bool) in
            state.calls.append(Call(url: url, resumeData: resumeData))
            let stall = resumeData == nil && state.stallOnce.remove(url) != nil
            return (state.payloads[url], stall)
        }
        guard let data else { throw URLError(.fileDoesNotExist) }
        let total = Int64(data.count)
        if stall {
            progress(total / 2, total)
            do { try await Task.sleep(for: .seconds(60)) } catch {
                throw DownloadInterruptedError(resumeData: Data("offset=\(total / 2)".utf8))
            }
        }
        progress(total, total)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("fake-\(UUID().uuidString)")
        try data.write(to: temp)
        return temp
    }
}

struct FakeManifests: ManifestResolving {
    var files: [ModelID: [RemoteFile]]
    func files(for model: ModelDescriptor) async throws -> [RemoteFile] {
        guard let result = files[model.id] else { throw AppError.modelDownloadFailed(model.id, reason: "no manifest") }
        return result
    }
}

final class FakeAppleAssets: AppleAssetProviding, Sendable {
    private let installed = OSAllocatedUnfairLock(initialState: Set<ModelID>())
    func isInstalled(_ model: ModelID) async -> Bool { installed.withLock { $0.contains(model) } }
    func install(_ model: ModelID, progress: @escaping @Sendable (Double) -> Void) async throws {
        progress(0.5)
        _ = installed.withLock { $0.insert(model) }
    }
}

func hf(_ path: String) -> URL { URL(string: "https://huggingface.co/test/repo/resolve/main/\(path)")! }

func makeTempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("earmark-models-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func collect(_ stream: AsyncThrowingStream<ModelDownloadEvent, any Error>) async throws -> [ModelDownloadEvent] {
    var events: [ModelDownloadEvent] = []
    for try await event in stream { events.append(event) }
    return events
}
