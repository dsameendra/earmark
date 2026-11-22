import AppCore
import AppCoreTesting
import FeatureSettings
import FeatureSupport
import Foundation
import Testing

/// LIB-AC-13: storage breakdown, cache clearing and moving the library with a confirm step.
@Suite @MainActor struct StorageTests {
    private struct Sandbox {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("storage-\(UUID().uuidString)", isDirectory: true)
        var base: URL { root.appendingPathComponent("base", isDirectory: true) }
        var target: URL { root.appendingPathComponent("target", isDirectory: true) }
        var caches: URL { root.appendingPathComponent("caches", isDirectory: true) }

        init() throws {
            for folder in [base, target, caches] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        }

        func write(_ bytes: Int, to relative: String, under folder: URL) throws {
            let url = folder.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 7, count: bytes).write(to: url)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    private func model(
        _ box: Sandbox, store: InMemorySettingsStore = InMemorySettingsStore(), used: Int64 = 5_000,
        activated: ActivatedBases = ActivatedBases(), clear: @escaping @Sendable () async -> Int64 = { 0 }
    ) -> StorageSettingsModel {
        StorageSettingsModel(
            store: store, models: MockModelManager(), transcripts: nil, clearCaches: clear, defaultBase: box.base,
            cachesDirectory: box.caches, databaseFiles: [box.base.appendingPathComponent("earmark.sqlite")],
            activate: { activated.record($0) })
    }

    final class ActivatedBases: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [URL] = []
        func record(_ url: URL) { lock.withLock { items.append(url) } }
        var all: [URL] { lock.withLock { items } }
    }

