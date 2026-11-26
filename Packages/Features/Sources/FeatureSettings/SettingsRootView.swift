import AppCore
import DesignSystem
import FeatureSupport
import LiveCaptions
import Processing
import SwiftUI

/// All Settings models, built from the dependency bundle. Models load lazily when their section appears (SET open < 200 ms).
@MainActor
public final class SettingsEnvironment {
    public let checkForUpdates: (@MainActor @Sendable () -> Void)?
    public let automaticUpdateChecks: (@MainActor @Sendable () -> Bool)?
    public let setAutomaticUpdateChecks: (@MainActor @Sendable (Bool) -> Void)?
    public let general: GeneralSettingsModel
    public let modelManager: ModelManagerModel
    public let languages: LanguageSelectionModel
    public let audio: AudioSettingsModel
    public let meetings: MeetingsSettingsModel
    public let meetingDiagnostics: MeetingDiagnosticsModel
    public let captions: CaptionPresetsModel
    public let overlayPlacement: OverlayPlacementSettingsModel
    public let dictation: DictationSettingsModel
    public let appearance: AppearanceSettingsModel
    public let ignored: IgnoredSegmentsModel
    public let replacements: ReplacementsModel
    public let translation: TranslationSettingsModel
    public let exportDefaults: ExportDefaultsModel
    public let storage: StorageSettingsModel
    public let shortcuts: ShortcutsModel
    public let permissions: PermissionsSettingsModel
    public let voiceProfiles: VoiceProfilesModel

    /// IGN-AC-05: re-derives stored ignore flags with the current rules; absent without a transcript repository.
    static func rederiveAction(_ deps: SettingsDependencies) -> (@Sendable (IgnoreFilterSettings) async throws -> IgnoreRederiver.Summary)? {
        guard let transcripts = deps.transcripts else { return nil }
        let rules = deps.rules
        return { settings in
            let context = PostProcessingContext(
                ignoreRules: try await rules.ignoreRules(), applyReplacements: false,
                enableHallucinationFilter: settings.hallucinationFilter, lowConfidenceThreshold: settings.lowConfidence,
                noSpeechThreshold: settings.noSpeech)
            return try await IgnoreRederiver(transcripts: transcripts) { context }.run()
        }
    }

    public init(_ deps: SettingsDependencies) {
        checkForUpdates = deps.checkForUpdates
        automaticUpdateChecks = deps.automaticUpdateChecks
        setAutomaticUpdateChecks = deps.setAutomaticUpdateChecks
        general = GeneralSettingsModel(store: deps.store, loginItem: deps.launchAtLogin)
        modelManager = ModelManagerModel(
            manager: deps.models, hardware: deps.hardware, store: deps.store,
            reviewedHuggingFaceModels: deps.reviewedHuggingFaceModels)
        languages = LanguageSelectionModel(manager: modelManager, store: deps.store)
        audio = AudioSettingsModel(
            provider: deps.audioDevices, store: deps.store, microphonePreview: deps.microphonePreview,
            microphoneSettingsURL: deps.permissions.settingsURL(for: .microphone), sourceErrors: deps.microphonePreviewErrors,
            permissions: deps.permissions)
        meetings = MeetingsSettingsModel(store: deps.store)
        meetingDiagnostics = MeetingDiagnosticsModel(source: deps.meetingDiagnostics)
        captions = CaptionPresetsModel(repository: deps.presets, store: deps.store)
        let captionModel = captions
        overlayPlacement = OverlayPlacementSettingsModel(
            store: deps.store, displays: deps.displays ?? SystemDisplayProvider(), controller: deps.overlayPlacement,
            previewPreset: { captionModel.draft }, knownPresetIDs: { captionModel.presets.map(\.id) })
        dictation = DictationSettingsModel(store: deps.store, permissions: deps.permissions)
        appearance = AppearanceSettingsModel(store: deps.store)
        ignored = IgnoredSegmentsModel(
            repository: deps.rules, store: deps.store, rederive: Self.rederiveAction(deps))
        replacements = ReplacementsModel(repository: deps.rules, store: deps.store)
        translation = TranslationSettingsModel(store: deps.store, models: deps.models)
        exportDefaults = ExportDefaultsModel(repository: deps.presets, store: deps.store)
        storage = StorageSettingsModel(
            store: deps.store, models: deps.models, transcripts: deps.transcripts, purger: deps.mediaPurger, clearCaches: deps.clearCaches)
        shortcuts = ShortcutsModel(
            store: deps.store, hotkeys: deps.hotkeys, diagnostics: deps.hotkeyDiagnostics, retryRegistration: deps.retryHotkeys)
        permissions = PermissionsSettingsModel(service: deps.permissions)
        voiceProfiles = VoiceProfilesModel(repository: deps.voiceProfiles)
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

    @Namespace private var selectionSpace
    @FocusState private var focusedSection: SettingsSection?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityPolicyOverride) private var policyOverride

    private var motionReduced: Bool { policyOverride?.suppressesMotion ?? reduceMotion }

