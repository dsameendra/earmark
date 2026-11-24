import AppCore
import Foundation

/// Owns one heavy native translation worker across checkpoint families. A lease spans
/// model selection and inference, including suspension points. Switching evicts the old
/// worker; releasing a stale runtime cannot unload the current owner's model.
public actor CTranslate2RuntimePool {
    private struct Active {
        let owner: UUID
        let folder: URL
        let profile: CTranslate2ModelProfile
        let runtime: any NLLBRuntime
    }
    private let makeRuntime: @Sendable (CTranslate2ModelProfile) -> any NLLBRuntime
    private var active: Active?
    private let gate = TranslationOperationGate()

    public init(nativeExecutable: URL) {
        makeRuntime = { CTranslate2WorkerRuntime(nativeExecutable: nativeExecutable, profile: $0) }
    }

    init(makeRuntime: @escaping @Sendable (CTranslate2ModelProfile) -> any NLLBRuntime) {
        self.makeRuntime = makeRuntime
    }

    public nonisolated func runtime(profile: CTranslate2ModelProfile) -> PooledCTranslate2Runtime {
        PooledCTranslate2Runtime(pool: self, profile: profile)
    }

    fileprivate func prepare(owner: UUID, folder: URL, profile: CTranslate2ModelProfile) async throws {
        try await gate.withLease { _ = try await self.select(owner: owner, folder: folder, profile: profile) }
    }

    fileprivate func translate(
        owner: UUID, folder: URL, profile: CTranslate2ModelProfile, texts: [String], source: String, target: String
    ) async throws -> [String] {
        try await gate.withLease {
            try await self.translateLocked(owner: owner, folder: folder, profile: profile, texts: texts, source: source, target: target)
        }
    }

    private func translateLocked(
        owner: UUID, folder: URL, profile: CTranslate2ModelProfile, texts: [String], source: String, target: String
    ) async throws -> [String] {
        let runtime = try await select(owner: owner, folder: folder, profile: profile)
        return try await runtime.translate(texts, source: source, target: target)
    }

    private func select(owner: UUID, folder: URL, profile: CTranslate2ModelProfile) async throws -> any NLLBRuntime {
        try Task.checkCancellation()
        if let active, active.owner == owner, active.folder == folder, active.profile == profile { return active.runtime }
        if let previous = active {
            active = nil
            await previous.runtime.unload()
        }
        try Task.checkCancellation()
        let runtime = makeRuntime(profile)
        do { try await runtime.load(modelFolder: folder) } catch {
            await runtime.unload()
            throw error
        }
        active = Active(owner: owner, folder: folder, profile: profile, runtime: runtime)
        return runtime
    }

    fileprivate func unload(owner: UUID) async {
        await gate.cleanup { await self.unloadLocked(owner: owner) }
    }

    private func unloadLocked(owner: UUID) async {
        guard let previous = active, previous.owner == owner else { return }
        active = nil
        await previous.runtime.unload()
    }

}

/// Per-engine handle. Its folder is retained across eviction; the next request
/// reacquires the right checkpoint instead of using another family's worker.
public actor PooledCTranslate2Runtime: NLLBRuntime {
    private let pool: CTranslate2RuntimePool
    private let profile: CTranslate2ModelProfile
    private let owner = UUID()
    private var folder: URL?
    private let gate = TranslationOperationGate()

    fileprivate init(pool: CTranslate2RuntimePool, profile: CTranslate2ModelProfile) {
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