    @Test func breakdownReportsLibraryRecordingsCachesAndModels() async throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        try box.write(40_000, to: "Library/Media/a/talk.m4a", under: box.base)
        try box.write(30_000, to: "Meetings/2026/mix.m4a", under: box.base)
        try box.write(20_000, to: "thumb.bin", under: box.caches)
        try box.write(10_000, to: "earmark.sqlite", under: box.base)
        let storage = model(box)
        await storage.load()
        let usage = try #require(storage.breakdown)
        // Allocated sizes are block-rounded, so check ordering and lower bounds rather than exact byte counts.
        #expect(usage.library >= 50_000 && usage.recordings >= 30_000 && usage.caches >= 20_000)
        #expect(usage.library > usage.recordings && usage.recordings > usage.caches)
        #expect(usage.total == usage.library + usage.models + usage.recordings + usage.caches)
    }

    @Test func clearingCachesRefreshesTheBreakdown() async throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        try box.write(20_000, to: "thumb.bin", under: box.caches)
        let caches = box.caches
        let storage = model(
            box,
            clear: {
                try? FileManager.default.removeItem(at: caches.appendingPathComponent("thumb.bin"))
                return 20_000
            })
        await storage.load()
        #expect((storage.breakdown?.caches ?? 0) >= 20_000)
        await storage.clearCaches()
        #expect(storage.lastFreedBytes == 20_000)
        #expect(storage.breakdown?.caches == 0)
    }

    @Test func proposingAFolderChangesNothingUntilConfirmed() async throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        try box.write(1_000, to: "Library/Media/a/talk.m4a", under: box.base)
        let storage = model(box)
        await storage.load()
        await storage.proposeLocation(box.target)
        let pending = try #require(storage.pendingMove)
        #expect(pending.plan.folders == ["Library"] && !pending.toDefault && pending.plan.bytes > 0)
        #expect(storage.libraryLocation.value.isEmpty)
        #expect(FileManager.default.fileExists(atPath: box.base.appendingPathComponent("Library/Media/a/talk.m4a").path))
        storage.cancelMove()
        #expect(storage.pendingMove == nil)
        #expect(!FileManager.default.fileExists(atPath: box.target.appendingPathComponent("Library").path))
    }

    @Test func confirmedMoveRelocatesLibraryAndRecordingsAndSwitchesTheSetting() async throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        try box.write(1_000, to: "Library/Media/a/talk.m4a", under: box.base)
        try box.write(2_000, to: "Meetings/m1/mix.m4a", under: box.base)
        let store = InMemorySettingsStore()
        let activated = ActivatedBases()
        let storage = model(box, store: store, activated: activated)
        await storage.load()
        await storage.proposeLocation(box.target)
        await storage.confirmMove()
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: box.target.appendingPathComponent("Library/Media/a/talk.m4a").path))
        #expect(fm.fileExists(atPath: box.target.appendingPathComponent("Meetings/m1/mix.m4a").path))
        #expect(!fm.fileExists(atPath: box.base.appendingPathComponent("Library").path))
        #expect(await store.value(for: SettingsKey.libraryLocation, as: String.self) == storage.libraryLocation.value)
        #expect(storage.libraryLocation.value.hasSuffix("/target") && storage.pendingMove == nil && storage.movedNotice != nil)
        #expect(activated.all.count == 1)
        #expect(storage.currentBase.lastPathComponent == "target")

        // And back to the default location, which clears the setting.
        await storage.proposeDefaultLocation()
        #expect(storage.pendingMove?.toDefault == true)
        await storage.confirmMove()
        #expect(storage.isDefaultLocation)
        #expect(fm.fileExists(atPath: box.base.appendingPathComponent("Library/Media/a/talk.m4a").path))
    }

    @Test func aSeparateMeetingsFolderIsNotMoved() async throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        try box.write(1_000, to: "Library/x.bin", under: box.base)
        try box.write(1_000, to: "Meetings/m/mix.m4a", under: box.base)
        let store = InMemorySettingsStore()
        await store.set(box.root.appendingPathComponent("elsewhere").path, for: SettingsKey.meetingStorageLocation)
        let storage = model(box, store: store)
        await storage.load()
        await storage.proposeLocation(box.target)
        #expect(storage.pendingMove?.plan.folders == ["Library"])
    }

    @Test func invalidDestinationsAreRejectedWithAReason() async throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        try box.write(1_000, to: "Library/x.bin", under: box.base)
        let storage = model(box)
        await storage.load()
        await storage.proposeLocation(box.base)
        #expect(storage.pendingMove == nil && storage.errorMessage == StorageRelocation.Failure.sameFolder.errorDescription)
        await storage.proposeLocation(box.base.appendingPathComponent("Library"))
        #expect(storage.errorMessage == StorageRelocation.Failure.insideCurrent.errorDescription)
        await storage.proposeLocation(box.root.appendingPathComponent("missing"))
        #expect(storage.errorMessage == StorageRelocation.Failure.notAFolder.errorDescription)
        try box.write(1, to: "Library/occupied.bin", under: box.target)
        await storage.proposeLocation(box.target)
        #expect(storage.errorMessage == StorageRelocation.Failure.conflict("Library").errorDescription)
        #expect(storage.pendingMove == nil && storage.libraryLocation.value.isEmpty)
    }

    @Test func aFailedMoveRestoresWhatWasAlreadyMoved() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        try box.write(1_000, to: "Library/a.bin", under: box.base)
        try box.write(1_000, to: "Meetings/b.bin", under: box.base)
        let plan = try StorageRelocation.plan(from: box.base, to: box.target)
        // Remove the second source after planning so its move fails and the first must be rolled back.
        try FileManager.default.removeItem(at: box.base.appendingPathComponent("Meetings"))
        #expect(throws: (any Error).self) { try StorageRelocation.move(plan) }
        #expect(FileManager.default.fileExists(atPath: box.base.appendingPathComponent("Library/a.bin").path))
        #expect(!FileManager.default.fileExists(atPath: box.target.appendingPathComponent("Library").path))
    }

    @Test func libraryLocationResolvesBaseAndRoots() {
        #expect(LibraryLocation.base(custom: nil) == LibraryLocation.defaultBase)
        #expect(LibraryLocation.base(custom: "") == LibraryLocation.defaultBase)
        let custom = LibraryLocation.base(custom: "/Volumes/Archive/Earmark")
        #expect(LibraryLocation.libraryRoot(base: custom).path == "/Volumes/Archive/Earmark/Library")
        #expect(LibraryLocation.meetingsRoot(base: custom).path == "/Volumes/Archive/Earmark/Meetings")
    }
}
