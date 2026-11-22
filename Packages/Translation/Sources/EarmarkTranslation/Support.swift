import AppCore
import CryptoKit
import Foundation

/// Engine ids (match `BuiltInCatalog` `engine` fields).
public enum TranslationEngineIDs {
    public static let apple: EngineID = "apple.translation"
    public static let nllb: EngineID = "nllb"
    public static let nllbModel: ModelID = "nllb/200-distilled-600M"
    public static let appleModel: ModelID = "apple/translation"
}

/// Why a request produced nothing (TRN-AC-06) or could not be served.
public enum TranslationFailure: Error, Sendable, Equatable, CustomStringConvertible {
    case sameLanguage(LanguageCode)
    case unknownSource
    case noEngine(LanguagePair)
    public var description: String {
        switch self {
        case .sameLanguage(let l): "Source and target language are both \(l.rawValue); nothing to translate."
        case .unknownSource: "The source language is unknown; choose it before translating."
        case .noEngine(let p): "No translation engine supports \(p.source.rawValue) to \(p.target.rawValue)."
        }
    }
}

/// An optional refinement so the router can ask "can you do this pair?" without enumerating every pair.
public protocol PairSupportChecking: TranslationEngine {
    func supports(_ pair: LanguagePair) async -> Bool
}

func supports(_ engine: any TranslationEngine, _ pair: LanguagePair) async -> Bool {
    if let checker = engine as? any PairSupportChecking { return await checker.supports(pair) }
    return await engine.supportedPairs().contains(pair)
}

// MARK: - Batching

/// Splits items into bounded batches, drops empty text, streams one `TranslatedSegment` per item as each batch completes and
/// stops promptly on cancellation (TRN-AC-16: bounded memory, cancel within 1 s).
func streamInBatches(
    items: [TranslationItem], maxItems: Int, maxCharacters: Int, engine: EngineID, lowConfidence: Bool,
    translateBatch: @escaping @Sendable ([String]) async throws -> [String]
) -> AsyncThrowingStream<TranslatedSegment, any Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                var batch: [TranslationItem] = []
                var chars = 0
                func flush() async throws {
                    guard !batch.isEmpty else { return }
                    try Task.checkCancellation()
                    let outputs = try await translateBatch(batch.map(\.text))
                    try Task.checkCancellation()
                    guard outputs.count == batch.count else {
                        throw AppError.engineFailure(engine, reason: "Engine returned \(outputs.count) results for \(batch.count) inputs.")
                    }
                    for (item, out) in zip(batch, outputs) {
                        continuation.yield(TranslatedSegment(segmentID: item.segmentID, text: out, engine: engine, isLowConfidence: lowConfidence))
                    }
                    batch.removeAll(keepingCapacity: true)
                    chars = 0
                }
                for item in items where !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if !batch.isEmpty, batch.count >= maxItems || chars + item.text.count > maxCharacters { try await flush() }
                    batch.append(item)
                    chars += item.text.count
                }
                try await flush()
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: AppError.cancelled)
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

// MARK: - Cache

/// Cache key: SHA-256 of the trimmed segment text, the language pair and the engine (T26 caching).
public struct TranslationCacheKey: Hashable, Sendable {
    public let textHash: String
    public let pair: LanguagePair
    public let engine: EngineID
    public init(text: String, pair: LanguagePair, engine: EngineID) {
        self.textHash = Self.hash(text)
        self.pair = pair
        self.engine = engine
    }
    public static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public actor TranslationCache {
    public struct Value: Sendable, Equatable {
        public var text: String
        public var isLowConfidence: Bool
    }
    private var storage: [TranslationCacheKey: Value] = [:]
    private var order: [TranslationCacheKey] = []
    private let capacity: Int
    public private(set) var hits = 0
    public private(set) var misses = 0
    public init(capacity: Int = 5_000) { self.capacity = max(1, capacity) }

    public func value(for key: TranslationCacheKey) -> Value? {
        if let v = storage[key] {
            hits += 1
            return v
        }
        misses += 1
        return nil
    }
    public func store(_ value: Value, for key: TranslationCacheKey) {
        if storage[key] == nil { order.append(key) }
        storage[key] = value
        while order.count > capacity { storage.removeValue(forKey: order.removeFirst()) }
    }
    public var count: Int { storage.count }
    public func removeAll() {
        storage.removeAll()
        order.removeAll()
    }
}

/// Decorator that serves repeats from the cache and forwards only the misses.
public struct CachingTranslationEngine: TranslationEngine, PairSupportChecking {
    public let inner: any TranslationEngine
    public let cache: TranslationCache
    public init(_ inner: any TranslationEngine, cache: TranslationCache) {
        self.inner = inner
        self.cache = cache
    }
    public var id: EngineID { inner.id }
    public func supportedPairs() async -> Set<LanguagePair> { await inner.supportedPairs() }
    public func supports(_ pair: LanguagePair) async -> Bool { await EarmarkTranslation.supports(inner, pair) }

    public func translate(items: [TranslationItem], from: LanguageCode, to: LanguageCode) -> AsyncThrowingStream<TranslatedSegment, any Error> {
        let inner = inner
        let cache = cache
        let pair = LanguagePair(source: from, target: to)
        let engineID = inner.id
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var misses: [TranslationItem] = []
                    for item in items {
                        let key = TranslationCacheKey(text: item.text, pair: pair, engine: engineID)
                        if let hit = await cache.value(for: key) {
                            continuation.yield(
                                TranslatedSegment(segmentID: item.segmentID, text: hit.text, engine: engineID, isLowConfidence: hit.isLowConfidence))
                        } else {
                            misses.append(item)
                        }
                    }
                    if !misses.isEmpty {
                        let byID = Dictionary(misses.map { ($0.segmentID, $0.text) }, uniquingKeysWith: { a, _ in a })
                        for try await out in inner.translate(items: misses, from: from, to: to) {
                            if let source = byID[out.segmentID] {
                                await cache.store(
                                    .init(text: out.text, isLowConfidence: out.isLowConfidence),
                                    for: TranslationCacheKey(text: source, pair: pair, engine: engineID))
                            }
                            continuation.yield(out)
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
