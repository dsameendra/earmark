import AppCore
import Foundation

/// Original / Translated / Bilingual (TRN-AC-08). Raw values are stable so the choice can be persisted per transcript.
public enum TranslationViewMode: String, Codable, Sendable, CaseIterable, Hashable {
    case original, translated, bilingual
    public var title: String {
        switch self {
        case .original: "Original"
        case .translated: "Translated"
        case .bilingual: "Bilingual"
        }
    }
}

/// One row of a parallel track.
public struct TranslatedTrackEntry: Hashable, Sendable, Identifiable {
    public var id: SegmentID
    public var original: String
    public var translated: String?
    public var engine: EngineID?
    public var isLowConfidence: Bool
    /// The original was edited after this translation was made (TRN-AC-10).
    public var isStale: Bool
    /// Ignored or empty segments are never translated.
    public var isSkipped: Bool
    public var translationIsPresent: Bool { translated != nil }
}

/// What a view or overlay should draw for one segment in a given mode.
public struct TrackLine: Hashable, Sendable, Identifiable {
    public var id: SegmentID
    public var primary: String
    /// Second line for bilingual mode (the translation beneath the original); nil otherwise.
    public var secondary: String?
    public var isLowConfidence: Bool
    public var isStale: Bool
    /// True when the mode wants a translation but none exists yet.
    public var isMissingTranslation: Bool
}

/// The parallel translation track for one target language, usable by the Editor, the Live overlay and exports.
/// Original text is never modified by applying translations (TRN-AC-04).
public struct TranslatedTrack: Sendable, Hashable {
    public private(set) var language: LanguageCode
    public private(set) var entries: [TranslatedTrackEntry]

    public init(language: LanguageCode, segments: [Segment]) {
        self.language = language
        self.entries = segments.map { segment in
            let existing = segment.translations.first { $0.language.translationIdentity == language.translationIdentity }
            return TranslatedTrackEntry(
                id: segment.id, original: segment.text, translated: existing?.text, engine: existing?.engine,
                isLowConfidence: existing.map { Self.isLowConfidence(engine: $0.engine, target: language) } ?? false,
                isStale: false, isSkipped: segment.isIgnored || segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// Persisted translations do not carry a confidence flag; the weak direction is derived from engine and target.
    public static func isLowConfidence(engine: EngineID, target: LanguageCode) -> Bool {
        engine == TranslationEngineIDs.nllb && target.primary == .sinhala
            || engine.rawValue.hasPrefix("pivot:") && target.primary == .sinhala
    }

    public var untranslatedIDs: [SegmentID] { entries.filter { !$0.isSkipped && $0.translated == nil }.map(\.id) }
    public var staleIDs: [SegmentID] { entries.filter { $0.isStale }.map(\.id) }
    /// Segments to (re)translate by default: missing plus stale.
    public var pendingIDs: [SegmentID] { entries.filter { !$0.isSkipped && ($0.translated == nil || $0.isStale) }.map(\.id) }
    public var containsLowConfidence: Bool { entries.contains { $0.isLowConfidence && $0.translated != nil } }
    public var fractionTranslated: Double {
        let eligible = entries.filter { !$0.isSkipped }
        guard !eligible.isEmpty else { return 1 }
        return Double(eligible.filter { $0.translated != nil }.count) / Double(eligible.count)
    }

    public func entry(_ id: SegmentID) -> TranslatedTrackEntry? { entries.first { $0.id == id } }

    /// Applies a streamed result and clears staleness. Unknown ids are ignored.
    public mutating func apply(_ result: TranslatedSegment) {
        guard let i = entries.firstIndex(where: { $0.id == result.segmentID }) else { return }
        entries[i].translated = result.text
        entries[i].engine = result.engine
        entries[i].isLowConfidence = result.isLowConfidence
        entries[i].isStale = false
    }

    /// The original text changed: keep the old translation but mark it stale (TRN-AC-10).
    public mutating func updateOriginal(_ id: SegmentID, text: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }), entries[i].original != text else { return }
        entries[i].original = text
        entries[i].isSkipped = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if entries[i].translated != nil { entries[i].isStale = true }
    }

    public mutating func setIgnored(_ id: SegmentID, _ ignored: Bool) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].isSkipped = ignored || entries[i].original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func lines(mode: TranslationViewMode) -> [TrackLine] {
        entries.map { e in
            switch mode {
            case .original:
                return TrackLine(
                    id: e.id, primary: e.original, secondary: nil, isLowConfidence: false, isStale: false, isMissingTranslation: false)
            case .translated:
                return TrackLine(
                    id: e.id, primary: e.translated ?? e.original, secondary: nil, isLowConfidence: e.isLowConfidence && e.translated != nil,
                    isStale: e.isStale, isMissingTranslation: e.translated == nil && !e.isSkipped)
            case .bilingual:
                return TrackLine(
                    id: e.id, primary: e.original, secondary: e.translated, isLowConfidence: e.isLowConfidence && e.translated != nil,
                    isStale: e.isStale, isMissingTranslation: e.translated == nil && !e.isSkipped)
            }
        }
    }

