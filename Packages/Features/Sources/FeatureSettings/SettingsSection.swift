import Foundation
import DesignSystem

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
