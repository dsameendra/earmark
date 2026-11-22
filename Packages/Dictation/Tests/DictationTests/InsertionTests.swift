import AppCore
import Foundation
import Synchronization
import Testing

@testable import Dictation

@Suite("Text insertion")
struct InsertionTests {
    static let original = [
        PasteboardItemSnapshot(representations: [
            .init(type: "public.utf8-plain-text", data: Data("keep me".utf8)),
            .init(type: "public.html", data: Data("<b>keep me</b>".utf8)),
        ]),
        PasteboardItemSnapshot(representations: [.init(type: "public.png", data: Data([1, 2, 3]))]),
    ]

    private func make(
        secure: Bool = false, trusted: Bool = true, ax: AXInsertResult = .unsupported, keystrokeFails: Bool = false,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }
    ) -> (TextInserter, FakePasteboard, FakeKeystroke, FakeAX) {
        let pb = FakePasteboard(items: Self.original)
        let key = FakeKeystroke(pasteboard: pb, fails: keystrokeFails)
        let axf = FakeAX(result: ax)
        let inserter = TextInserter(
            pasteboard: pb, keystroke: key, accessibility: axf, secureInput: FakeSecure(isSecureInputActive: secure),
            trust: FakeTrust(isTrusted: trusted), sleep: sleep)
        return (inserter, pb, key, axf)
    }

    @Test func pasteboardMethodSavesWritesPastesThenRestoresAllItemTypes() async throws {
        let (inserter, pb, key, _) = make()
        try await inserter.insert("hello", method: .pasteboardPaste)
        #expect(pb.log == ["snapshot", "write:hello", "cmdV", "restore"])
        #expect(key.pasteCount == 1)
        #expect(pb.items == Self.original)
    }

    @Test func restoreHappensWithin500ms() async throws {
        let waited = Mutex<Duration?>(nil)
        let (inserter, _, _, _) = make(sleep: { d in waited.withLock { $0 = d } })
        try await inserter.insert("x", method: .pasteboardPaste)
        let d = try #require(waited.withLock { $0 })
        #expect(d <= .milliseconds(500))
    }

    @Test func doesNotClobberPasteboardChangedByUserMeanwhile() async throws {
        let box = Mutex<FakePasteboard?>(nil)
        let (inserter, pb, _, _) = make(sleep: { _ in box.withLock { $0 }?.externalWrite("user copied this") })
        box.withLock { $0 = pb }
        try await inserter.insert("hello", method: .pasteboardPaste)
        #expect(!pb.log.contains("restore"))
        #expect(String(data: pb.items[0].representations[0].data, encoding: .utf8) == "user copied this")
    }

    @Test func failedKeystrokeRestoresPasteboardAndThrows() async {
        let (inserter, pb, _, _) = make(keystrokeFails: true)
        await #expect(throws: DictationError.self) { try await inserter.insert("x", method: .pasteboardPaste) }
        #expect(pb.items == Self.original)
    }

    @Test func accessibilityMethodInsertsWithoutTouchingPasteboard() async throws {
        let (inserter, pb, key, ax) = make(ax: .inserted)
        try await inserter.insert("héllo සිංහල", method: .accessibility)
        #expect(ax.texts == ["héllo සිංහල"])
        #expect(key.pasteCount == 0)
        #expect(pb.log.isEmpty)
    }

    @Test func accessibilityFallsBackToPasteboardWhenUnsupported() async throws {
        let (inserter, pb, key, _) = make(ax: .unsupported)
        try await inserter.insert("hello", method: .accessibility)
        #expect(key.pasteCount == 1)
        #expect(pb.items == Self.original)
    }

    @Test func secureInputRefusesAndTouchesNothing() async {
        let (inserter, pb, key, ax) = make(secure: true, ax: .inserted)
        await #expect(throws: DictationError.secureInputActive) { try await inserter.insert("secret", method: .pasteboardPaste) }
        #expect(pb.log.isEmpty && key.pasteCount == 0 && ax.texts.isEmpty)
        #expect(DictationError.secureInputActive.errorDescription?.contains("password") == true)
    }

    @Test func untrustedProcessThrowsPermissionDeniedAndNeverInsertsSilently() async {
        let (inserter, pb, key, _) = make(trusted: false)
        await #expect(throws: AppError.permissionDenied(.accessibility)) { try await inserter.insert("x", method: .pasteboardPaste) }
        #expect(pb.log.isEmpty && key.pasteCount == 0)
    }

    @Test func emptyTextIsNotInserted() async throws {
        let (inserter, pb, _, _) = make()
        try await inserter.insert("", method: .pasteboardPaste)
        #expect(pb.log.isEmpty)
    }
}
