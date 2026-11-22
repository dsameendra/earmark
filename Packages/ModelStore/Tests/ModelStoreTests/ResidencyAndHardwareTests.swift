import AppCore
import Foundation
import Testing

@testable import ModelStore

private let gib: UInt64 = 1_073_741_824

@Suite("Residency")
struct ResidencyTests {
    @Test("LRU heavy model is evicted when the limit is reached")
    func lruEviction() async throws {
        let log = UnloadLog()
        let tracker = ModelResidencyTracker(maxHeavyResident: 2) { await log.record($0) }
        try await tracker.prepareToLoad("a", isHeavy: true)
        try await tracker.prepareToLoad("b", isHeavy: true)
        await tracker.touch("a")  // b is now least recently used
        let evicted = try await tracker.prepareToLoad("c", isHeavy: true)
        #expect(evicted == ["b"])
        #expect(await log.ids == ["b"])
        #expect(await tracker.resident() == ["a", "c"])
    }

    @Test("light models do not count against the heavy limit")
    func lightModels() async throws {
        let tracker = ModelResidencyTracker(maxHeavyResident: 1)
        try await tracker.prepareToLoad("heavy", isHeavy: true)
        let evicted = try await tracker.prepareToLoad("vad", isHeavy: false)
        #expect(evicted.isEmpty)
        #expect(await tracker.resident().count == 2)
    }

    @Test("tier8 keeps at most one heavy model resident")
    func tier8() async throws {
        #expect(ModelResidencyTracker.defaultMaxHeavy(for: .tier8) == 1)
        #expect(ModelResidencyTracker.defaultMaxHeavy(for: .tier32Plus) == 2)
        let tracker = ModelResidencyTracker(tier: .tier8)
        try await tracker.prepareToLoad("whisper", isHeavy: true)
        try await tracker.prepareToLoad("qwen", isHeavy: true)
        #expect(await tracker.resident() == ["qwen"])
    }

    @Test("busy models are never evicted; all busy throws outOfMemory")
    func busyModels() async throws {
        let tracker = ModelResidencyTracker(maxHeavyResident: 1)
        try await tracker.prepareToLoad("a", isHeavy: true)
        await tracker.beginUse("a")
        await #expect(throws: AppError.outOfMemory) { try await tracker.prepareToLoad("b", isHeavy: true) }
        #expect(await tracker.handleMemoryPressure() == nil)
        await tracker.endUse("a")
        let evicted = try await tracker.prepareToLoad("b", isHeavy: true)
        #expect(evicted == ["a"])
    }

    @Test("memory pressure unloads the least recently used idle model")
    func memoryPressure() async throws {
        let log = UnloadLog()
        let tracker = ModelResidencyTracker(maxHeavyResident: 3) { await log.record($0) }
        try await tracker.prepareToLoad("a", isHeavy: true)
        try await tracker.prepareToLoad("b", isHeavy: true)
        await tracker.beginUse("a")
        await tracker.touch("b")
        #expect(await tracker.handleMemoryPressure() == "b", "a is busy so idle b goes")
        #expect(await log.ids == ["b"])
    }

    @Test("monitoring reacts to provider memory-pressure events")
    func monitoring() async throws {
        struct Provider: HardwareTierProviding {
            let events: AsyncStream<Void>
            var profile: HardwareProfile { HardwareProfile(chip: "T", memoryBytes: 16 * gib, performanceCores: 4, tier: .tier16) }
            func memoryPressure() -> AsyncStream<Void> { events }
            func thermalPressure() -> AsyncStream<ThermalPressure> { AsyncStream { $0.finish() } }
            func isOnBattery() -> Bool { false }
        }
        let (events, continuation) = AsyncStream<Void>.makeStream()
        let log = UnloadLog()
        let tracker = ModelResidencyTracker(maxHeavyResident: 2) { await log.record($0) }
        try await tracker.prepareToLoad("a", isHeavy: true)
        await tracker.startMonitoring(Provider(events: events))
        continuation.yield()
        for _ in 0..<200 where await log.ids.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await log.ids == ["a"])
        await tracker.stopMonitoring()
    }

    @Test("loads are serialized")
    func serialized() async throws {
        let log = UnloadLog()
        let tracker = ModelResidencyTracker(maxHeavyResident: 1) { id in
            try? await Task.sleep(for: .milliseconds(20))
            await log.record(id)
        }
        try await tracker.prepareToLoad("a", isHeavy: true)
        async let first = tracker.prepareToLoad("b", isHeavy: true)
        async let second = tracker.prepareToLoad("c", isHeavy: true)
        _ = try await (first, second)
        #expect(await tracker.resident().count == 1)
        #expect(await log.ids.count == 2)
    }
}

@Suite("Hardware tiers")
struct HardwareTierTests {
    @Test(
        "memory maps to tiers per ADR-007",
        arguments: [
            (8, HardwareTier.tier8), (10, .tier8), (16, .tier16), (18, .tier16), (24, .tier16), (32, .tier32Plus), (64, .tier32Plus),
        ])
    func tiers(gb: Int, expected: HardwareTier) {
        let provider = SystemHardwareTierProvider(memoryBytes: UInt64(gb) * gib, chip: "Test", performanceCores: 6)
        #expect(provider.profile.tier == expected)
        #expect(provider.profile.memoryBytes == UInt64(gb) * gib)
        #expect(provider.profile.chip == "Test")
        #expect(provider.profile.performanceCores == 6)
    }

    @Test("real machine reports a plausible profile")
    func realMachine() {
        let profile = SystemHardwareTierProvider().profile
        #expect(profile.memoryBytes == ProcessInfo.processInfo.physicalMemory)
        #expect(profile.performanceCores > 0)
        #expect(!profile.chip.isEmpty)
    }

    @Test("thermal state mapping")
    func thermal() {
        #expect(SystemHardwareTierProvider.pressure(for: .nominal) == .nominal)
        #expect(SystemHardwareTierProvider.pressure(for: .fair) == .fair)
        #expect(SystemHardwareTierProvider.pressure(for: .serious) == .serious)
        #expect(SystemHardwareTierProvider.pressure(for: .critical) == .critical)
    }

    @Test("streams can be created and cancelled")
    func streams() async {
        let provider = SystemHardwareTierProvider()
        let task = Task { for await _ in provider.memoryPressure() {} }
        let thermal = Task { for await _ in provider.thermalPressure() {} }
        _ = provider.isOnBattery()
        task.cancel()
        thermal.cancel()
        await task.value
        await thermal.value
    }
}
