import AppCore
import Foundation

/// Tracks which models are loaded in memory, evicts least-recently-used idle ones, and reacts to memory pressure (ADR-007).
///
/// Engines call ``prepareToLoad(_:isHeavy:bytes:)`` before loading a model; the returned (already unloaded) ids tell
/// them what was evicted. Loads are serialized so two jobs needing different heavy models on a small Mac queue up.
public actor ModelResidencyTracker {
    private struct Entry {
        var isHeavy: Bool
        var bytes: Int64
        var lastUsed: UInt64
        var inUse: Int
    }

    /// Maximum number of heavy models resident at once.
    public private(set) var maxHeavyResident: Int
    private var entries: [ModelID: Entry] = [:]
    private var tick: UInt64 = 0
    private var unloadHandler: (@Sendable (ModelID) async -> Void)?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var monitor: Task<Void, Never>?
    private var removals: Set<ModelID> = []

    /// One heavy model on 8 and 16 GB Macs, two on 32 GB and above (ADR-007: one heavy model resident by default).
    public static func defaultMaxHeavy(for tier: HardwareTier) -> Int { tier == .tier32Plus ? 2 : 1 }

    public init(maxHeavyResident: Int, unloadHandler: (@Sendable (ModelID) async -> Void)? = nil) {
        self.maxHeavyResident = max(1, maxHeavyResident)
        self.unloadHandler = unloadHandler
    }

    public init(tier: HardwareTier, unloadHandler: (@Sendable (ModelID) async -> Void)? = nil) {
        self.init(maxHeavyResident: Self.defaultMaxHeavy(for: tier), unloadHandler: unloadHandler)
    }

    /// Sets the callback that actually unloads a model from its engine.
    public func setUnloadHandler(_ handler: @escaping @Sendable (ModelID) async -> Void) { unloadHandler = handler }

    /// Resident models, least recently used first.
    public func resident() -> [ModelID] {
        entries.sorted { $0.value.lastUsed < $1.value.lastUsed }.map(\.key)
    }

    public func isResident(_ id: ModelID) -> Bool { entries[id] != nil }

    /// Sum of the declared sizes of resident models.
    public func residentBytes() -> Int64 { entries.values.reduce(0) { $0 + $1.bytes } }

    /// Registers `id` as about to be loaded, evicting LRU idle heavy models until there is room.
    /// - Returns: ids that were unloaded to make room.
    /// - Throws: ``AppError/outOfMemory`` if room is needed but every resident model is in use.
    @discardableResult
    public func prepareToLoad(_ id: ModelID, isHeavy: Bool, bytes: Int64 = 0) async throws -> [ModelID] {
        await acquireLoadLock()
        defer { releaseLoadLock() }
        guard !removals.contains(id) else { throw AppError.other("This model is being removed. Try again when removal finishes.") }
        if entries[id] != nil {
            touch(id)
            return []
        }
        var evicted: [ModelID] = []
        while isHeavy, entries.values.filter(\.isHeavy).count >= maxHeavyResident {
            guard let victim = lruIdle(heavyOnly: true) else { throw AppError.outOfMemory }
            await unload(victim)
            evicted.append(victim)
        }
        tick += 1
        entries[id] = Entry(isHeavy: isHeavy, bytes: bytes, lastUsed: tick, inUse: 0)
        return evicted
    }

    /// Marks `id` most recently used.
    public func touch(_ id: ModelID) {
        guard entries[id] != nil else { return }
        tick += 1
        entries[id]?.lastUsed = tick
    }

    /// Marks the model busy (e.g. a transcription running); busy models are never evicted.
    public func beginUse(_ id: ModelID) throws {
        guard !removals.contains(id), entries[id] != nil else { throw AppError.modelNotInstalled(id) }
        touch(id)
        entries[id]?.inUse += 1
    }

    /// Reserve deletion across the actual engine unload and filesystem mutation.
    /// A new load cannot enter during the suspension in the unload callback.
    public func beginRemoval(_ id: ModelID) async throws {
        await acquireLoadLock()
        defer { releaseLoadLock() }
        guard !removals.contains(id) else { throw AppError.other("This model is already being removed.") }
        guard (entries[id]?.inUse ?? 0) == 0 else { throw AppError.other("Stop using this model before removing it.") }
        removals.insert(id)
        if entries[id] != nil { await unload(id) }
    }

    public func endRemoval(_ id: ModelID) { removals.remove(id) }

    public func endUse(_ id: ModelID) {
        guard var entry = entries[id] else { return }
        entry.inUse = max(0, entry.inUse - 1)
        tick += 1
        entry.lastUsed = tick
        entries[id] = entry
    }

    /// Records that an engine unloaded `id` on its own (or that the model was deleted).
    public func markUnloaded(_ id: ModelID) { entries[id] = nil }

    /// Unloads `id` if resident and idle, via the unload handler.
    /// - Returns: `true` if the model was unloaded.
    @discardableResult
    public func evict(_ id: ModelID) async -> Bool {
        guard let entry = entries[id], entry.inUse == 0 else { return false }
        await unload(id)
        return true
    }

    /// Unloads the least-recently-used idle model (ENG-AC-10).
    /// - Returns: the unloaded id, or `nil` when nothing was idle.
    @discardableResult
    public func handleMemoryPressure() async -> ModelID? {
        guard let victim = lruIdle(heavyOnly: false) else { return nil }
        await unload(victim)
        return victim
    }

    /// Starts reacting to the provider's memory-pressure events. Event driven; no timers.
    public func startMonitoring(_ provider: any HardwareTierProviding) {
        monitor?.cancel()
        let stream = provider.memoryPressure()
        monitor = Task { [weak self] in
            for await _ in stream {
                await self?.handleMemoryPressure()
            }
        }
    }

    public func stopMonitoring() {
        monitor?.cancel()
        monitor = nil
    }

    private func lruIdle(heavyOnly: Bool) -> ModelID? {
        entries.filter { $0.value.inUse == 0 && (!heavyOnly || $0.value.isHeavy) }
            .min { $0.value.lastUsed < $1.value.lastUsed }?.key
    }

    private func unload(_ id: ModelID) async {
        entries[id] = nil
        await unloadHandler?(id)
    }

    private func acquireLoadLock() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func releaseLoadLock() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