    public var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            GeometryReader { _ in
                Group {
                    VStack(alignment: .leading, spacing: DSSpacing.md) {
                        VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                            Text("earmark").font(DSTypography.title2)
                            Text("Settings").font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                        }
                        .padding(.horizontal, DSSpacing.lg).padding(.top, DSSpacing.lg)
                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(alignment: .leading, spacing: DSSpacing.lg) {
                                    ForEach(SettingsSectionGroup.allCases) { group in
                                        VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                                            SectionCaption(LocalizedStringKey(group.title)).padding(.horizontal, DSSpacing.sm)
                                                .padding(.bottom, DSSpacing.xs)
                                            ForEach(group.sections) { section in sectionButton(section).id(section) }
                                        }
                                    }
                                }
                                .padding(DSSpacing.md)
                            }
                            .scrollIndicators(.automatic)
                            // Minimal scroll (nil anchor): the list moves only when the selected item is off-screen, so
                            // clicking a visible item never jumps, while arrow keys can still reach every section.
                            .onChange(of: selection) { _, new in proxy.scrollTo(new, anchor: nil) }
                        }
                        .accessibilityIdentifier("settings.navigation")
                    }
                    .onKeyPress(.upArrow) {
                        moveSelection(by: -1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        moveSelection(by: 1)
                        return .handled
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .navigationSplitViewColumnWidth(238)
            .toolbar(removing: .sidebarToggle)  // also on the column: the outer modifier alone is ignored when the window reopens
            .accessibilityLabel("Settings navigation")
        } detail: {
            GeometryReader { _ in
                VStack(alignment: .leading, spacing: DSSpacing.lg) {
                    VStack(alignment: .leading, spacing: DSSpacing.xs) {
                        Text(selection.title).font(DSTypography.title1).accessibilityAddTraits(.isHeader)
                        Text(selection.summary).font(DSTypography.body).foregroundStyle(DSColor.secondaryText)
                    }
                    .padding(.horizontal, DSSpacing.lg).padding(.top, DSSpacing.lg)
                    detail
                        .scrollContentBackground(.hidden)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .id(selection)
                        .transition(.opacity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(DSColor.paper)
            }
        }
        .background(DSColor.paper)
        .navigationTitle("Settings")
        .toolbar(removing: .sidebarToggle)
        // The empty unified toolbar painted a white strip over the paper detail pane.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .dsIconContext(.sidebar)
        .dsAnimation(.glide, value: selection)
        .frame(minWidth: 900, minHeight: 620)
    }

    private func sectionButton(_ section: SettingsSection) -> some View {
        let selected = selection == section
        return Button {
            selection = section
            focusedSection = section
        } label: {
            HStack(spacing: DSSpacing.sm) {
                DSIcon(section.symbol, orStock: section.systemImage, style: selected ? .duotone : .monochrome)
                    .frame(width: 22)
                Text(section.title).font(DSTypography.body.weight(selected ? .semibold : .regular))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? DSColor.primaryText : DSColor.secondaryText)
            .padding(.horizontal, DSSpacing.sm).padding(.vertical, DSSpacing.sm)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .background {
                if selected {
                    if motionReduced {
                        RoundedRectangle(cornerRadius: DSRadius.medium).fill(DSColor.selectionPill)
                    } else {
                        RoundedRectangle(cornerRadius: DSRadius.medium).fill(DSColor.selectionPill)
                            .matchedGeometryEffect(id: "settings-selection", in: selectionSpace)
                    }
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: DSRadius.medium))
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focusedSection, equals: section)
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("settings.section.\(section.rawValue)")
    }

    private func moveSelection(by offset: Int) {
        let sections = SettingsSectionGroup.allCases.flatMap(\.sections)
        guard let index = sections.firstIndex(of: focusedSection ?? selection) else { return }
        let next = sections[max(0, min(sections.count - 1, index + offset))]
        selection = next
        focusedSection = next
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .general:
            GeneralSettingsView(
                model: environment.general, checkForUpdates: environment.checkForUpdates,
                automaticUpdateChecks: environment.automaticUpdateChecks, setAutomaticUpdateChecks: environment.setAutomaticUpdateChecks)
        case .models: ModelsSettingsView(model: environment.modelManager)
        case .languages: LanguagesSettingsView(model: environment.languages)
        case .audio: AudioSettingsView(model: environment.audio)
        case .meetings: MeetingsSettingsView(model: environment.meetings, diagnostics: environment.meetingDiagnostics)
        case .liveCaptions: LiveCaptionsSettingsView(model: environment.captions, placement: environment.overlayPlacement)
        case .dictation: DictationSettingsView(model: environment.dictation)
        case .transcriptAppearance: AppearanceSettingsView(model: environment.appearance)
        case .ignoredSegments: IgnoredSegmentsView(model: environment.ignored)
        case .replacements: ReplacementsView(model: environment.replacements)
        case .translation: TranslationSettingsView(model: environment.translation, models: environment.modelManager)
        case .exportDefaults: ExportDefaultsView(model: environment.exportDefaults)
        case .storage: StorageSettingsView(model: environment.storage)
        case .keyboardShortcuts: ShortcutsSettingsView(model: environment.shortcuts)
        case .privacyPermissions: PrivacySettingsView(model: environment.permissions, voiceProfiles: environment.voiceProfiles)
        }
    }
}

#Preview("Settings") { SettingsRootView(store: InMemorySettingsStore()) }
