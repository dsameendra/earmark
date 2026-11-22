import AppCore
import Foundation

// MARK: - Abstractions (faked in tests, real TCC-gated implementations in SystemInsertion.swift)

/// One pasteboard item with every representation, so restore preserves all item types.
public struct PasteboardItemSnapshot: Sendable, Equatable {
    public var representations: [Representation]
    public struct Representation: Sendable, Equatable {
        public var type: String
        public var data: Data
        public init(type: String, data: Data) {
            self.type = type
            self.data = data
        }
    }
    public init(representations: [Representation]) { self.representations = representations }
}

public protocol PasteboardAccessing: Sendable {
    var changeCount: Int { get }
    func snapshot() -> [PasteboardItemSnapshot]
    /// Replaces the contents with `text`, flagged transient/concealed so clipboard managers ignore it.
    /// Returns the change count right after the write.
    func writeTransient(_ text: String) -> Int
    func restore(_ items: [PasteboardItemSnapshot])
}

public protocol KeystrokePosting: Sendable {
    /// Synthesizes ⌘V into the frontmost app.
    func postPaste() throws
}

public enum AXInsertResult: Sendable, Equatable {
    case inserted
    /// No focused element, or it does not accept `AXSelectedText` writes.
    case unsupported
}

public protocol AccessibilityTextInserting: Sendable {
    func insert(_ text: String) -> AXInsertResult
}

public protocol SecureInputChecking: Sendable {
    var isSecureInputActive: Bool { get }
}

public protocol AccessibilityTrustChecking: Sendable {
    var isTrusted: Bool { get }
}

public enum DictationError: Error, Sendable, Equatable {
    /// A password field (or other secure input) is focused; insertion is refused (DICT-AC-15).
    case secureInputActive
    case insertionFailed(String)
    case translationFailed(String)
}

extension DictationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .secureInputActive: "Dictation can't type into password fields or other secure input."
        case .insertionFailed(let r): "Couldn't insert the text: \(r)"
        case .translationFailed(let r): "Translation failed: \(r)"
        }
    }
}

// MARK: - Inserter

/// `TextInserting` implementation: pasteboard-preserving ⌘V, or Accessibility insertion with pasteboard fallback.
public struct TextInserter: TextInserting {
    private let pasteboard: any PasteboardAccessing
    private let keystroke: any KeystrokePosting
    private let accessibility: any AccessibilityTextInserting
    private let secureInput: any SecureInputChecking
    private let trust: any AccessibilityTrustChecking
    private let restoreDelay: Duration
    private let sleep: @Sendable (Duration) async throws -> Void

    /// `restoreDelay` is how long the target app gets to read the pasteboard before it is restored
    /// (DICT-AC-04 requires the restore within 500 ms).
    public init(
        pasteboard: any PasteboardAccessing, keystroke: any KeystrokePosting, accessibility: any AccessibilityTextInserting,
        secureInput: any SecureInputChecking, trust: any AccessibilityTrustChecking,
        restoreDelay: Duration = .milliseconds(250),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.pasteboard = pasteboard
        self.keystroke = keystroke
        self.accessibility = accessibility
        self.secureInput = secureInput
        self.trust = trust
        self.restoreDelay = restoreDelay
        self.sleep = sleep
    }

    public func insert(_ text: String, method: TextInsertionMethod) async throws {
        guard !text.isEmpty else { return }
        if secureInput.isSecureInputActive { throw DictationError.secureInputActive }
        guard trust.isTrusted else { throw AppError.permissionDenied(.accessibility) }
        if method == .accessibility, accessibility.insert(text) == .inserted { return }
        try await pasteViaPasteboard(text)
    }

    private func pasteViaPasteboard(_ text: String) async throws {
        let saved = pasteboard.snapshot()
        let written = pasteboard.writeTransient(text)
        do {
            try keystroke.postPaste()
        } catch {
            pasteboard.restore(saved)
            throw DictationError.insertionFailed(String(describing: error))
        }
        try? await sleep(restoreDelay)
        // Only restore if nobody (the user, another app) changed the pasteboard in the meantime.
        if pasteboard.changeCount == written { pasteboard.restore(saved) }
    }
}
