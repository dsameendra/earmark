import AppCore
import AppCoreTesting
import Foundation
import Synchronization

@testable import Dictation

// MARK: Event source

final class FakeEventSource: HotkeyEventSource, @unchecked Sendable {
    private let state = Mutex<(handler: (@Sendable (RawKeyEvent) -> Bool)?, starts: Int, stops: Int)>((nil, 0, 0))
    private let failing: Mutex<Bool>
    let capture: HotkeyCapture
    init(failStart: Bool = false, capture: HotkeyCapture = .swallowing) {
        failing = Mutex(failStart)
        self.capture = capture
    }
    func setFailStart(_ value: Bool) { failing.withLock { $0 = value } }
    func start(handler: @escaping @Sendable (RawKeyEvent) -> Bool) throws {
        let failStart = failing.withLock { $0 }
        if failStart { throw HotkeyError.eventSourceUnavailable }
        state.withLock {
            $0.handler = handler
            $0.starts += 1
        }
    }
    func stop() {
        state.withLock {
            $0.handler = nil
            $0.stops += 1
        }
    }
    @discardableResult func emit(_ event: RawKeyEvent) -> Bool { state.withLock { $0.handler }?(event) ?? false }
    var starts: Int { state.withLock { $0.starts } }
    var stops: Int { state.withLock { $0.stops } }
}

// MARK: Insertion fakes

final class FakePasteboard: PasteboardAccessing, @unchecked Sendable {
    private let state: Mutex<State>
    struct State {
        var items: [PasteboardItemSnapshot]
        var changeCount = 1
        var log: [String] = []
    }
    init(items: [PasteboardItemSnapshot]) { state = Mutex(State(items: items)) }
    var changeCount: Int { state.withLock { $0.changeCount } }
    var items: [PasteboardItemSnapshot] { state.withLock { $0.items } }
    var log: [String] { state.withLock { $0.log } }
    func snapshot() -> [PasteboardItemSnapshot] {
        state.withLock {
            $0.log.append("snapshot")
            return $0.items
        }
    }
    func writeTransient(_ text: String) -> Int {
        state.withLock {
            $0.log.append("write:\(text)")
            $0.items = [.init(representations: [.init(type: "public.utf8-plain-text", data: Data(text.utf8))])]
            $0.changeCount += 1
            return $0.changeCount
        }
    }
    func restore(_ items: [PasteboardItemSnapshot]) {
        state.withLock {
            $0.log.append("restore")
            $0.items = items
            $0.changeCount += 1
        }
    }
    /// Simulates another app (or the user) writing to the pasteboard.
    func externalWrite(_ text: String) {
        state.withLock {
            $0.items = [.init(representations: [.init(type: "public.utf8-plain-text", data: Data(text.utf8))])]
            $0.changeCount += 1
        }
    }
    func appendLog(_ s: String) { state.withLock { $0.log.append(s) } }
}

final class FakeKeystroke: KeystrokePosting, @unchecked Sendable {
    let pasteboard: FakePasteboard?
    let fails: Bool
    private let count = Mutex(0)
    init(pasteboard: FakePasteboard? = nil, fails: Bool = false) {
        self.pasteboard = pasteboard
        self.fails = fails
    }
    var pasteCount: Int { count.withLock { $0 } }
    func postPaste() throws {
        if fails { throw DictationError.insertionFailed("boom") }
        count.withLock { $0 += 1 }
        pasteboard?.appendLog("cmdV")
    }
}

final class FakeAX: AccessibilityTextInserting, @unchecked Sendable {
    let result: AXInsertResult
    private let inserted = Mutex<[String]>([])
    init(result: AXInsertResult) { self.result = result }
    var texts: [String] { inserted.withLock { $0 } }
    func insert(_ text: String) -> AXInsertResult {
        if result == .inserted { inserted.withLock { $0.append(text) } }
        return result
    }
}

struct FakeSecure: SecureInputChecking { var isSecureInputActive: Bool }
struct FakeTrust: AccessibilityTrustChecking { var isTrusted: Bool }

// MARK: Controller fakes

