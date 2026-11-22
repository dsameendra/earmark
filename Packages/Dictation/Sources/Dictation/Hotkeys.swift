import AppCore
import ApplicationServices
import CoreGraphics
import Foundation
import Synchronization

// MARK: - Key combos

/// Device-independent modifier bits, matching `NSEvent.ModifierFlags` / `CGEventFlags` raw values.
public enum ModifierMask {
    public static let shift = 0x20000
    public static let control = 0x40000
    public static let option = 0x80000
    public static let command = 0x100000
    /// `NSEvent.ModifierFlags.function` (Fn / Globe).
    public static let function = 0x800000
    public static let all = shift | control | option | command | function
}

extension KeyCombo {
    /// Key code of the Fn / Globe key (reported through `flagsChanged`).
    public static let functionKeyCode: UInt16 = 63
    /// The Fn / Globe key on its own: the default press-and-hold dictation trigger.
    public static let fn = KeyCombo(keyCode: functionKeyCode, modifiers: ModifierMask.function)

    /// Key codes of modifier keys. Combos on these keys fire from `flagsChanged`, not `keyDown`.
    static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 58, 59, 60, 61, 62, 63]

    /// True when the combo is a lone modifier key (Fn, Right Option, ...).
    public var isModifierOnly: Bool { Self.modifierKeyCodes.contains(keyCode) }

    /// The modifier bit a modifier-only key sets while held.
    var ownModifierBit: Int {
        switch keyCode {
        case 54, 55: ModifierMask.command
        case 56, 60: ModifierMask.shift
        case 58, 61: ModifierMask.option
        case 59, 62: ModifierMask.control
        case 63: ModifierMask.function
        default: 0
        }
    }
}

/// Human-readable combo names for HUD hints and settings ("Fn", "⌃⌥D").
public enum KeyComboFormatter {
    public static func name(for combo: KeyCombo) -> String {
        if combo.isModifierOnly {
            switch combo.keyCode {
            case 63: return "Fn"
            case 54, 55: return "⌘"
            case 56, 60: return "⇧"
            case 58, 61: return "⌥"
            default: return "⌃"
            }
        }
        var s = ""
        if combo.modifiers & ModifierMask.function != 0 { s += "Fn" }
        if combo.modifiers & ModifierMask.control != 0 { s += "⌃" }
        if combo.modifiers & ModifierMask.option != 0 { s += "⌥" }
        if combo.modifiers & ModifierMask.shift != 0 { s += "⇧" }
        if combo.modifiers & ModifierMask.command != 0 { s += "⌘" }
        return s + (keyNames[combo.keyCode] ?? "Key \(combo.keyCode)")
    }

    static let keyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E",
        15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-",
        28: "8", 29: "0", 31: "O", 32: "U", 34: "I", 35: "P", 36: "Return", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        48: "Tab", 49: "Space", 51: "Delete", 53: "Esc", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 103: "F11",
        109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1", 99: "F3",
    ]
}

// MARK: - Raw events and matching

/// A keyboard event as seen by the event source, decoupled from CGEvent so the matcher is unit-testable.
public struct RawKeyEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case keyDown, keyUp, flagsChanged
        /// The source lost events (event tap disabled by timeout or user input): drop any held state.
        case reset
    }
    public var kind: Kind
    public var keyCode: UInt16
    /// Raw modifier flags at the time of the event (masked with ``ModifierMask/all`` by the matcher).
    public var modifiers: Int
    public var isAutorepeat: Bool
    public init(kind: Kind, keyCode: UInt16, modifiers: Int, isAutorepeat: Bool = false) {
        self.kind = kind
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isAutorepeat = isAutorepeat
    }
}

/// Turns raw key events into press/release transitions for one combo. Value type, no I/O.
public struct HotkeyMatcher: Sendable {
    public let combo: KeyCombo
    public private(set) var isDown = false
    /// True between a consumed key-down and its key-up, so the matching key-up and auto-repeats are consumed too.
    private var swallowing = false
    public init(combo: KeyCombo) { self.combo = combo }

