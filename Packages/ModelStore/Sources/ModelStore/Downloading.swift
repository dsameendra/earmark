import AppCore
import Foundation
import os

/// A single remote file belonging to a model (relative path inside the model folder, source URL, optional size and checksum).
public struct RemoteFile: Sendable, Hashable {
    public var relativePath: String
    public var url: URL
    public var sizeBytes: Int64?
    /// Lowercase hex SHA-256, when known (Hugging Face exposes it for LFS files).
    public var sha256: String?
    public init(relativePath: String, url: URL, sizeBytes: Int64? = nil, sha256: String? = nil) {
        self.relativePath = relativePath
        self.url = url
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
    }

    /// Whether ``relativePath`` is a plain relative path: non-empty, no leading `/` or `~`, no empty, `.` or `..` components,
    /// no backslashes or NUL bytes. Remote manifests are untrusted input (QA B10).
    public var hasSafeRelativePath: Bool {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.hasPrefix("~"),
            !relativePath.contains("\\"), !relativePath.contains("\0")
        else { return false }
        return relativePath.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// The file's destination inside `root`, or `nil` when the path is unsafe or would resolve outside `root`.
    public func destination(in root: URL) -> URL? {
        guard hasSafeRelativePath else { return nil }
        let base = root.standardizedFileURL.path
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        return candidate.path.hasPrefix(base.hasSuffix("/") ? base : base + "/") ? candidate : nil
    }
}

/// Thrown by a ``Downloading`` implementation when a transfer stops before completion (task cancelled, network drop).
/// `resumeData` is opaque to the manager and handed back to the downloader on the next attempt.
public struct DownloadInterruptedError: Error, Sendable {
    public var resumeData: Data?
    public init(resumeData: Data?) { self.resumeData = resumeData }
}

/// A non-2xx HTTP response from a download or manifest request (so retry and resume logic can tell a refusal from an outage).
public struct DownloadHTTPError: Error, Sendable, Equatable {
    public var status: Int
    public init(status: Int) { self.status = status }
}

/// Thrown by a ``Downloading`` implementation when a transfer **fails** (as opposed to being cancelled). `resumeData` is
/// present when the failure left a resumable partial (for example a dropped connection).
public struct DownloadFailedError: Error, Sendable {
    public var underlying: any Error
    public var resumeData: Data?
    public init(underlying: any Error, resumeData: Data? = nil) {
        self.underlying = underlying
        self.resumeData = resumeData
    }
}

/// Transport abstraction so tests never touch the network.
public protocol Downloading: Sendable {
    /// Downloads `url` into a temporary file owned by the caller and returns its location.
    ///
    /// Implementations must call `progress(bytesReceived, bytesTotal)` as data arrives and must throw
    /// ``DownloadInterruptedError`` (with resume data when available) if the surrounding task is cancelled.
    func download(
        from url: URL, resumeData: Data?, progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> URL
}

/// Lists the files that make up a model. Network access happens only when this is called from `ensureAvailable`.
public protocol ManifestResolving: Sendable {
    func files(for model: ModelDescriptor) async throws -> [RemoteFile]
}

/// Hook for models owned by the operating system (SpeechAnalyzer locale assets, Apple Translation languages).
public protocol AppleAssetProviding: Sendable {
    func isInstalled(_ model: ModelID) async -> Bool
    /// Installs the system asset, reporting progress in `0...1`.
    func install(_ model: ModelID, progress: @escaping @Sendable (Double) -> Void) async throws
}

/// Hosts the app is allowed to contact for model downloads (ENG-AC-14).
public struct HostAllowList: Sendable, Equatable {
    public var exactHosts: Set<String>
    public var hostSuffixes: [String]
    public init(exactHosts: Set<String>, hostSuffixes: [String] = []) {
        self.exactHosts = exactHosts
        self.hostSuffixes = hostSuffixes
    }

    /// `huggingface.co`, plus its `*.huggingface.co` and `*.hf.co` CDN hosts that `resolve/` URLs redirect to.
    public static let models = HostAllowList(
        exactHosts: ["huggingface.co", "hf.co"], hostSuffixes: [".huggingface.co", ".hf.co"])

