import AppCore
import AppCoreTesting
import Foundation

@testable import EarmarkTranslation

/// Fake Apple backend: "translation" is `[to] text`.
actor FakeAppleBackend: AppleTranslationBackend {
    var languages: Set<LanguageCode>
    var installed: Set<LanguagePair>
    var unsupported: Set<LanguagePair>
    var failure: (any Error)?
    private(set) var calls = 0
    private(set) var maxBatch = 0
    var delay: Duration = .zero
    var failAfter: Int?

    init(
        languages: Set<LanguageCode> = ["en", "de", "fr", "ja", "ar", "hi"], installed: Set<LanguagePair> = [],
        unsupported: Set<LanguagePair> = [], failure: (any Error)? = nil
    ) {
        self.languages = languages
        self.installed = installed
        self.unsupported = unsupported
        self.failure = failure
    }
    func setDelay(_ d: Duration) { delay = d }
    func supportedLanguages() async -> Set<LanguageCode> { languages }
    func status(from: LanguageCode, to: LanguageCode) async -> AppleLanguageStatus {
        let pair = LanguagePair(source: from, target: to)
        if unsupported.contains(pair) || !languages.contains(from) || !languages.contains(to) { return .unsupported }
        return installed.contains(pair) ? .installed : .supported
    }
    func translate(_ texts: [String], from: LanguageCode, to: LanguageCode) async throws -> [String] {
        if let failAfter, calls >= failAfter { throw AppError.engineFailure("apple.translation", reason: "flaky") }
        calls += 1
        maxBatch = max(maxBatch, texts.count)
        if delay > .zero { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        return texts.map { "[\(to.rawValue)] \($0)" }
    }
}

/// Fake NLLB runtime recording the codes it was asked for; fails after `failAfterCalls` calls when set.
actor FakeNLLBRuntime: NLLBRuntime {
    private(set) var loadedFolder: URL?
    private(set) var requests: [(source: String, target: String, count: Int)] = []
    private(set) var unloads = 0
    var failAfterCalls: Int?
    var delay: Duration = .zero
    func setFailAfter(_ n: Int?) { failAfterCalls = n }
    func setDelay(_ d: Duration) { delay = d }
    func load(modelFolder: URL) async throws { loadedFolder = modelFolder }
    func unload() async { unloads += 1 }
    func translate(_ texts: [String], source: String, target: String) async throws -> [String] {
        if let failAfterCalls, requests.count >= failAfterCalls { throw AppError.engineFailure("nllb", reason: "boom") }
        requests.append((source, target, texts.count))
        if delay > .zero { try await Task.sleep(for: delay) }
        return texts.map { "<\(target)> \($0)" }
    }
}

/// Engine fake that records invocations and can fail.
final class FakeEngine: TranslationEngine, PairSupportChecking, @unchecked Sendable {
    let id: EngineID
    let pairs: Set<LanguagePair>
    let lowConfidence: Bool
    private let lock = NSLock()
    private var _calls: [[String]] = []
    var failure: (any Error)?
    var calls: [[String]] { lock.withLock { _calls } }
    init(id: EngineID, pairs: Set<LanguagePair>, lowConfidence: Bool = false, failure: (any Error)? = nil) {
        self.id = id
        self.pairs = pairs
        self.lowConfidence = lowConfidence
        self.failure = failure
    }
    func supportedPairs() async -> Set<LanguagePair> { pairs }
    func supports(_ pair: LanguagePair) async -> Bool { pairs.contains(pair) }
    func translate(items: [TranslationItem], from: LanguageCode, to: LanguageCode) -> AsyncThrowingStream<TranslatedSegment, any Error> {
        lock.withLock { _calls.append(items.map(\.text)) }
        let (id, low, failure) = (id, lowConfidence, failure)
        return AsyncThrowingStream { c in
            if let failure {
                c.finish(throwing: failure)
                return
            }
            for item in items {
                c.yield(TranslatedSegment(segmentID: item.segmentID, text: "\(id.rawValue):\(to.rawValue):\(item.text)", engine: id, isLowConfidence: low))
            }
            c.finish()
        }
    }
}

func pair(_ a: LanguageCode, _ b: LanguageCode) -> LanguagePair { LanguagePair(source: a, target: b) }

func allPairs(_ langs: [LanguageCode]) -> Set<LanguagePair> {
    var out = Set<LanguagePair>()
    for a in langs { for b in langs where a != b { out.insert(LanguagePair(source: a, target: b)) } }
    return out
}

func collect(_ stream: AsyncThrowingStream<TranslatedSegment, any Error>) async throws -> [TranslatedSegment] {
    var out: [TranslatedSegment] = []
    for try await s in stream { out.append(s) }
    return out
}

func items(_ texts: [String]) -> [TranslationItem] { texts.map { TranslationItem(segmentID: SegmentID(), text: $0) } }

func seg(_ text: String, ignored: Bool = false, translations: [SegmentTranslation] = []) -> Segment {
    Segment(start: 0, end: 1, text: text, isIgnored: ignored, translations: translations)
}
