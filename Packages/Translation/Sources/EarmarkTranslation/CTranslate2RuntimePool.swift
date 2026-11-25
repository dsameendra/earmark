import AppCore
import Foundation
import TextModelProfiles
import NativeWorkerKit

enum TranslationWorkerProfile: Sendable, Equatable {
    case ctranslate2(CTranslate2ModelProfile)
    case generative(GenerativeProfile)
}

/// Owns one heavy native translation worker across checkpoint families. A lease spans
/// model selection and inference, including suspension points. Switching evicts the old
/// worker; releasing a stale runtime cannot unload the current owner's model.
public actor CTranslate2RuntimePool {
    private struct Active {
        let owner: UUID
        let folder: URL
        let profile: TranslationWorkerProfile
        let runtime: any NLLBRuntime
        var ready: Bool
    }
    private let makeRuntime: @Sendable (TranslationWorkerProfile) -> any NLLBRuntime
    private var active: Active?
    private let gate = TranslationOperationGate()

    public init(nativeExecutable: URL, generativeExecutable: URL? = nil) {
        makeRuntime = { profile in
            switch profile {
            case .ctranslate2(let profile): return CTranslate2WorkerRuntime(nativeExecutable: nativeExecutable, profile: profile)
            case .generative(let profile):
                guard let generativeExecutable else { return UnavailableGenerativeRuntime() }
                return CTranslate2WorkerRuntime(nativeExecutable: generativeExecutable, generativeProfile: profile)
            }
        }
    }

    init(makeRuntime: @escaping @Sendable (CTranslate2ModelProfile) -> any NLLBRuntime) {
        self.makeRuntime = { profile in
            switch profile {
            case .ctranslate2(let value): makeRuntime(value)
            case .generative: UnavailableGenerativeRuntime()
            }
        }
    }

    init(makeTranslationRuntime: @escaping @Sendable (TranslationWorkerProfile) -> any NLLBRuntime) {
        makeRuntime = makeTranslationRuntime
    }

    public nonisolated func runtime(profile: CTranslate2ModelProfile) -> PooledCTranslate2Runtime {
        PooledCTranslate2Runtime(pool: self, profile: .ctranslate2(profile))
    }

    public nonisolated func runtime(profile: GenerativeProfile) -> PooledCTranslate2Runtime {
        PooledCTranslate2Runtime(pool: self, profile: .generative(profile))
    }

    func workerProcessIdentifier() async -> Int32? {
        guard let runtime = active?.runtime as? CTranslate2WorkerRuntime else { return nil }
        return await runtime.workerProcessIdentifier()
    }

    fileprivate func prepare(owner: UUID, folder: URL, profile: TranslationWorkerProfile) async throws {
        try await gate.withLease { _ = try await self.select(owner: owner, folder: folder, profile: profile) }
    }

    fileprivate func translate(
        owner: UUID, folder: URL, profile: TranslationWorkerProfile, texts: [String], source: String, target: String
    ) async throws -> [String] {
        try await gate.withLease {
            try await self.translateLocked(owner: owner, folder: folder, profile: profile, texts: texts, source: source, target: target)
        }
    }

    private func translateLocked(
        owner: UUID, folder: URL, profile: TranslationWorkerProfile, texts: [String], source: String, target: String
    ) async throws -> [String] {
        let runtime = try await select(owner: owner, folder: folder, profile: profile)
        return try await runtime.translate(texts, source: source, target: target)
    }

    private func select(owner: UUID, folder: URL, profile: TranslationWorkerProfile) async throws -> any NLLBRuntime {
        try Task.checkCancellation()
        if let active, active.ready, active.owner == owner, active.folder == folder, active.profile == profile { return active.runtime }
        if let previous = active {
            guard await stop(previous.runtime) else {
                active?.ready = false
                throw AppError.other("The previous translation worker has not stopped. A replacement cannot load until it exits.")
            }
            active = nil
        }
        try Task.checkCancellation()
        let runtime = makeRuntime(profile)
        active = Active(owner: owner, folder: folder, profile: profile, runtime: runtime, ready: false)
        do { try await runtime.load(modelFolder: folder) } catch {
            if await stop(runtime) { active = nil }
            throw error
        }
        active?.ready = true
        return runtime
    }

    fileprivate func unload(owner: UUID) async {
        await gate.cleanup { await self.unloadLocked(owner: owner) }
    }

    private func unloadLocked(owner: UUID) async {
        guard let previous = active, previous.owner == owner else { return }
        if await stop(previous.runtime) { active = nil }
        else { active?.ready = false }
    }

    private func stop(_ runtime: any NLLBRuntime) async -> Bool {
        if let worker = runtime as? any WorkerStopping { return await worker.stop() }
        await runtime.unload()
        return true
    }

}

/// Per-engine handle. Its folder is retained across eviction; the next request
/// reacquires the right checkpoint instead of using another family's worker.
public actor PooledCTranslate2Runtime: NLLBRuntime {
    private let pool: CTranslate2RuntimePool
    private let profile: TranslationWorkerProfile
    private let owner = UUID()
    private var folder: URL?
    private let gate = TranslationOperationGate()

    fileprivate init(pool: CTranslate2RuntimePool, profile: TranslationWorkerProfile) {
        self.pool = pool
        self.profile = profile
    }

    public func load(modelFolder: URL) async throws {
        try await gate.withLease { try await self.loadLocked(modelFolder: modelFolder) }
    }

    private func loadLocked(modelFolder: URL) async throws {
        try await pool.prepare(owner: owner, folder: modelFolder, profile: profile)
        folder = modelFolder
    }

    public func translate(_ texts: [String], source: String, target: String) async throws -> [String] {
        try await gate.withLease { try await self.translateLocked(texts, source: source, target: target) }
    }

    private func translateLocked(_ texts: [String], source: String, target: String) async throws -> [String] {
        guard let folder else { throw AppError.other("Load a translation model before translating.") }
        return try await pool.translate(owner: owner, folder: folder, profile: profile, texts: texts, source: source, target: target)
    }

    public func unload() async {
        await gate.cleanup { await self.unloadLocked() }
    }

    private func unloadLocked() async {
        folder = nil
        await pool.unload(owner: owner)
    }

}

private struct UnavailableGenerativeRuntime: NLLBRuntime {
    func load(modelFolder: URL) async throws { throw AppError.other("The native generative translation helper is unavailable in this build.") }
    func translate(_ texts: [String], source: String, target: String) async throws -> [String] { throw AppError.other("The native generative translation helper is unavailable in this build.") }
    func unload() async {}
}
