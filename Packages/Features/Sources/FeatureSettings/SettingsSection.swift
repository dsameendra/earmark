import DesignSystem
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

    /// Duotone symbol where the `Icons` board covers the section; nil sections keep their stock `systemImage`.
    public var symbol: DSSymbol? {
        switch self {
        case .general: .settings
        case .models: .models
        case .languages: .language
        case .audio: .systemAudio
        case .meetings: .meetings
        case .liveCaptions: .liveCaptions
        case .dictation: .dictation
        case .ignoredSegments: .hidden
        case .translation: .translate
        case .exportDefaults: .export
        case .transcriptAppearance, .replacements, .storage, .keyboardShortcuts, .privacyPermissions: nil
        }
    }

    public var systemImage: String {
        switch self {
        case .general: DSSymbol.settings.systemImageName
        case .models: DSSymbol.models.systemImageName
        case .languages: DSSymbol.language.systemImageName
        case .audio: DSSymbol.systemAudio.systemImageName
        case .meetings: DSSymbol.meetings.systemImageName
        case .liveCaptions: DSSymbol.liveCaptions.systemImageName
        case .dictation: DSSymbol.dictation.systemImageName
        case .transcriptAppearance: "textformat"
        case .ignoredSegments: DSSymbol.hidden.systemImageName
        case .replacements: "arrow.left.arrow.right"
        case .translation: DSSymbol.translate.systemImageName
        case .exportDefaults: DSSymbol.export.systemImageName
        case .storage: "internaldrive"
        case .keyboardShortcuts: "keyboard"
        case .privacyPermissions: "hand.raised"
        }
    }
}

/// Readable groups shared by Settings navigation and its coverage checks.
public enum SettingsSectionGroup: String, CaseIterable, Identifiable, Sendable {
    case app, capture, transcripts, system
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .app: "Earmark"
        case .capture: "Capture"
        case .transcripts: "Transcripts"
        case .system: "System"
        }
    }
    public var sections: [SettingsSection] {
        switch self {
        case .app: [.general, .models, .languages, .audio]
        case .capture: [.meetings, .liveCaptions, .dictation]
        case .transcripts: [.transcriptAppearance, .ignoredSegments, .replacements, .translation, .exportDefaults]
        case .system: [.storage, .keyboardShortcuts, .privacyPermissions]
        }
    }
}

extension SettingsSection {
    /// Explains the selected pane rather than repeating the same generic save notice everywhere.
    public var summary: String {
        switch self {
        case .general: "Make Earmark feel at home on your Mac. Changes are saved automatically."
        case .models: "Choose the local engines you need. Models download only when you ask."
        case .languages: "Choose your languages and the models that understand them."
        case .audio: "Choose microphones, test input and set the source for each kind of capture."
        case .meetings: "Decide what happens when a meeting starts. Ask first is the default."
        case .liveCaptions: "Shape the captions and overlay that follow your conversations."
        case .dictation: "Speak where you type, with controls that fit your workflow."
        case .transcriptAppearance: "Make transcripts comfortable to read and easy to follow."
        case .ignoredSegments: "Keep unwanted segments out of view without deleting the original words."
        case .replacements: "Correct familiar words and phrases consistently."
        case .translation: "Choose how local translation handles your transcripts."
        case .exportDefaults: "Keep your preferred document and subtitle settings close at hand."
        case .storage: "Manage what Earmark keeps on this Mac."
        case .keyboardShortcuts: "Move through Earmark and capture audio from the keyboard."
        case .privacyPermissions: "Grant access when you need it. Your recordings and transcripts stay on this Mac."
        }
    }
}
