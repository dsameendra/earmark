import Foundation
import Testing
@testable import EarmarkTranslation

@Suite("Native translation resource ownership")
struct CTranslate2RuntimePoolTests {
    @Test func evictionReacquiresTheCorrectFamilyAndStaleReleaseDoesNotUnloadIt() async throws {
        let tracker = PoolTracker()
        let pool = CTranslate2RuntimePool(makeRuntime: { PoolRuntime(profile: $0, tracker: tracker) })
        let nllb = pool.runtime(profile: .nllb)
        let madlad = pool.runtime(profile: .madlad)
        try await nllb.load(modelFolder: URL(fileURLWithPath: "/nllb"))
        try await madlad.load(modelFolder: URL(fileURLWithPath: "/madlad"))
        #expect(try await nllb.translate(["a"], source: "en", target: "de") == ["nllb:nllb:a"])
        // MADLAD was evicted above; releasing that old handle cannot unload NLLB.
        await madlad.unload()
        #expect(try await nllb.translate(["b"], source: "en", target: "de") == ["nllb:nllb:b"])
        #expect(await tracker.peak == 1)
        #expect(await tracker.count == 1)
        await nllb.unload()
        #expect(await tracker.count == 0)
    }

    @Test func simultaneousFamiliesSerializeLoadingAndInference() async throws {
        let tracker = PoolTracker()
        let pool = CTranslate2RuntimePool(makeRuntime: { PoolRuntime(profile: $0, tracker: tracker) })
        let nllb = pool.runtime(profile: .nllb), madlad = pool.runtime(profile: .madlad)
        try await nllb.load(modelFolder: URL(fileURLWithPath: "/first"))
        try await madlad.load(modelFolder: URL(fileURLWithPath: "/second"))
        async let first = nllb.translate(["one"], source: "en", target: "de")
        async let second = madlad.translate(["two"], source: "en", target: "fr")
        let (a, b) = try await (first, second)
        #expect(a == ["nllb:first:one"])
        #expect(b == ["madlad:second:two"])
        #expect(await tracker.peak == 1)
        await nllb.unload()
        await madlad.unload()
        #expect(await tracker.count == 0)
    }
}

private actor PoolTracker {
    private(set) var count = 0
    private(set) var peak = 0
    func load() { count += 1; peak = max(peak, count) }
    func unload() { count -= 1 }
}

private actor PoolRuntime: NLLBRuntime {
    let profile: CTranslate2ModelProfile
    let tracker: PoolTracker
    private var folder: URL?
    init(profile: CTranslate2ModelProfile, tracker: PoolTracker) { self.profile = profile; self.tracker = tracker }
    func load(modelFolder: URL) async {
        folder = modelFolder
        await tracker.load()
    }
    func unload() async {
        guard folder != nil else { return }
        folder = nil
        await tracker.unload()
    }
    func translate(_ texts: [String], source: String, target: String) async throws -> [String] {
        try await Task.sleep(for: .milliseconds(30))
        return texts.map { profile.rawValue + ":" + (folder?.lastPathComponent ?? "unloaded") + ":" + $0 }
    }
}