actor MemorySettings: SettingsStore {
    private var store: [String: Data] = [:]
    func value<T: Codable & Sendable>(for key: String, as: T.Type) async -> T? {
        guard let d = store[key] else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }
    func set<T: Codable & Sendable>(_ value: T, for key: String) async { store[key] = try? JSONEncoder().encode(value) }
    nonisolated func changes(for key: String) -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

actor MemoryHistory: DictationHistoryRepository {
    private(set) var entries: [DictationEntry] = []
    var failSave = false
    func recent(limit: Int, matching: String?) async throws -> [DictationEntry] {
        let filtered = entries.filter { matching == nil || $0.text.localizedCaseInsensitiveContains(matching!) }
        return Array(filtered.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }
    func save(_ entry: DictationEntry) async throws {
        if failSave { throw AppError.persistence(reason: "x") }
        entries.append(entry)
    }
    func clear() async throws { entries = [] }
}

actor MemoryRules: RuleRepository {
    var ignore: [IgnoreRule] = []
    var replace: [ReplacementRule] = []
    init(ignore: [IgnoreRule] = [], replace: [ReplacementRule] = []) {
        self.ignore = ignore
        self.replace = replace
    }
    func ignoreRules() async throws -> [IgnoreRule] { ignore }
    func saveIgnoreRule(_ rule: IgnoreRule) async throws {}
    func removeIgnoreRule(_ id: RuleID) async throws {}
    func replaceAllIgnoreRules(_ rules: [IgnoreRule]) async throws {}
    func replacementRules() async throws -> [ReplacementRule] { replace }
    func saveReplacementRule(_ rule: ReplacementRule) async throws {}
    func removeReplacementRule(_ id: RuleID) async throws {}
}

/// Records the context it receives and applies a literal find/replace plus ignore of whole-segment matches,
/// mimicking the order (ignore, then replace) of the real chain.
final class SpyProcessor: TranscriptPostProcessor, @unchecked Sendable {
    let contexts = Mutex<[PostProcessingContext]>([])
    func process(_ segments: [Segment], context: PostProcessingContext) async -> [Segment] {
        contexts.withLock { $0.append(context) }
        var out: [Segment] = []
        for var s in segments {
            if context.ignoreRules.contains(where: { $0.pattern == s.text }) { s.isIgnored = true }
            for r in context.replacementRules where !s.isIgnored { s.text = s.text.replacingOccurrences(of: r.find, with: r.replacement) }
            out.append(s)
        }
        return out
    }
}

final class FakePermissions: PermissionsServicing, @unchecked Sendable {
    private let state = Mutex<(status: PermissionStatus, cont: AsyncStream<(PermissionKind, PermissionStatus)>.Continuation?)>((.granted, nil))
    /// How long `status` takes, to model a slow Accessibility check.
    private let delay: Duration
    init(accessibility: PermissionStatus = .granted, delay: Duration = .zero) {
        self.delay = delay
        state.withLock { $0.status = accessibility }
    }
    func status(_ kind: PermissionKind) async -> PermissionStatus {
        if delay > .zero { try? await Task.sleep(for: delay) }
        return state.withLock { $0.status }
    }
    func request(_ kind: PermissionKind) async -> PermissionStatus { state.withLock { $0.status } }
    func settingsURL(for kind: PermissionKind) -> URL { URL(string: "x-apple.systempreferences:test")! }
    func changes() -> AsyncStream<(PermissionKind, PermissionStatus)> {
        let (s, c) = AsyncStream<(PermissionKind, PermissionStatus)>.makeStream()
        state.withLock { $0.cont = c }
        return s
    }
    func grant() {
        let c = state.withLock { st -> AsyncStream<(PermissionKind, PermissionStatus)>.Continuation? in
            st.status = .granted
            return st.cont
        }
        c?.yield((.accessibility, .granted))
    }
}

final class FakeHUD: DictationHUDPresenting, @unchecked Sendable {
    private let events = Mutex<[String]>([])
    var log: [String] { events.withLock { $0 } }
    private func add(_ s: String) { events.withLock { $0.append(s) } }
    func show(_ info: DictationHUDInfo) async { add("show:\(info.hint)") }
    func update(partial: String) async { add("partial:\(partial)") }
    func update(level: Float) async {}
    func showProcessing() async { add("processing") }
    func showExperimentalBadge() async { add("experimental") }
    func dismiss() async { add("dismiss") }
    func dismissWithError(_ message: String) async { add("error:\(message)") }
}

final class FakeNotifier: DictationNotifying, @unchecked Sendable {
    private let items = Mutex<[DictationNotice]>([])
    var notices: [DictationNotice] { items.withLock { $0 } }
    func notify(_ notice: DictationNotice) async { items.withLock { $0.append(notice) } }
}

final class FakeOnboarding: DictationOnboardingPresenting, @unchecked Sendable {
    private let state = Mutex((presented: 0, dismissed: 0))
    var presented: Int { state.withLock { $0.presented } }
    var dismissed: Int { state.withLock { $0.dismissed } }
    func presentAccessibilityOnboarding(settingsURL: URL) async { state.withLock { $0.presented += 1 } }
    func dismissAccessibilityOnboarding() async { state.withLock { $0.dismissed += 1 } }
}

final class FakeInserter: TextInserting, @unchecked Sendable {
    private let state = Mutex<(texts: [String], methods: [TextInsertionMethod], error: (any Error)?)>(([], [], nil))
    init(error: (any Error)? = nil) { state.withLock { $0.error = error } }
    var texts: [String] { state.withLock { $0.texts } }
    var methods: [TextInsertionMethod] { state.withLock { $0.methods } }
    func insert(_ text: String, method: TextInsertionMethod) async throws {
        if let e = state.withLock({ $0.error }) { throw e }
        state.withLock {
            $0.texts.append(text)
            $0.methods.append(method)
        }
    }
}

struct ThrowingTranslationRouter: TranslationRouter {
    func engine(for pair: LanguagePair) async throws -> any TranslationEngine { throw AppError.unsupportedLanguage(pair.target) }
}

struct UppercaseTranslationEngine: TranslationEngine {
    var id: EngineID { "fake.translate" }
    func supportedPairs() async -> Set<LanguagePair> { [] }
    func translate(items: [TranslationItem], from: LanguageCode, to: LanguageCode) -> AsyncThrowingStream<TranslatedSegment, any Error> {
        AsyncThrowingStream { c in
            for i in items { c.yield(TranslatedSegment(segmentID: i.segmentID, text: "[\(to.rawValue)] " + i.text, engine: id)) }
            c.finish()
        }
    }
}

struct FixedTranslationRouter: TranslationRouter {
    func engine(for pair: LanguagePair) async throws -> any TranslationEngine { UppercaseTranslationEngine() }
}

final class ManualClock: @unchecked Sendable {
    private let t = Mutex(1000.0)
    func advance(_ s: TimeInterval) { t.withLock { $0 += s } }
    var now: TimeInterval { t.withLock { $0 } }
}

/// Polls until `condition` holds (max ~3 s).
func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<300 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

func seg(_ text: String, lang: LanguageCode? = .english) -> Segment {
    Segment(start: 0, end: 1, text: text, languageCode: lang)
}