    /// `true` for `https` URLs whose host is allow-listed.
    public func permits(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return exactHosts.contains(host) || hostSuffixes.contains { host.hasSuffix($0) }
    }
}

// MARK: - Hugging Face manifest

/// Resolves a Hugging Face `tree` / `resolve` URL into concrete files using the public tree API (checksums come from LFS oids).
public struct HuggingFaceManifestResolver: ManifestResolving {
    struct Location: Equatable {
        var owner: String
        var repo: String
        var revision: String
        var subpath: String
        var isSingleFile: Bool
    }

    /// Fetches one page of the tree listing; the second value is the next page (`Link: rel="next"`), if any.
    private let fetch: @Sendable (URL) async throws -> (Data, URL?)

    public init() {
        self.fetch = { url in
            let (data, response) = try await URLSession(configuration: .ephemeral).data(from: url)
            guard let http = response as? HTTPURLResponse else { return (data, nil) }
            if !(200..<300).contains(http.statusCode) { throw DownloadHTTPError(status: http.statusCode) }
            return (data, Self.nextPage(inLinkHeader: http.value(forHTTPHeaderField: "Link")))
        }
    }

    /// Test seam: supply the JSON fetch (single page).
    init(fetch: @escaping @Sendable (URL) async throws -> Data) { self.fetch = { (try await fetch($0), nil) } }

    /// Test seam: supply paged JSON fetches.
    init(pages: @escaping @Sendable (URL) async throws -> (Data, URL?)) { self.fetch = pages }

    /// Parses `<https://...>; rel="next"` out of a `Link` header.
    static func nextPage(inLinkHeader header: String?) -> URL? {
        guard let header else { return nil }
        for part in header.split(separator: ",") where part.contains("rel=\"next\"") {
            guard let open = part.firstIndex(of: "<"), let close = part.firstIndex(of: ">"), open < close else { continue }
            return URL(string: String(part[part.index(after: open)..<close]))
        }
        return nil
    }

    public func files(for model: ModelDescriptor) async throws -> [RemoteFile] {
        let primary = try await primaryFiles(for: model)
        let additional = QwenSpeechDetectorFiles.files(for: model.id)
        let paths = (primary + additional).map(\.relativePath)
        guard Set(paths).count == paths.count else {
            throw AppError.modelDownloadFailed(model.id, reason: "The model manifest contains conflicting destination paths.")
        }
        return primary + additional
    }

    private func primaryFiles(for model: ModelDescriptor) async throws -> [RemoteFile] {
        guard let source = model.sourceURL, HostAllowList.models.permits(source), let location = Self.location(of: source) else {
            throw AppError.modelDownloadFailed(model.id, reason: "No allow-listed download source")
        }
        if location.isSingleFile {
            let name = location.subpath.split(separator: "/").last.map(String.init) ?? location.subpath
            return [
                RemoteFile(
                    relativePath: name, url: Self.resolveURL(location, path: location.subpath),
                    sizeBytes: model.sizeBytes > 0 ? model.sizeBytes : nil, sha256: model.sha256)
            ]
        }
        var api = "https://huggingface.co/api/models/\(location.owner)/\(location.repo)/tree/\(location.revision)"
        if !location.subpath.isEmpty { api += "/\(location.subpath)" }
        guard let first = URL(string: api + "?recursive=true") else { throw URLError(.badURL) }
        var next: URL? = first
        var result: [RemoteFile] = []
        var pages = 0
        while let url = next, pages < 50 {
            let (data, following) = try await fetch(url)
            result += try Self.files(fromTreeJSON: data, location: location)
            next = following
            pages += 1
        }
        let selected = Self.filter(result, include: model.downloadInclude, location: location)
        // A catalog entry that names files must find every one of them: a renamed or truncated listing is an error, not a
        // silently partial model.
        let missing = model.downloadInclude.filter { include in
            !selected.contains { $0.relativePath == include || $0.relativePath.hasPrefix(include + "/") }
        }
        if !missing.isEmpty {
            throw AppError.modelDownloadFailed(model.id, reason: "The model listing is missing: \(missing.joined(separator: ", ")).")
        }
        return selected
    }

