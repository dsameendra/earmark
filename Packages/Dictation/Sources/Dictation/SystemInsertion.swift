import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// `NSPasteboard.general` adapter. Unverified against real clipboard managers.
public final class SystemPasteboard: PasteboardAccessing, @unchecked Sendable {
    private var board: NSPasteboard { .general }
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    public init() {}

    public var changeCount: Int { board.changeCount }

    public func snapshot() -> [PasteboardItemSnapshot] {
        (board.pasteboardItems ?? []).map { item in
            PasteboardItemSnapshot(
                representations: item.types.compactMap { type in
                    item.data(forType: type).map { .init(type: type.rawValue, data: $0) }
                })
        }
    }

    public func writeTransient(_ text: String) -> Int {
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: Self.transientType)
        item.setData(Data(), forType: Self.concealedType)
        board.writeObjects([item])
        return board.changeCount
    }

    public func restore(_ items: [PasteboardItemSnapshot]) {
        board.clearContents()
        let restored = items.map { snap -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for rep in snap.representations { item.setData(rep.data, forType: NSPasteboard.PasteboardType(rep.type)) }
            return item
        }
        if !restored.isEmpty { board.writeObjects(restored) }
    }
}

/// Posts ⌘V through the HID event system (requires Accessibility trust).
public struct SystemKeystrokePoster: KeystrokePosting {
    public init() {}
    public func postPaste() throws {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else { throw DictationError.insertionFailed("could not create key events") }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }
}

/// Inserts by writing `AXSelectedText` on the focused element. Many web/Electron apps report success without
/// inserting; the pasteboard method is the reliable default (see ``TextInsertionMethod``).
public struct SystemAccessibilityInserter: AccessibilityTextInserting {
    public init() {}
    public func insert(_ text: String) -> AXInsertResult {
        guard let element = AXFocus.focusedElement() else { return .unsupported }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success, settable.boolValue
        else { return .unsupported }
        let err = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        return err == .success ? .inserted : .unsupported
    }
}

enum AXFocus {
    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        // Safe: type ID checked above.
        return (value as! AXUIElement)  // swiftlint:disable:this force_cast
    }
}

public struct SystemSecureInputChecker: SecureInputChecking {
    public init() {}
    public var isSecureInputActive: Bool { IsSecureEventInputEnabled() }
}

public struct SystemAccessibilityTrust: AccessibilityTrustChecking {
    public init() {}
    public var isTrusted: Bool { AXIsProcessTrusted() }
}

extension TextInserter {
    /// The production inserter wired to the real pasteboard, CGEvent and AX APIs.
    public static func system() -> TextInserter {
        TextInserter(
            pasteboard: SystemPasteboard(), keystroke: SystemKeystrokePoster(), accessibility: SystemAccessibilityInserter(),
            secureInput: SystemSecureInputChecker(), trust: SystemAccessibilityTrust())
    }
}
