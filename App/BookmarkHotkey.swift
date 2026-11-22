import AppCore
import FeatureSettings
import FeatureSupport
import Foundation

/// Registers `HotkeyAction.bookmarkMoment` (default Control-Option-B, changeable in Settings > Shortcuts; a change applies at
/// the next launch) and adds a bookmark to the running capture on every press (MTG-AC-14). A registration failure (no
/// Input Monitoring or Accessibility permission) only disables the shortcut.
enum BookmarkHotkey {
    static func run(hotkeys: any HotkeyServicing, settings: any SettingsStore, bookmark: @escaping @Sendable () async -> Void) async {
        let key = SettingsKey.shortcut(HotkeyAction.bookmarkMoment.rawValue)
        let combo: KeyCombo
        if let stored = await settings.value(for: key, as: KeyCombo.self) {
            combo = stored
        } else if await settings.value(for: key + ".cleared", as: Bool.self) == true {
            return  // the user removed the shortcut
        } else if let fallback = await ShortcutsModel.defaultCombo(for: .bookmarkMoment) {
            combo = fallback
        } else {
            return
        }
        do {
            for await event in try await hotkeys.register(.bookmarkMoment, combo: combo) where event == .pressed { await bookmark() }
        } catch {
            AppLog.logger("meetings.hotkey").error("Bookmark hotkey not registered: \(String(describing: error), privacy: .public)")
        }
    }
}