    /// Keeps files under one of the `include` paths (all files when `include` is empty). Paths are repo-relative.
    static func filter(_ files: [RemoteFile], include: [String], location: Location) -> [RemoteFile] {
        guard !include.isEmpty else { return files }
        let prefix = location.subpath.isEmpty ? "" : location.subpath + "/"
        return files.filter { file in
            let path = prefix + file.relativePath
            return include.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
    }

    static func location(of url: URL) -> Location? {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { return nil }
        let owner = parts[0]
        let repo = parts[1]
        if parts.count == 2 { return Location(owner: owner, repo: repo, revision: "main", subpath: "", isSingleFile: false) }
        guard parts.count >= 4 else { return nil }
        let rest = parts.dropFirst(4).joined(separator: "/")
        switch parts[2] {
        case "tree": return Location(owner: owner, repo: repo, revision: parts[3], subpath: rest, isSingleFile: false)
        case "resolve", "blob":
            return rest.isEmpty ? nil : Location(owner: owner, repo: repo, revision: parts[3], subpath: rest, isSingleFile: true)
        default: return nil
        }
    }

    static func resolveURL(_ location: Location, path: String) -> URL {
        let encoded = path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        return URL(string: "https://huggingface.co/\(location.owner)/\(location.repo)/resolve/\(location.revision)/\(encoded)")!
    }

    static func files(fromTreeJSON data: Data, location: Location) throws -> [RemoteFile] {
        struct Entry: Decodable {
            struct LFS: Decodable { var oid: String }
            var type: String
            var path: String
            var size: Int64?
            var lfs: LFS?
        }
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        let prefix = location.subpath.isEmpty ? "" : location.subpath + "/"
        return entries.filter { $0.type == "file" && $0.path.hasPrefix(prefix) }.map { entry in
            RemoteFile(
                relativePath: String(entry.path.dropFirst(prefix.count)), url: resolveURL(location, path: entry.path),
                sizeBytes: entry.size, sha256: entry.lfs?.oid.lowercased())
        }
    }
}

// MARK: - URLSession transport

/// Production ``Downloading`` implementation: one `URLSessionDownloadTask` per file, producing resume data on cancel.
public struct URLSessionDownloader: Downloading {
    private let allowList: HostAllowList
    public init(allowList: HostAllowList = .models) { self.allowList = allowList }

    public func download(
        from url: URL, resumeData: Data?, progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> URL {
        guard allowList.permits(url) else { throw URLError(.appTransportSecurityRequiresSecureConnection) }
        let transfer = Transfer(allowList: allowList, progress: progress)
        return try await withTaskCancellationHandler {
            try await transfer.start(url: url, resumeData: resumeData)
        } onCancel: {
            transfer.cancel()
        }
    }
}

private final class Transfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<URL, any Error>?
        var task: URLSessionDownloadTask?
        var session: URLSession?
        var cancelled = false
        var finished = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let allowList: HostAllowList
    private let progress: @Sendable (Int64, Int64?) -> Void

    init(allowList: HostAllowList, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.allowList = allowList
        self.progress = progress
    }

    func start(url: URL, resumeData: Data?) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: url)
            let wasCancelled = state.withLock { state -> Bool in
                state.continuation = continuation
                state.task = task
                state.session = session
                return state.cancelled
            }
            if wasCancelled {
                finish(.failure(DownloadInterruptedError(resumeData: resumeData)))
            } else {
                task.resume()
            }
        }
    }

    func cancel() {
        let task = state.withLock { state -> URLSessionDownloadTask? in
            state.cancelled = true
            return state.task
        }
        task?.cancel(byProducingResumeData: { [self] data in finish(.failure(DownloadInterruptedError(resumeData: data))) })
    }

    private func finish(_ result: Result<URL, any Error>) {
        let (continuation, session) = state.withLock { state -> (CheckedContinuation<URL, any Error>?, URLSession?) in
            guard !state.finished else { return (nil, nil) }
            state.finished = true
            defer { state.continuation = nil }
            return (state.continuation, state.session)
        }
        session?.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // A resumed task replays the original signed CDN URL; once it expires the server answers 403.
            finish(.failure(DownloadFailedError(underlying: DownloadHTTPError(status: http.statusCode))))
            return
        }
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("earmark-dl-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            finish(.success(kept))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error else { return }
        let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let userCancelled = state.withLock { $0.cancelled }
        if userCancelled || (error as? URLError)?.code == .cancelled {
            finish(.failure(DownloadInterruptedError(resumeData: data)))
        } else {
            // A real failure (offline, timeout, bad resume data): report it, do not disguise it as a pause.
            finish(.failure(DownloadFailedError(underlying: error, resumeData: data)))
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(request.url.map(allowList.permits) == true ? request : nil)
    }
}
