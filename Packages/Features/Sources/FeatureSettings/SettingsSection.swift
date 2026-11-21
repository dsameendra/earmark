import Foundation

/// Sections of the Settings window (SET-AC-01). Only General is functional in the shell task.
public enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
    case general, models, languages, audio, meetings, liveCaptions, dictation, transcriptAppearance
    case ignoredSegments, replacements, translation, exportDefaults, storage, keyboardShortcuts, privacyPermissions

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general: "General"
        case .models: "Models"
        case .languages: "Languages"
        case .audio: "Audio"
        case .meetings: "Meetings"
        case .liveCaptions: "Live Captions"
        case .dictation: "Dictation"
        case .transcriptAppearance: "Transcript Appearance"
        case .ignoredSegments: "Ignored Segments"
        case .replacements: "Replacements"
        case .translation: "Translation"
        case .exportDefaults: "Export Defaults"
        case .storage: "Storage"
        case .keyboardShortcuts: "Keyboard Shortcuts"
        case .privacyPermissions: "Privacy & Permissions"
        }
    }

    public var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .models: "cpu"
        case .languages: "globe"
        case .audio: "speaker.wave.2"
        case .meetings: "person.2.wave.2"
        case .liveCaptions: "captions.bubble"
        case .dictation: "mic"
        case .transcriptAppearance: "textformat"
        case .ignoredSegments: "eye.slash"
        case .replacements: "arrow.left.arrow.right"
        case .translation: "character.bubble"
        case .exportDefaults: "square.and.arrow.up"
        case .storage: "internaldrive"
        case .keyboardShortcuts: "keyboard"
        case .privacyPermissions: "hand.raised"
        }
    }
}
