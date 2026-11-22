import AppCore
import CryptoKit
import Foundation
import os

/// Persisted manager state (`state.json` in the models root).
private struct PersistedState: Codable {
    var customModels: [ModelDescriptor] = []
    var installed: [String: Int64] = [:]
    var paused: [String: Double] = [:]
    /// Models whose licence/hardware confirmation the user already gave (SCR-011). Optional so older files still decode.
    var consented: [String]?
}

/// Fan-out of values to any number of `AsyncStream` subscribers; safe to subscribe from non-isolated code.
final class Broadcaster<Element: Sendable>: Sendable {
    private let subscribers = OSAllocatedUnfairLock<[UUID: AsyncStream<Element>.Continuation]>(initialState: [:])

    func stream() -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream<Element>.makeStream()
        let id = UUID()
        subscribers.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.subscribers.withLock { _ = $0.removeValue(forKey: id) }
        }
        return stream
    }

    func send(_ element: Element) {
        let all = subscribers.withLock { Array($0.values) }
        for continuation in all { continuation.yield(element) }
    }
}

/// Latest `(received, total)` pair reported by a downloader callback; read back by an ordered actor hop.
private final class ProgressRelay: Sendable {
    private let value = OSAllocatedUnfairLock<(Int64, Int64?)>(initialState: (0, nil))
    func set(_ received: Int64, _ total: Int64?) { value.withLock { $0 = (received, total) } }
    func get() -> (Int64, Int64?) { value.withLock { $0 } }
}

