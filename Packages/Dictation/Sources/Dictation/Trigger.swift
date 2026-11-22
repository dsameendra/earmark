import AppCore
import Foundation

/// Pure hotkey state machine (DICT-AC-01, DICT-AC-13). Maps press/release events plus timestamps to commands.
public struct DictationTrigger: Sendable {
    public enum Command: Sendable, Equatable {
        /// Begin capture.
        case start
        /// Finalize and insert.
        case finish
        /// Discard without inserting (accidental tap).
        case cancel
    }

    public var mode: HotkeyMode
    /// A push-to-talk hold shorter than this is an accidental tap and is cancelled.
    public let minimumHold: TimeInterval
    public private(set) var isActive = false
    private var pressedAt: TimeInterval = 0

    public init(mode: HotkeyMode, minimumHold: TimeInterval = 0.25) {
        self.mode = mode
        self.minimumHold = minimumHold
    }

    public mutating func handle(_ event: HotkeyEvent, at time: TimeInterval) -> Command? {
        switch (mode, event) {
        case (.pushToTalk, .pressed):
            guard !isActive else { return nil }
            isActive = true
            pressedAt = time
            return .start
        case (.pushToTalk, .released):
            guard isActive else { return nil }
            isActive = false
            return time - pressedAt < minimumHold ? .cancel : .finish
        case (.toggle, .pressed):
            if isActive {
                isActive = false
                return .finish
            }
            isActive = true
            pressedAt = time
            return .start
        case (.toggle, .released):
            return nil
        }
    }

    /// Called when a session ends for any reason other than the user's own release (error, permission, busy).
    public mutating func sessionEnded() { isActive = false }

    public mutating func setMode(_ newMode: HotkeyMode) {
        mode = newMode
        isActive = false
    }
}

/// HUD hint copy derived from mode and combo ("Release Fn to insert", "Press ⌃⌥D to insert").
public enum DictationHint {
    public static func text(mode: HotkeyMode, combo: KeyCombo) -> String {
        let name = KeyComboFormatter.name(for: combo)
        switch mode {
        case .pushToTalk: return "Release \(name) to insert"
        case .toggle: return "Press \(name) to insert"
        }
    }
}

/// Optional punctuation and capitalization cleanup (applied after ignore and replacement rules).
public enum DictationTextFormatter {
    public static func clean(_ text: String, autoPunctuation: Bool) -> String {
        var s = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard autoPunctuation, !s.isEmpty else { return s }
        if let first = s.first, first.isLowercase { s = first.uppercased() + s.dropFirst() }
        if let last = s.last, last.isLetter || last.isNumber { s += "." }
        return s
    }
}