    /// Persistable form of one entry (TRN-AC-04, TRN-AC-05: callers can persist per segment as results stream in).
    public func segmentTranslation(for id: SegmentID) -> SegmentTranslation? {
        guard let e = entry(id), let text = e.translated, let engine = e.engine else { return nil }
        return SegmentTranslation(language: language, text: text, engine: engine)
    }

    /// Returns `segments` with this track's translations stored as parallel `SegmentTranslation`s; original text is untouched.
    public func applied(to segments: [Segment]) -> [Segment] {
        segments.map { segment in
            guard let translation = segmentTranslation(for: segment.id) else { return segment }
            var copy = segment
            copy.translations.removeAll { $0.language.translationIdentity == language.translationIdentity }
            copy.translations.append(translation)
            return copy
        }
    }
}

// MARK: - Job-level coordinator

public enum TranslationSkipReason: Sendable, Equatable { case sameLanguage, unknownSource }

public enum TranslationEvent: Sendable, Equatable {
    /// Nothing will be translated; show the message (TRN-AC-06).
    case skipped(TranslationSkipReason, message: String)
    case started(total: Int)
    case segment(TranslatedSegment)
    case progress(done: Int, total: Int)
    case finished(translated: Int)
}

/// Runs a translation pass over segments: skips ignored/empty ones, streams per-segment results (so partial results can be
/// persisted, TRN-AC-05) and ends with a retryable error on engine failure while already-delivered results stay valid (TRN-AC-13).
public struct TranslationCoordinator: Sendable {
    private let router: any TranslationRouter
    public init(router: any TranslationRouter) { self.router = router }

    /// - Parameters:
    ///   - only: restrict to these segments (selection, stale re-translate, retry); nil means all.
    public func translate(
        segments: [Segment], source: LanguageCode?, target: LanguageCode, only: Set<SegmentID>? = nil
    ) -> AsyncThrowingStream<TranslationEvent, any Error> {
        let router = router
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let source, !source.rawValue.isEmpty else {
                        continuation.yield(.skipped(.unknownSource, message: TranslationFailure.unknownSource.description))
                        continuation.finish()
                        return
                    }
                    if LanguagePair(source: source, target: target).isSameWrittenLanguage {
                        continuation.yield(.skipped(.sameLanguage, message: TranslationFailure.sameLanguage(source.primary).description))
                        continuation.finish()
                        return
                    }
                    let items = segments.filter { segment in
                        !segment.isIgnored && !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && (only?.contains(segment.id) ?? true)
                    }.map { TranslationItem(segmentID: $0.id, text: $0.text) }
                    continuation.yield(.started(total: items.count))
                    guard !items.isEmpty else {
                        continuation.yield(.finished(translated: 0))
                        continuation.finish()
                        return
                    }
                    let engine = try await router.engine(for: LanguagePair(source: source, target: target))
                    var done = 0
                    for try await result in engine.translate(items: items, from: source, to: target) {
                        done += 1
                        continuation.yield(.segment(result))
                        continuation.yield(.progress(done: done, total: items.count))
                    }
                    continuation.yield(.finished(translated: done))
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

    /// Whether the user should be offered "Retry" for this error (TRN-AC-13).
    public static func isRetryable(_ error: any Error) -> Bool {
        switch error as? AppError {
        case .engineFailure, .cancelled, .outOfMemory, .other: true
        case .modelNotInstalled, .modelDownloadFailed, .unsupportedLanguage: false
        default: error is TranslationFailure ? false : true
        }
    }
}

// MARK: - Dictation (TRN-AC-12)

/// Translates final dictation text before insertion; falls back to the original on failure or timeout.
public struct DictationTranslator: Sendable {
    private let router: any TranslationRouter
    private let timeout: Duration
    public init(router: any TranslationRouter, timeout: Duration = .seconds(3)) {
        self.router = router
        self.timeout = timeout
    }