    /// Press/release transition only (see ``process(_:)`` for the swallow decision).
    public mutating func handle(_ event: RawKeyEvent) -> HotkeyEvent? { process(event).event }

    /// Transition plus whether an active event tap should swallow this event so the focused app never sees it.
    ///
    /// Key-down, auto-repeat and key-up of the combo's key are consumed together. Modifier-only combos are consumed
    /// only for Fn / Globe (so the emoji picker does not open); swallowing Command, Option, Shift or Control changes
    /// would leave other apps with a stuck modifier.
    public mutating func process(_ event: RawKeyEvent) -> (event: HotkeyEvent?, consume: Bool) {
        let mods = event.modifiers & ModifierMask.all
        if event.kind == .reset {
            swallowing = false
            guard isDown else { return (nil, false) }
            isDown = false
            return (.released, false)
        }
        if combo.isModifierOnly {
            guard event.kind == .flagsChanged, event.keyCode == combo.keyCode else { return (nil, false) }
            let consume = combo.keyCode == KeyCombo.functionKeyCode
            let nowDown = mods & combo.ownModifierBit != 0
            guard nowDown != isDown else { return (nil, consume) }
            isDown = nowDown
            return (nowDown ? .pressed : .released, consume)
        }
        switch event.kind {
        case .keyDown:
            guard event.keyCode == combo.keyCode, mods == (combo.modifiers & ModifierMask.all) else { return (nil, false) }
            swallowing = true
            guard !event.isAutorepeat, !isDown else { return (nil, true) }
            isDown = true
            return (.pressed, true)
        case .keyUp:
            guard event.keyCode == combo.keyCode else { return (nil, false) }
            let consume = swallowing
            swallowing = false
            guard isDown else { return (nil, consume) }
            isDown = false
            return (.released, consume)
        case .flagsChanged:
            // Letting go of a modifier before the key still ends a push-to-talk hold.
            guard isDown, mods != (combo.modifiers & ModifierMask.all) else { return (nil, false) }
            isDown = false
            return (.released, false)
        case .reset:
            return (nil, false)
        }
    }
}

// MARK: - Conflict detection (DICT-AC-02)

public enum ShortcutConflict: Sendable, Equatable {
    case none
    /// Hard reject: another Earmark action already uses this combo.
    case earmarkAction(HotkeyAction)
    /// Soft warning: a common system shortcut (the name is shown to the user).
    case systemShortcut(String)

    public var isRejected: Bool { if case .earmarkAction = self { true } else { false } }
}

public enum ShortcutConflictChecker {
    public static func check(
        _ combo: KeyCombo, for action: HotkeyAction, existing: [HotkeyAction: KeyCombo]
    ) -> ShortcutConflict {
        let normalized = normalize(combo)
        if let other = existing.first(where: { $0.key != action && normalize($0.value) == normalized }) {
            return .earmarkAction(other.key)
        }
        if let name = systemShortcuts[normalized] { return .systemShortcut(name) }
        return .none
    }

    static func normalize(_ combo: KeyCombo) -> KeyCombo {
        KeyCombo(keyCode: combo.keyCode, modifiers: combo.modifiers & ModifierMask.all)
    }

