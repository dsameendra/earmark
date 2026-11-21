import AppCore
import FeatureSupport
import Foundation
import Observation

/// Shortcuts the user can rebind: global hotkeys (`HotkeyAction`) and in-app commands.
public enum ShortcutAction: String, CaseIterable, Identifiable, Sendable {
    case dictation, toggleLiveCaptions, toggleMeetingCapture, bookmarkMoment, toggleOverlayClickThrough
    case find, findAndReplace, quickOpen, exportTranscript

    public var id: String { rawValue }

    public var isGlobal: Bool { hotkeyAction != nil }

    public var hotkeyAction: HotkeyAction? { HotkeyAction(rawValue: rawValue) }

    public var title: String {
        switch self {
        case .dictation: "Dictation"
        case .toggleLiveCaptions: "Toggle live captions"
        case .toggleMeetingCapture: "Start / stop meeting capture"
        case .bookmarkMoment: "Bookmark this moment"
        case .toggleOverlayClickThrough: "Overlay click-through"
        case .find: "Find in transcript"
        case .findAndReplace: "Find and replace"
        case .quickOpen: "Quick open"
        case .exportTranscript: "Export transcript"
        }
    }
}

/// `NSEvent.ModifierFlags`-compatible bit masks used by `KeyCombo.modifiers`.
public enum ModifierMask {
    public static let shift = 1 << 17
    public static let control = 1 << 18
    public static let option = 1 << 19
    public static let command = 1 << 20
    public static let all = shift | control | option | command
}

/// Settings → Keyboard Shortcuts: record, change, clear, and warn on conflicts (SET-AC-16).
@MainActor @Observable
public final class ShortcutsModel {
    public private(set) var combos: [ShortcutAction: KeyCombo] = [:]
    /// A recording that conflicts with another action and awaits confirmation.
    public private(set) var pendingConflict: (action: ShortcutAction, combo: KeyCombo, conflictsWith: ShortcutAction?, reserved: Bool)?
    public var errorMessage: String?

    @ObservationIgnored private let store: any SettingsStore
    @ObservationIgnored private let hotkeys: (any HotkeyServicing)?
    @ObservationIgnored private var cleared: Set<ShortcutAction> = []

    public init(store: any SettingsStore, hotkeys: (any HotkeyServicing)?) {
        self.store = store
        self.hotkeys = hotkeys
    }

    public static func defaultCombo(for action: ShortcutAction) -> KeyCombo? {
        let hyper = ModifierMask.control | ModifierMask.option
        switch action {
        case .dictation: return KeyCombo(keyCode: 49, modifiers: ModifierMask.option)  // ⌥Space
        case .toggleLiveCaptions: return KeyCombo(keyCode: 37, modifiers: hyper)  // ⌃⌥L
        case .toggleMeetingCapture: return KeyCombo(keyCode: 46, modifiers: hyper)  // ⌃⌥M
        case .bookmarkMoment: return KeyCombo(keyCode: 11, modifiers: hyper)  // ⌃⌥B
        case .toggleOverlayClickThrough: return KeyCombo(keyCode: 8, modifiers: hyper)  // ⌃⌥C
        case .find: return KeyCombo(keyCode: 3, modifiers: ModifierMask.command)  // ⌘F
        case .findAndReplace: return KeyCombo(keyCode: 3, modifiers: ModifierMask.command | ModifierMask.option)  // ⌥⌘F
        case .quickOpen: return KeyCombo(keyCode: 35, modifiers: ModifierMask.command)  // ⌘P
        case .exportTranscript: return KeyCombo(keyCode: 14, modifiers: ModifierMask.command | ModifierMask.shift)  // ⇧⌘E
        }
    }

    /// Combos the system reserves; recording one asks for confirmation.
    static let reserved: [KeyCombo: String] = [
        KeyCombo(keyCode: 12, modifiers: ModifierMask.command): "Quit",
        KeyCombo(keyCode: 48, modifiers: ModifierMask.command): "App switcher",
        KeyCombo(keyCode: 49, modifiers: ModifierMask.command): "Spotlight",
        KeyCombo(keyCode: 4, modifiers: ModifierMask.command): "Hide",
    ]

    public func load() async {
        for action in ShortcutAction.allCases {
            let key = SettingsKey.shortcut(action.rawValue)
            if let stored = await store.value(for: key, as: KeyCombo.self) {
                combos[action] = stored
            } else if await store.value(for: key + ".cleared", as: Bool.self) == true {
                cleared.insert(action)
            } else {
                combos[action] = Self.defaultCombo(for: action)
            }
        }
    }

    public func combo(for action: ShortcutAction) -> KeyCombo? { combos[action] }

    public func conflict(for combo: KeyCombo, excluding action: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0 != action && combos[$0] == combo }
    }

    /// Records `combo` for `action`. Returns `true` when applied; conflicts are parked in `pendingConflict` for confirmation.
    @discardableResult
    public func record(_ combo: KeyCombo, for action: ShortcutAction) async -> Bool {
        errorMessage = nil
        guard combo.modifiers & ModifierMask.all != 0 || Self.isFunctionKey(combo.keyCode) else {
            errorMessage = "Include at least one modifier key (⌘, ⌥, ⌃ or ⇧)."
            return false
        }
        let other = conflict(for: combo, excluding: action)
        let reservedName = Self.reserved[combo]
        if other != nil || reservedName != nil {
            pendingConflict = (action, combo, other, reservedName != nil)
            return false
        }
        await apply(combo, for: action)
        return true
    }

    /// Applies a parked conflicting recording, clearing the shortcut it conflicts with.
    public func confirmConflict() async {
        guard let pending = pendingConflict else { return }
        pendingConflict = nil
        if let other = pending.conflictsWith { await clear(other) }
        await apply(pending.combo, for: pending.action)
    }

    public func cancelConflict() { pendingConflict = nil }

    public func clear(_ action: ShortcutAction) async {
        combos[action] = nil
        cleared.insert(action)
        await store.set(true, for: SettingsKey.shortcut(action.rawValue) + ".cleared")
        if let hotkey = action.hotkeyAction { await hotkeys?.unregister(hotkey) }
    }

    public func resetToDefault(_ action: ShortcutAction) async {
        if let combo = Self.defaultCombo(for: action) {
            await apply(combo, for: action)
        } else {
            await clear(action)
        }
    }

    private func apply(_ combo: KeyCombo, for action: ShortcutAction) async {
        combos[action] = combo
        cleared.remove(action)
        await store.set(combo, for: SettingsKey.shortcut(action.rawValue))
        await store.set(false, for: SettingsKey.shortcut(action.rawValue) + ".cleared")
    }

    static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111].contains(keyCode)
    }

    /// Human-readable form such as `⌃⌥L`.
    public static func display(_ combo: KeyCombo) -> String {
        var text = ""
        if combo.modifiers & ModifierMask.control != 0 { text += "⌃" }
        if combo.modifiers & ModifierMask.option != 0 { text += "⌥" }
        if combo.modifiers & ModifierMask.shift != 0 { text += "⇧" }
        if combo.modifiers & ModifierMask.command != 0 { text += "⌘" }
        return text + (keyNames[combo.keyCode] ?? "Key \(combo.keyCode)")
    }

    static let keyNames: [UInt16: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N",
        31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11",
        111: "F12",
    ]
}
