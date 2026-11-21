/// `SettingsStore` keys shared by the shell, menu bar and Settings scene.
public enum SettingsKey {
    /// `String` raw value of the last selected sidebar section (NAV-AC-15).
    public static let lastSection = "ui.lastSection"
    /// `Bool`; Dock icon visible (default `true`, MENU-AC-08).
    public static let showDockIcon = "general.showDockIcon"
    /// `Bool`; keep running in the menu bar after the main window closes (NAV-AC-16).
    public static let keepRunning = "general.keepRunning"
    /// `LanguageMode`; default for the next session (MENU-AC-09).
    public static let languageMode = "defaults.languageMode"
    /// `String`; chosen input device UID (absent means system default).
    public static let inputDeviceUID = "audio.inputDeviceUID"
    /// `Bool`; auto-record meetings.
    public static let autoRecord = "meetings.autoRecord"
    /// `String` ("grid" or "list"); Library layout (LIB-AC-04).
    public static let libraryLayout = "library.layout"
    /// `Int`; days soft-deleted items are kept before auto-purge (LIB-AC-08). 0 means never.
    public static let libraryRetentionDays = "library.retentionDays"
    /// `[LibraryFolder]`; Library folder names (folders have no repository, only `Transcript.folderID`).
    public static let libraryFolders = "library.folders"
    /// `Int`; maximum parallel jobs (FILE-AC-07).
    public static let queueMaxConcurrency = "queue.maxConcurrency"
}