    private static let systemShortcutList: [(UInt16, Int, String)] = [
        (49, ModifierMask.command, "Spotlight (⌘Space)"),
        (49, ModifierMask.control, "Input source switch (⌃Space)"),
        (49, ModifierMask.control | ModifierMask.command, "Emoji & Symbols (⌃⌘Space)"),
        (48, ModifierMask.command, "App switcher (⌘Tab)"),
        (12, ModifierMask.command, "Quit (⌘Q)"),
        (13, ModifierMask.command, "Close window (⌘W)"),
        (4, ModifierMask.command, "Hide app (⌘H)"),
        (46, ModifierMask.command, "Minimize (⌘M)"),
        (8, ModifierMask.command, "Copy (⌘C)"),
        (9, ModifierMask.command, "Paste (⌘V)"),
        (7, ModifierMask.command, "Cut (⌘X)"),
        (6, ModifierMask.command, "Undo (⌘Z)"),
        (0, ModifierMask.command, "Select All (⌘A)"),
        (20, ModifierMask.command | ModifierMask.shift, "Screenshot (⌘⇧3)"),
        (21, ModifierMask.command | ModifierMask.shift, "Screenshot selection (⌘⇧4)"),
        (23, ModifierMask.command | ModifierMask.shift, "Screenshot options (⌘⇧5)"),
        (53, ModifierMask.command | ModifierMask.option, "Force Quit (⌘⌥Esc)"),
        (12, ModifierMask.command | ModifierMask.control, "Lock Screen (⌃⌘Q)"),
        (63, ModifierMask.function, "Globe key (may open the emoji picker or system Dictation; set it to Do Nothing in Keyboard settings)"),
    ]

    static let systemShortcuts: [KeyCombo: String] = Dictionary(
        uniqueKeysWithValues: systemShortcutList.map { (KeyCombo(keyCode: $0.0, modifiers: $0.1), $0.2) })
}

// MARK: - Event source abstraction

public enum HotkeyError: Error, Sendable, Equatable {
    /// Another Earmark action already uses this combo.
    case conflict(HotkeyAction)
    /// The event tap could not be created (Input Monitoring / Accessibility not granted).
    case eventSourceUnavailable
}

/// A source of raw global key events. The production implementation wraps a CGEventTap; tests inject a fake.
public protocol HotkeyEventSource: Sendable {
    /// Starts delivering events to `handler` (called on an arbitrary thread). The handler returns `true` when the event
    /// belongs to a registered shortcut and should be swallowed; sources that cannot swallow ignore the result.
    /// Throws ``HotkeyError/eventSourceUnavailable``.
    func start(handler: @escaping @Sendable (RawKeyEvent) -> Bool) throws
    func stop()
    /// What the started source can do (valid after a successful `start`).
    var capture: HotkeyCapture { get }
}

extension HotkeyEventSource {
    public var capture: HotkeyCapture { .listenOnly }
}

// MARK: - Service

/// Permission and system-setting probes behind the hotkey diagnostics, injectable for tests.
public struct HotkeySystemState: Sendable {
    public var accessibilityTrusted: @Sendable () -> Bool
    public var inputMonitoringGranted: @Sendable () -> Bool
    /// Raw `AppleFnUsageType` from `com.apple.HIToolbox`, `nil` when never set.
    public var fnUsageType: @Sendable () -> Int?

    public init(
        accessibilityTrusted: @escaping @Sendable () -> Bool, inputMonitoringGranted: @escaping @Sendable () -> Bool,
        fnUsageType: @escaping @Sendable () -> Int?
    ) {
        self.accessibilityTrusted = accessibilityTrusted
        self.inputMonitoringGranted = inputMonitoringGranted
        self.fnUsageType = fnUsageType
    }

    public static let system = HotkeySystemState(
        accessibilityTrusted: { AXIsProcessTrusted() },
        inputMonitoringGranted: { CGPreflightListenEventAccess() },
        fnUsageType: {
            (CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString) as? NSNumber)?.intValue
        })
}

/// User-facing registration failure copy.
enum HotkeyFailureMessage {
    static let unavailable =
        "Earmark could not start global key monitoring. Allow Earmark under Privacy & Security > Accessibility "
        + "(and Input Monitoring), then reopen this pane."
    static func conflict(_ other: HotkeyAction) -> String { "This shortcut is already used by another Earmark action (\(other.rawValue))." }
}