    public struct Outcome: Sendable, Equatable {
        public var text: String
        public var didTranslate: Bool
        public var isLowConfidence: Bool
    }

    public func translateBeforeInsert(_ text: String, from: LanguageCode, to: LanguageCode) async -> Outcome {
        let original = Outcome(text: text, didTranslate: false, isLowConfidence: false)
        let router = router
        let limit = timeout
        let work = Task<Outcome?, Never> {
            do {
                let engine = try await router.engine(for: LanguagePair(source: from, target: to))
                for try await out in engine.translate(items: [TranslationItem(segmentID: SegmentID(), text: text)], from: from, to: to) {
                    return Outcome(text: out.text, didTranslate: true, isLowConfidence: out.isLowConfidence)
                }
            } catch {}
            return nil
        }
        let timer = Task {
            try? await Task.sleep(for: limit)
            work.cancel()
        }
        let result = await work.value
        timer.cancel()
        return result ?? original
    }
}

// MARK: - Live translation (TRN-AC-09)

/// Translates finalized live lines at most once per `minInterval`, keeping only the newest pending line (stale ones are dropped).
public actor LiveTranslator {
    public nonisolated let results: AsyncStream<TranslatedSegment>
    public private(set) var droppedCount = 0
    private let continuation: AsyncStream<TranslatedSegment>.Continuation
    private let router: any TranslationRouter
    private let pair: LanguagePair
    private let minInterval: Duration
    private let clock: @Sendable () -> ContinuousClock.Instant
    private let sleep: @Sendable (Duration) async -> Void
    private var pending: TranslationItem?
    private var lastStart: ContinuousClock.Instant?
    private var worker: Task<Void, Never>?

    public init(
        router: any TranslationRouter, pair: LanguagePair, minInterval: Duration = .seconds(1),
        clock: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        (results, continuation) = AsyncStream<TranslatedSegment>.makeStream(bufferingPolicy: .bufferingNewest(16))
        self.router = router
        self.pair = pair
        self.minInterval = minInterval
        self.clock = clock
        self.sleep = sleep
    }

    /// Queues a finalized line. A line still pending is replaced (dropped as stale).
    public func submit(_ item: TranslationItem) {
        if pending != nil { droppedCount += 1 }
        pending = item
        if worker == nil { worker = Task { await self.drain() } }
    }

    public func stop() {
        worker?.cancel()
        worker = nil
        pending = nil
        continuation.finish()
    }

    private func drain() async {
        while let _ = pending, !Task.isCancelled {
            if let lastStart {
                let wait = minInterval - (clock() - lastStart)
                if wait > .zero { await sleep(wait) }
            }
            guard let item = pending else { break }
            pending = nil
            lastStart = clock()
            do {
                let engine = try await router.engine(for: pair)
                for try await out in engine.translate(items: [item], from: pair.source, to: pair.target) { continuation.yield(out) }
            } catch {}
        }
        worker = nil
    }
}