/// Catalog, download engine, installed-model bookkeeping and custom import (ENG-AC-02..08, 14, 18).
///
/// Layout under `rootDirectory` (default `Application Support/Earmark/Models`):
/// - `<model>/` final, verified model folder (moved in atomically)
/// - `.partial/<model>/payload` files staged so far; `.partial/<model>/resume` per-file resume data
/// - `state.json` installed sizes, paused fractions and custom models
///
/// The manager never touches the network except while running a download started by ``ensureAvailable(_:)``
/// or ``resumeDownload(_:)``, and only against ``HostAllowList`` hosts.
public actor ModelManager: ModelManaging {
    private enum Phase { case running, pausing, paused, cancelling }

    private final class Job {
        var task: Task<Void, Never>?
        var phase: Phase = .running
        var fraction: Double
        /// Only the tokenizer files are missing for an already installed model.
        var tokenizerOnly = false
        var subscribers: [UUID: AsyncThrowingStream<ModelDownloadEvent, any Error>.Continuation] = [:]
        init(fraction: Double) { self.fraction = fraction }
    }

    /// `Application Support/Earmark/Models`.
    public static var defaultRootDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Earmark/Models", isDirectory: true)
    }

    /// LRU residency tracker owned by this manager; engines report loads/unloads here.
    public nonisolated let residency: ModelResidencyTracker

    /// Folder to pass to WhisperKit as `tokenizerFolder`; the Whisper tokenizers are provisioned here with the models.
    public nonisolated let tokenizerFolder: URL

    private let root: URL
    private let downloader: any Downloading
    private let manifests: any ManifestResolving
    private let appleAssets: (any AppleAssetProviding)?
    private let allowList: HostAllowList
    private let consent: (any ModelDownloadConsenting)?
    private let retryPolicy: RetryPolicy
    private let hardwareTier: HardwareTier?
    private let freeDiskBytes: @Sendable (URL) -> Int64?
    private var pendingConsent: [ModelID: Task<Bool, Never>] = [:]
    private let fm = FileManager.default
    private let changes = Broadcaster<(ModelID, ModelState)>()
    private var persisted: PersistedState
    private var jobs: [ModelID: Job] = [:]
    private var failures: [ModelID: String] = [:]

    /// - Parameters:
    ///   - rootDirectory: where models and state live.
    ///   - downloader: transport; inject a fake in tests.
    ///   - manifests: file-list resolver for a model.
    ///   - appleAssets: hook for system-managed assets; `nil` means they are reported as not installed.
    ///   - hardware: used to size the residency tracker (defaults to tier16 semantics when `nil`) and for the tier preflight.
    ///   - consent: confirmation hook for downloads whose preflight `requiresConsent` (non-commercial or share-alike licence,
    ///     under-spec hardware). `nil` means "no gate": callers that already confirmed (Settings) are not asked twice.
    ///   - retryPolicy: retry/backoff for transient network and server failures.
    ///   - freeDiskBytes: free space on the volume holding the given URL; injectable for tests.
    public init(
        rootDirectory: URL = ModelManager.defaultRootDirectory, downloader: any Downloading = URLSessionDownloader(),
        manifests: any ManifestResolving = HuggingFaceManifestResolver(), appleAssets: (any AppleAssetProviding)? = nil,
        allowList: HostAllowList = .models, hardware: (any HardwareTierProviding)? = nil,
        consent: (any ModelDownloadConsenting)? = nil, retryPolicy: RetryPolicy = .standard,
        freeDiskBytes: @escaping @Sendable (URL) -> Int64? = ModelManager.availableDiskBytes
    ) {
        self.consent = consent
        self.retryPolicy = retryPolicy
        self.hardwareTier = hardware?.profile.tier
        self.freeDiskBytes = freeDiskBytes
        self.root = rootDirectory
        self.downloader = downloader
        self.manifests = manifests
        self.appleAssets = appleAssets
        self.allowList = allowList
        self.residency = ModelResidencyTracker(tier: hardware?.profile.tier ?? .tier16)
        self.tokenizerFolder = rootDirectory.appendingPathComponent("Tokenizers", isDirectory: true)
        try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let saved = try? Data(contentsOf: rootDirectory.appendingPathComponent("state.json"))
        self.persisted = saved.flatMap { try? JSONDecoder().decode(PersistedState.self, from: $0) } ?? PersistedState()
    }

    /// Free bytes the system reports as available for important data on the volume containing `url`.
    public static func availableDiskBytes(at url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: ModelManaging

    public func catalog() -> [ModelDescriptor] { BuiltInCatalog.models + persisted.customModels }

    public func state(of model: ModelID) async -> ModelState {
        if let job = jobs[model] {
            return job.phase == .paused ? .paused(fraction: job.fraction) : .downloading(fraction: job.fraction)
        }
        if let reason = failures[model] { return .failed(reason: reason) }
        guard let descriptor = descriptor(model) else { return .notInstalled }
        if descriptor.runtime == .appleAsset {
            return await appleAssets?.isInstalled(model) == true ? .installed(bytesOnDisk: 0) : .notInstalled
        }
        if persisted.installed[model.rawValue] != nil, fm.fileExists(atPath: folder(for: model).path) {
            return .installed(bytesOnDisk: directorySize(folder(for: model)))
        }
        if let fraction = persisted.paused[model.rawValue] { return .paused(fraction: fraction) }
        return .notInstalled
    }

    public nonisolated func stateChanges() -> AsyncStream<(ModelID, ModelState)> { changes.stream() }

    public func installedModels() async -> Set<ModelID> {
        var result: Set<ModelID> = []
        for descriptor in catalog() {
            if case .installed = await state(of: descriptor.id) { result.insert(descriptor.id) }
        }
        return result
    }

    public nonisolated func ensureAvailable(_ model: ModelID) -> AsyncThrowingStream<ModelDownloadEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<ModelDownloadEvent, any Error>.makeStream()
        let subscriber = UUID()
        continuation.onTermination = { [self] _ in Task { await detach(model, subscriber) } }
        Task { await attach(model, subscriber: subscriber, continuation: continuation) }
        return stream
    }

    public nonisolated func retryDownload(_ model: ModelID) -> AsyncThrowingStream<ModelDownloadEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<ModelDownloadEvent, any Error>.makeStream()
        let subscriber = UUID()
        continuation.onTermination = { [self] _ in Task { await detach(model, subscriber) } }
        Task {
            await discardStaleState(model)
            await attach(model, subscriber: subscriber, continuation: continuation)
        }
        return stream
    }

    /// A retry restarts cleanly: the failure and any stale per-file resume data (expired signed URLs) are dropped; files that
    /// already finished stay in the payload folder and are skipped.
    private func discardStaleState(_ model: ModelID) {
        guard jobs[model] == nil else { return }
        failures[model] = nil
        try? fm.removeItem(at: partialDirectory(for: model).appendingPathComponent("resume", isDirectory: true))
    }

    public func preflight(_ model: ModelID) async -> ModelPreflightResult {
        guard let descriptor = descriptor(model) else {
            return ModelPreflightResult(model: model, displayName: model.rawValue, downloadBytes: 0)
        }
        var result = ModelPreflightResult(model: model, displayName: descriptor.displayName, downloadBytes: descriptor.sizeBytes)
        if descriptor.runtime == .appleAsset || descriptor.isCustom || jobs[model] != nil { return result }
        if case .installed = await state(of: model) { return result }
        let license = descriptor.license
        if license.isNonCommercial {
            result.issues.append(.nonCommercialLicense(spdx: license.spdx))
        } else if license.needsAcknowledgement {
            result.issues.append(.licenseNotice(spdx: license.spdx, attribution: license.attribution))
        }
        if let tier = hardwareTier, descriptor.minTier > tier {
            result.issues.append(.hardwareTier(required: descriptor.minTier, available: tier))
        }
        if descriptor.sizeBytes >= 1_000_000_000 { result.issues.append(.largeDownload(bytes: descriptor.sizeBytes)) }
        if let free = freeDiskBytes(root) {
            result.freeDiskBytes = free
            // A resumed or retried download already holds part of the payload on disk; only the rest needs room.
            let alreadyOnDisk = min(descriptor.sizeBytes, directorySize(partialDirectory(for: model)))
            let remaining = descriptor.sizeBytes - alreadyOnDisk
            let needed = remaining + remaining / 5
            if free < needed { result.issues.append(.insufficientDisk(needed: needed, available: free)) }
        }
        return result
    }

    /// `true` once the user confirmed this model's licence/hardware preflight.
    public func hasConsent(for model: ModelID) -> Bool { persisted.consented?.contains(model.rawValue) == true }

    /// Records a confirmation the caller collected itself (for example Settings' own warning dialog), so the consent hook is
    /// not asked again for this model.
    public func grantConsent(for model: ModelID) {
        guard !hasConsent(for: model) else { return }
        persisted.consented = (persisted.consented ?? []) + [model.rawValue]
        save()
    }

    public func recordConsent(for model: ModelID) { grantConsent(for: model) }

    /// Runs the preflight and the consent hook. `nil` means the download may start.
    private func gate(_ model: ModelID) async -> AppError? {
        let result = await preflight(model)
        if let blocking = result.issues.first(where: \.isBlocking) {
            return .modelDownloadFailed(model, reason: blocking.message)
        }
        guard result.requiresConsent, !hasConsent(for: model), let consent else { return nil }
        let task: Task<Bool, Never>
        if let existing = pendingConsent[model] {
            task = existing
        } else {
            task = Task { await consent.confirmDownload(result) }
            pendingConsent[model] = task
        }
        let accepted = await task.value
        pendingConsent[model] = nil
        guard accepted else { return .cancelled }
        grantConsent(for: model)
        return nil
    }

    public func pauseDownload(_ model: ModelID) async {
        guard let job = jobs[model], job.phase == .running else { return }
        job.phase = .pausing
        job.task?.cancel()
        await job.task?.value
    }

    public func resumeDownload(_ model: ModelID) async {
        if let job = jobs[model] {
            guard job.phase == .paused else { return }
            job.phase = .running
            startTask(for: model)
        } else if persisted.paused[model.rawValue] != nil, descriptor(model) != nil {
            let job = Job(fraction: persisted.paused[model.rawValue] ?? 0)
            jobs[model] = job
            startTask(for: model)
        }
    }

    public func cancelDownload(_ model: ModelID) async {
        if let job = jobs[model] {
            if job.phase == .paused {
                finishCancelled(model, job: job)
            } else {
                job.phase = .cancelling
                job.task?.cancel()
                await job.task?.value
            }
        } else if persisted.paused[model.rawValue] != nil || failures[model] != nil {
            // Also the "Cancel" of a failed row: discard the partial download and the failure.
            removePartial(model)
            persisted.paused[model.rawValue] = nil
            failures[model] = nil
            save()
            publish(model, .notInstalled)
        }
    }

    public func delete(_ model: ModelID) async throws {
        guard let descriptor = descriptor(model) else { throw AppError.modelNotInstalled(model) }
        if descriptor.runtime == .appleAsset {
            throw AppError.unsupportedFormat("\(descriptor.displayName) is managed by macOS and cannot be deleted here.")
        }
        await cancelDownload(model)
        await residency.evict(model)
        await residency.markUnloaded(model)
        let dir = folder(for: model)
        if fm.fileExists(atPath: dir.path) { try fm.removeItem(at: dir) }
        removePartial(model)
        persisted.installed[model.rawValue] = nil
        persisted.paused[model.rawValue] = nil
        if descriptor.isCustom { persisted.customModels.removeAll { $0.id == model } }
        failures[model] = nil
        save()
        publish(model, .notInstalled)
    }

    public func importModel(folder source: URL, displayName: String, languages: Set<LanguageCode>) async throws -> ModelDescriptor {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AppError.unsupportedFormat("Not a folder: \(source.lastPathComponent)")
        }
        let required = ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"]
        let missing = required.filter { !fm.fileExists(atPath: source.appendingPathComponent($0).path) }
        guard missing.isEmpty else {
            throw AppError.unsupportedFormat("Not a WhisperKit CoreML folder; missing \(missing.joined(separator: ", ")).")
        }
        guard !languages.isEmpty else { throw AppError.unsupportedFormat("Choose at least one language.") }

        let id = ModelID("custom/\(UUID().uuidString.prefix(8).lowercased())")
        let staging = partialDirectory(for: id).appendingPathComponent("import", isDirectory: true)
        try fm.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: partialDirectory(for: id)) }
        try fm.copyItem(at: source, to: staging)
        try fm.moveItem(at: staging, to: folder(for: id))

        let size = directorySize(folder(for: id))
        let descriptor = ModelDescriptor(
            id: id, displayName: displayName, kind: .asr, runtime: .coreML, engine: "whisperkit", languages: languages,
            sizeBytes: size, license: LicenseInfo(spdx: "NOASSERTION", attribution: "User-imported model."), isExperimental: true,
            notes: "Imported from \(source.lastPathComponent).", isCustom: true)
        persisted.customModels.append(descriptor)
        persisted.installed[id.rawValue] = size
        save()
        publish(id, .installed(bytesOnDisk: size))
        return descriptor
    }

    public func diskUsage() -> DiskUsage {
        var perModel: [ModelID: Int64] = [:]
        for key in persisted.installed.keys {
            let id = ModelID(key)
            let dir = folder(for: id)
            if fm.fileExists(atPath: dir.path) { perModel[id] = directorySize(dir) }
        }
        return DiskUsage(totalBytes: perModel.values.reduce(0, +), perModel: perModel)
    }

    public func location(of model: ModelID) async throws -> URL {
        guard let descriptor = descriptor(model) else { throw AppError.modelNotInstalled(model) }
        if descriptor.runtime == .appleAsset {
            guard await appleAssets?.isInstalled(model) == true else { throw AppError.modelNotInstalled(model) }
            return root
        }
        guard persisted.installed[model.rawValue] != nil, fm.fileExists(atPath: folder(for: model).path) else {
            throw AppError.modelNotInstalled(model)
        }
        return folder(for: model)
    }

    // MARK: Subscription handling

    private func attach(
        _ model: ModelID, subscriber: UUID, continuation: AsyncThrowingStream<ModelDownloadEvent, any Error>.Continuation
    ) async {
        guard descriptor(model) != nil else {
            continuation.finish(throwing: AppError.modelNotInstalled(model))
            return
        }
        if let job = jobs[model] {
            job.subscribers[subscriber] = continuation
            if job.phase == .paused { await resumeDownload(model) }
            return
        }
        if case .installed = await state(of: model) {
            guard needsTokenizer(model) else {
                continuation.yield(.completed)
                continuation.finish()
                return
            }
            // Installed before tokenizers were provisioned: fetch only those small files.
            let tokenizerJob = Job(fraction: 0)
            tokenizerJob.tokenizerOnly = true
            tokenizerJob.subscribers[subscriber] = continuation
            jobs[model] = tokenizerJob
            failures[model] = nil
            startTask(for: model)
            return
        }
        if let refusal = await gate(model) {
            continuation.finish(throwing: refusal)
            return
        }
        if let job = jobs[model] {  // another caller started it while we waited for consent
            job.subscribers[subscriber] = continuation
            return
        }
        let job = Job(fraction: persisted.paused[model.rawValue] ?? 0)
        job.subscribers[subscriber] = continuation
        jobs[model] = job
        failures[model] = nil
        startTask(for: model)
    }

    private func detach(_ model: ModelID, _ subscriber: UUID) { jobs[model]?.subscribers[subscriber] = nil }

    // MARK: Download engine

    private func startTask(for model: ModelID) {
        publish(model, .downloading(fraction: jobs[model]?.fraction ?? 0))
        let task = Task { await self.run(model) }
        jobs[model]?.task = task
    }

    private func run(_ model: ModelID) async {
        guard let descriptor = descriptor(model), let job = jobs[model] else { return }
        do {
            if descriptor.runtime == .appleAsset {
                try await installAppleAsset(descriptor)
            } else {
                if !job.tokenizerOnly {
                    try await perform(descriptor)
                    // The model folder is in place: record the install now, so a tokenizer failure below cannot
                    // force the (large) model to be downloaded again. The rest of this run only fetches the tokenizer.
                    persisted.installed[model.rawValue] = directorySize(folder(for: model))
                    persisted.paused[model.rawValue] = nil
                    save()
                    job.tokenizerOnly = true
                }
                try await provisionTokenizer(for: descriptor)
            }
            jobs[model] = nil
            let size = descriptor.runtime == .appleAsset ? 0 : directorySize(folder(for: model))
            persisted.paused[model.rawValue] = nil
            save()
            publish(model, .installed(bytesOnDisk: size))
            for continuation in job.subscribers.values {
                continuation.yield(.completed)
                continuation.finish()
            }
        } catch {
            handleFailure(error, model: model, job: job)
        }
    }

    private func handleFailure(_ error: any Error, model: ModelID, job: Job) {
        if job.tokenizerOnly {
            // The model itself stays installed; only the tokenizer fetch failed (retried on the next ensureAvailable).
            jobs[model] = nil
            let appError = error as? AppError ?? AppError.modelDownloadFailed(model, reason: Self.reason(for: error))
            publish(model, .installed(bytesOnDisk: directorySize(folder(for: model))))
            for continuation in job.subscribers.values { continuation.finish(throwing: appError) }
            return
        }
        switch job.phase {
        case .pausing:
            job.phase = .paused
            persisted.paused[model.rawValue] = job.fraction
            save()
            publish(model, .paused(fraction: job.fraction))
        case .cancelling:
            finishCancelled(model, job: job)
        default:
            jobs[model] = nil
            let appError = error as? AppError ?? AppError.modelDownloadFailed(model, reason: Self.reason(for: error))
            let hasPartial = fm.fileExists(atPath: partialDirectory(for: model).path)
            if case .checksumMismatch = appError {
                removePartial(model)
            } else if hasPartial {
                persisted.paused[model.rawValue] = job.fraction
                save()
            }
            failures[model] = Self.reason(for: appError)
            publish(model, .failed(reason: failures[model] ?? "Failed"))
            for continuation in job.subscribers.values { continuation.finish(throwing: appError) }
        }
    }

    private func finishCancelled(_ model: ModelID, job: Job) {
        jobs[model] = nil
        removePartial(model)
        persisted.paused[model.rawValue] = nil
        save()
        publish(model, .notInstalled)
        for continuation in job.subscribers.values { continuation.finish(throwing: AppError.cancelled) }
    }

    private func installAppleAsset(_ descriptor: ModelDescriptor) async throws {
        guard let provider = appleAssets else {
            throw AppError.modelDownloadFailed(descriptor.id, reason: "System asset installation is unavailable.")
        }
        let model = descriptor.id
        let relay = ProgressRelay()
        try await provider.install(model) { fraction in
            relay.set(Int64(fraction * 1_000_000), 1_000_000)
            Task { await self.emitProgress(model, base: 0, total: 1_000_000, relay: relay) }
        }
    }

    // swiftlint:disable:next function_body_length
    private func perform(_ descriptor: ModelDescriptor) async throws {
        let model = descriptor.id
        let files = try await withRetry(model) { try await manifests.files(for: descriptor) }
        guard !files.isEmpty else { throw AppError.modelDownloadFailed(model, reason: "Empty file list") }
        for file in files where !allowList.permits(file.url) {
            throw AppError.modelDownloadFailed(model, reason: "Host not allow-listed: \(file.url.host ?? "unknown")")
        }
        for file in files where !file.hasSafeRelativePath {
            throw AppError.modelDownloadFailed(model, reason: "Unsafe file path in the model manifest")
        }
        let known = files.compactMap(\.sizeBytes).reduce(0, +)
        let total = max(known > 0 && files.allSatisfy({ $0.sizeBytes != nil }) ? known : descriptor.sizeBytes, 1)

        let payload = partialDirectory(for: model).appendingPathComponent("payload", isDirectory: true)
        let resumeDir = partialDirectory(for: model).appendingPathComponent("resume", isDirectory: true)
        try fm.createDirectory(at: payload, withIntermediateDirectories: true)
        try fm.createDirectory(at: resumeDir, withIntermediateDirectories: true)

        var done: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            guard let destination = file.destination(in: payload) else {
                throw AppError.modelDownloadFailed(model, reason: "Unsafe file path in the model manifest")
            }
            if let existing = fileSize(destination), file.sizeBytes == nil || existing == file.sizeBytes {
                done += existing
                emitProgress(model, base: done, total: total, relay: ProgressRelay())  // seed progress from files already on disk
                continue
            }
            let resumeFile = resumeDir.appendingPathComponent(SHA256.hash(data: Data(file.relativePath.utf8)).hex)
            let relay = ProgressRelay()
            let base = done
            let temp = try await downloadFile(file, model: model, resumeFile: resumeFile) { received, expected in
                relay.set(received, expected)
                Task { await self.emitProgress(model, base: base, total: total, relay: relay) }
            }
            emitProgress(model, base: base, total: total, relay: relay)  // the file is complete; do not wait for the callback hop
            try? fm.removeItem(at: resumeFile)
            let expectedHash = file.sha256 ?? (files.count == 1 ? descriptor.sha256 : nil)
            if let expectedHash {
                publishVerifying(model)
                let actual = try Self.sha256Hex(of: temp)
                guard actual.caseInsensitiveCompare(expectedHash) == .orderedSame else {
                    try? fm.removeItem(at: temp)
                    removePartial(model)
                    throw AppError.checksumMismatch(model)
                }
            }
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: temp, to: destination)
            done += fileSize(destination) ?? 0
        }
        publishVerifying(model)
        let final = folder(for: model)
        if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
        try fm.moveItem(at: payload, to: final)  // atomic within the same volume
        removePartial(model)
    }

    /// Downloads one file with the recovery rules of SCR-011:
    /// - Resume data that no longer works (HF `resolve/` redirects to a CDN URL signed for about an hour; resuming later gets a
    ///   403) is deleted and the file restarts cleanly from a fresh `resolve/` URL, without counting as a retry.
    /// - Transient network/server failures are retried with exponential backoff, keeping valid resume data.
    /// - Offline fails immediately with ``DownloadMessage/offline``; the partial data is kept for the next retry.
    private func downloadFile(
        _ file: RemoteFile, model: ModelID, resumeFile: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> URL {
        var resume = try? Data(contentsOf: resumeFile)
        var attempt = 0
        while true {
            do {
                return try await downloader.download(from: file.url, resumeData: resume, progress: progress)
            } catch let interrupted as DownloadInterruptedError {
                if let data = interrupted.resumeData { try? data.write(to: resumeFile, options: .atomic) }
                throw interrupted
            } catch let error as AppError {
                throw error
            } catch {
                try Task.checkCancellation()
                let kind = DownloadFailureKind(classifying: error)
                if resume != nil, !kind.preservesResumeData {
                    try? fm.removeItem(at: resumeFile)
                    resume = nil
                    continue
                }
                if let data = (error as? DownloadFailedError)?.resumeData {
                    resume = data
                    try? data.write(to: resumeFile, options: .atomic)
                }
                attempt += 1
                guard kind.isTransient, attempt < retryPolicy.maxAttempts else {
                    throw AppError.modelDownloadFailed(model, reason: kind.message)
                }
                try await Task.sleep(for: retryPolicy.delay(afterAttempt: attempt))
            }
        }
    }

    /// Retries `operation` on transient failures (HTTP 429/5xx, dropped connection) with backoff; offline and other failures
    /// surface immediately as ``AppError/modelDownloadFailed(_:reason:)`` with a clear message.
    private func withRetry<T: Sendable>(_ model: ModelID, _ operation: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch let error as AppError {
                throw error
            } catch let interrupted as DownloadInterruptedError {
                throw interrupted
            } catch {
                try Task.checkCancellation()
                let kind = DownloadFailureKind(classifying: error)
                attempt += 1
                guard kind.isTransient, attempt < retryPolicy.maxAttempts else {
                    throw AppError.modelDownloadFailed(model, reason: kind.message)
                }
                try await Task.sleep(for: retryPolicy.delay(afterAttempt: attempt))
            }
        }
    }

    /// `true` when `model` is a built-in Whisper model whose tokenizer files are not on disk yet.
    private func needsTokenizer(_ model: ModelID) -> Bool {
        guard let repo = WhisperTokenizerFiles.repo(for: model) else { return false }
        let folder = WhisperTokenizerFiles.folder(repo: repo, under: tokenizerFolder)
        return !WhisperTokenizerFiles.fileNames.allSatisfy { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    /// Downloads the Whisper tokenizer files into the Hub-layout folder WhisperKit reads (skips files already present).
    private func provisionTokenizer(for descriptor: ModelDescriptor) async throws {
        let model = descriptor.id
        guard needsTokenizer(model), let repo = WhisperTokenizerFiles.repo(for: model) else { return }
        let folder = WhisperTokenizerFiles.folder(repo: repo, under: tokenizerFolder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in WhisperTokenizerFiles.remoteFiles(repo: repo) {
            try Task.checkCancellation()
            guard let destination = file.destination(in: folder) else {
                throw AppError.modelDownloadFailed(model, reason: "Unsafe file path in the model manifest")
            }
            if fm.fileExists(atPath: destination.path) { continue }
            guard allowList.permits(file.url) else {
                throw AppError.modelDownloadFailed(model, reason: "Host not allow-listed: \(file.url.host ?? "unknown")")
            }
            do {
                let temp = try await withRetry(model) { try await downloader.download(from: file.url, resumeData: nil) { _, _ in } }
                try fm.moveItem(at: temp, to: destination)
            } catch let interrupted as DownloadInterruptedError {
                throw interrupted
            } catch let error as AppError {
                throw error
            } catch {
                throw AppError.modelDownloadFailed(model, reason: "Tokenizer download failed: \(error.localizedDescription)")
            }
        }
    }

    private func emitProgress(_ model: ModelID, base: Int64, total: Int64, relay: ProgressRelay) {
        guard let job = jobs[model], job.phase == .running else { return }
        let (received, _) = relay.get()
        let bytes = min(base + received, total)
        let fraction = max(job.fraction, min(1, Double(bytes) / Double(total)))
        job.fraction = fraction
        publish(model, .downloading(fraction: fraction))
        for continuation in job.subscribers.values {
            continuation.yield(.progress(fraction: fraction, bytesReceived: bytes, bytesTotal: total))
        }
    }

    private func publishVerifying(_ model: ModelID) {
        for continuation in jobs[model]?.subscribers.values ?? [:].values { continuation.yield(.verifying) }
    }

    // MARK: Helpers

    private func descriptor(_ id: ModelID) -> ModelDescriptor? { catalog().first { $0.id == id } }

    private func publish(_ model: ModelID, _ state: ModelState) { changes.send((model, state)) }

    private func folder(for model: ModelID) -> URL {
        root.appendingPathComponent(model.rawValue.replacingOccurrences(of: "/", with: "__"), isDirectory: true)
    }

    private func partialDirectory(for model: ModelID) -> URL {
        root.appendingPathComponent(".partial", isDirectory: true)
            .appendingPathComponent(model.rawValue.replacingOccurrences(of: "/", with: "__"), isDirectory: true)
    }

    private func removePartial(_ model: ModelID) { try? fm.removeItem(at: partialDirectory(for: model)) }

    private func save() {
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        try? data.write(to: root.appendingPathComponent("state.json"), options: .atomic)
    }

    private func fileSize(_ url: URL) -> Int64? {
        (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    private static func reason(for error: any Error) -> String {
        switch error {
        case AppError.checksumMismatch: "Checksum mismatch; the download was discarded."
        case AppError.modelDownloadFailed(_, let reason): reason
        case is DownloadInterruptedError: "The download was interrupted."
        default: error.localizedDescription
        }
    }

    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().hex
    }
}

extension Digest {
    fileprivate var hex: String { map { String(format: "%02x", $0) }.joined() }
}