/// Global hotkey service (`HotkeyServicing`). One shared event source; idle cost is one event tap.
public final class GlobalHotkeyService: HotkeyServicing, HotkeyDiagnosing {
    private struct Registration {
        var matcher: HotkeyMatcher
        var continuation: AsyncStream<HotkeyEvent>.Continuation
    }
    private let source: any HotkeyEventSource
    private let system: HotkeySystemState
    private let registrations = Mutex<[HotkeyAction: Registration]>([:])
    private let running = Mutex(false)
    private let failures = Mutex<[HotkeyAction: String]>([:])

    public init(source: any HotkeyEventSource, system: HotkeySystemState = .system) {
        self.source = source
        self.system = system
    }

    /// Registers `combo` for `action`. Throws ``HotkeyError/conflict(_:)`` if another Earmark action uses it and
    /// ``HotkeyError/eventSourceUnavailable`` if the OS refuses global monitoring (callers degrade gracefully).
    /// Failures are remembered for ``refreshDiagnostics()`` so Settings can explain them.
    public func register(_ action: HotkeyAction, combo: KeyCombo) async throws -> AsyncStream<HotkeyEvent> {
        let existing = registrations.withLock { $0.mapValues { $0.matcher.combo } }
        if case .earmarkAction(let other) = ShortcutConflictChecker.check(combo, for: action, existing: existing) {
            failures.withLock { $0[action] = HotkeyFailureMessage.conflict(other) }
            throw HotkeyError.conflict(other)
        }
        do {
            try startSourceIfNeeded()
        } catch {
            failures.withLock { $0[action] = HotkeyFailureMessage.unavailable }
            throw error
        }
        failures.withLock { $0[action] = nil }
        let (stream, continuation) = AsyncStream<HotkeyEvent>.makeStream(bufferingPolicy: .unbounded)
        let old = registrations.withLock { regs -> AsyncStream<HotkeyEvent>.Continuation? in
            let old = regs[action]?.continuation
            regs[action] = Registration(matcher: HotkeyMatcher(combo: combo), continuation: continuation)
            return old
        }
        old?.finish()
        return stream
    }

    public func unregister(_ action: HotkeyAction) async {
        failures.withLock { $0[action] = nil }
        let (old, empty) = registrations.withLock { regs -> (AsyncStream<HotkeyEvent>.Continuation?, Bool) in
            let old = regs.removeValue(forKey: action)?.continuation
            return (old, regs.isEmpty)
        }
        old?.finish()
        if empty {
            let was = running.withLock { r -> Bool in
                defer { r = false }
                return r
            }
            if was { source.stop() }
        }
    }

    public func refreshDiagnostics() async -> HotkeyDiagnostics {
        let trusted = system.accessibilityTrusted()
        // Accessibility was granted after a listen-only start: restart so the active (swallowing) tap is used.
        if running.withLock({ $0 }), source.capture != .swallowing, trusted {
            source.stop()
            running.withLock { $0 = false }
            try? startSourceIfNeeded()
        }
        let isRunning = running.withLock { $0 }
        return HotkeyDiagnostics(
            capture: isRunning ? source.capture : .unavailable, accessibilityTrusted: trusted,
            inputMonitoringGranted: system.inputMonitoringGranted(), globeKeyAction: GlobeKeyAction(appleFnUsageType: system.fnUsageType()),
            failures: failures.withLock { $0 })
    }

    private func startSourceIfNeeded() throws {
        guard !running.withLock({ $0 }) else { return }
        try source.start { [weak self] event in self?.dispatch(event) ?? false }
        running.withLock { $0 = true }
    }

    @discardableResult
    func dispatch(_ event: RawKeyEvent) -> Bool {
        registrations.withLock { regs in
            var consume = false
            for key in Array(regs.keys) {
                guard let result = regs[key]?.matcher.process(event) else { continue }
                if let out = result.event { regs[key]?.continuation.yield(out) }
                consume = consume || result.consume
            }
            return consume
        }
    }
}
