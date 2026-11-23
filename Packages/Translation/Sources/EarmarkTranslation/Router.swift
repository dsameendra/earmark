import AppCore
import Foundation

/// Routing table (specs/research/translation.md section 4, rows 1-7):
/// Apple Translation first; NLLB for Sinhala and for pairs Apple lacks; two-hop pivot through English otherwise.
/// Sinhala never goes to Apple (TRN-AC-02). Pure for a given set of engine capabilities (TRN-AC-01).
public struct DefaultTranslationRouter: TranslationRouter {
    private let apple: any TranslationEngine
    private let nllb: (any TranslationEngine)?
    private let cache: TranslationCache?
    private let additional: [any TranslationEngine]
    private let selectedEngine: @Sendable () async -> EngineID?
    private let isAllowed: @Sendable (EngineID) async -> Bool

    /// Explicit engine choice never silently falls back. Policy is evaluated at execution, including cache hits.
    public init(
        apple: any TranslationEngine, nllb: (any TranslationEngine)?, cache: TranslationCache? = TranslationCache(),
        additional: [any TranslationEngine] = [],
        selectedEngine: @escaping @Sendable () async -> EngineID? = { nil },
        isAllowed: @escaping @Sendable (EngineID) async -> Bool = { _ in true }
    ) {
        self.apple = apple
        self.nllb = nllb
        self.cache = cache
        self.additional = additional
        self.selectedEngine = selectedEngine
        self.isAllowed = isAllowed
    }

    public func engine(for pair: LanguagePair) async throws -> any TranslationEngine {
        let source = pair.source.primary
        let target = pair.target.primary
        if source.rawValue.isEmpty || source.rawValue == "und" { throw TranslationFailure.unknownSource }
        guard source != target else { throw TranslationFailure.sameLanguage(source) }
        let normalized = LanguagePair(source: source, target: target)
        if let selected = await selectedEngine() {
            let candidates = [apple] + (nllb.map { [$0] } ?? []) + additional
            guard let engine = candidates.first(where: { $0.id == selected }),
                await isAllowed(selected), await supports(engine, normalized)
            else { throw TranslationFailure.noEngine(normalized) }
            return wrap(engine)
        }
        if let direct = await direct(normalized) { return wrap(direct) }
        if source != .english, target != .english,
            let first = await direct(LanguagePair(source: source, target: .english)),
            let second = await direct(LanguagePair(source: .english, target: target))
        {
            return PivotEngine(first: wrap(first), second: wrap(second), via: .english)
        }
        throw TranslationFailure.noEngine(normalized)
    }

    private func direct(_ pair: LanguagePair) async -> (any TranslationEngine)? {
        let involvesSinhala = pair.source == .sinhala || pair.target == .sinhala
        if !involvesSinhala, await isAllowed(apple.id), await supports(apple, pair) { return apple }
        if let nllb, await isAllowed(nllb.id), await supports(nllb, pair) { return nllb }
        for engine in additional where await isAllowed(engine.id) {
            if await supports(engine, pair) { return engine }
        }
        return nil
    }

    private func wrap(_ engine: any TranslationEngine) -> any TranslationEngine {
        guard let cache else { return engine }
        return CachingTranslationEngine(engine, cache: cache)
    }
}

/// Source -> English -> target in two hops (rows 5 and 6); errors compound, so the result is flagged low confidence when either
/// hop is. Per-segment streaming is kept on the second hop.
public struct PivotEngine: TranslationEngine, PairSupportChecking {
    public let first: any TranslationEngine
    public let second: any TranslationEngine
    public let via: LanguageCode
    public var id: EngineID { EngineID("pivot:\(first.id.rawValue)+\(second.id.rawValue)") }

    public init(first: any TranslationEngine, second: any TranslationEngine, via: LanguageCode) {
        self.first = first
        self.second = second
        self.via = via
    }
    public func supportedPairs() async -> Set<LanguagePair> { [] }
    public func supports(_ pair: LanguagePair) async -> Bool {
        let a = await EarmarkTranslation.supports(first, LanguagePair(source: pair.source, target: via))
        let b = await EarmarkTranslation.supports(second, LanguagePair(source: via, target: pair.target))
        return a && b
    }

    public func translate(items: [TranslationItem], from: LanguageCode, to: LanguageCode) -> AsyncThrowingStream<TranslatedSegment, any Error> {
        let (first, second, via, engineID) = (first, second, via, id)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var middle: [TranslationItem] = []
                    var weak = Set<SegmentID>()
                    for try await out in first.translate(items: items, from: from, to: via) {
                        middle.append(TranslationItem(segmentID: out.segmentID, text: out.text))
                        if out.isLowConfidence { weak.insert(out.segmentID) }
                    }
                    for try await out in second.translate(items: middle, from: via, to: to) {
                        continuation.yield(
                            TranslatedSegment(
                                segmentID: out.segmentID, text: out.text, engine: engineID,
                                isLowConfidence: out.isLowConfidence || weak.contains(out.segmentID)))
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
