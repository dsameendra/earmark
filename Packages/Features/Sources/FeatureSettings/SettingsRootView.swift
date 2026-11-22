import AppCore
import DesignSystem
import FeatureSupport
import SwiftUI

/// All Settings models, built from the dependency bundle. Models load lazily when their section appears (SET open < 200 ms).
@MainActor
public final class SettingsEnvironment {
    public let general: GeneralSettingsModel
    public let modelManager: ModelManagerModel
    public let languages: LanguageSelectionModel
    public let audio: AudioSettingsModel
    public let meetings: MeetingsSettingsModel
    public let captions: CaptionPresetsModel
    public let dictation: DictationSettingsModel
    public let appearance: AppearanceSettingsModel
    public let ignored: IgnoredSegmentsModel
    public let replacements: ReplacementsModel
    public let translation: TranslationSettingsModel
    public let exportDefaults: ExportDefaultsModel
    public let storage: StorageSettingsModel
    public let shortcuts: ShortcutsModel
    public let permissions: PermissionsSettingsModel

    public init(_ deps: SettingsDependencies) {
        general = GeneralSettingsModel(store: deps.store, loginItem: deps.launchAtLogin)
        modelManager = ModelManagerModel(manager: deps.models, hardware: deps.hardware, store: deps.store)
        languages = LanguageSelectionModel(manager: modelManager, store: deps.store)
        audio = AudioSettingsModel(provider: deps.audioDevices, store: deps.store)
        meetings = MeetingsSettingsModel(store: deps.store)
        captions = CaptionPresetsModel(repository: deps.presets, store: deps.store)
        dictation = DictationSettingsModel(store: deps.store)
        appearance = AppearanceSettingsModel(store: deps.store)
        ignored = IgnoredSegmentsModel(repository: deps.rules, store: deps.store)
        replacements = ReplacementsModel(repository: deps.rules, store: deps.store)
        translation = TranslationSettingsModel(store: deps.store)
        exportDefaults = ExportDefaultsModel(repository: deps.presets, store: deps.store)
        storage = StorageSettingsModel(
            store: deps.store, models: deps.models, transcripts: deps.transcripts, clearCaches: deps.clearCaches)
        shortcuts = ShortcutsModel(
            store: deps.store, hotkeys: deps.hotkeys, diagnostics: deps.hotkeyDiagnostics, retryRegistration: deps.retryHotkeys)
        permissions = PermissionsSettingsModel(service: deps.permissions)
    }
}

/// Content of the separate Settings scene: a section list with a detail pane (SET-AC-01).
public struct SettingsRootView: View {
    @State private var selection: SettingsSection = .general
    private let environment: SettingsEnvironment

    /// Full wiring from the composition root.
    public init(dependencies: SettingsDependencies) { environment = SettingsEnvironment(dependencies) }

    /// Store-only wiring: model, rule and permission sections use placeholders until the app supplies real services.
    public init(store: any SettingsStore) { environment = SettingsEnvironment(.standalone(store: store)) }

    private var sidebarSelection: Binding<SettingsSection?> {
        Binding(get: { selection }, set: { selection = $0 ?? selection })
    }

    public var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: sidebarSelection) { section in
                Label(section.title, systemImage: section.systemImage).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .accessibilityLabel("Settings sections")
        } detail: {
            detail.navigationTitle(selection.title)
        }
        .frame(minWidth: 760, minHeight: 480)
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .general: GeneralSettingsView(model: environment.general)
        case .models: ModelsSettingsView(model: environment.modelManager)
        case .languages: LanguagesSettingsView(model: environment.languages)
        case .audio: AudioSettingsView(model: environment.audio)
        case .meetings: MeetingsSettingsView(model: environment.meetings)
        case .liveCaptions: LiveCaptionsSettingsView(model: environment.captions)
        case .dictation: DictationSettingsView(model: environment.dictation)
        case .transcriptAppearance: AppearanceSettingsView(model: environment.appearance)
        case .ignoredSegments: IgnoredSegmentsView(model: environment.ignored)
        case .replacements: ReplacementsView(model: environment.replacements)
        case .translation: TranslationSettingsView(model: environment.translation, models: environment.modelManager)
        case .exportDefaults: ExportDefaultsView(model: environment.exportDefaults)
        case .storage: StorageSettingsView(model: environment.storage)
        case .keyboardShortcuts: ShortcutsSettingsView(model: environment.shortcuts)
        case .privacyPermissions: PrivacySettingsView(model: environment.permissions)
        }
    }
}

#Preview("Settings") { SettingsRootView(store: InMemorySettingsStore()) }
