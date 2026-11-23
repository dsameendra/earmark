import AppCore
import DesignSystem
import FeatureSupport
import Foundation
import Observation
import SwiftUI

/// How the Re-transcribe popover picks its language(s).
public enum RerunLanguageKind: String, CaseIterable, Identifiable, Sendable {
    case single, autoDetect, multilingual
    public var id: String { rawValue }
    var title: String {
        switch self {
        case .single: "One language"
        case .autoDetect: "Detect automatically"
        case .multilingual: "Several languages"
        }
    }
}

/// Logic behind the editor's Re-transcribe popover (SCR-013): scope, language(s), model with greyed-out unsupported options,
/// "Identify speakers again" with an expected count, and the non-destructive default with a "Replace everything" choice.
@MainActor @Observable
public final class RerunPanelModel {
    public var scope: RerunRequest.Scope = .wholeTranscript
    public private(set) var kind: RerunLanguageKind = .autoDetect
    public private(set) var singleLanguage: LanguageCode = .english
    public private(set) var multiLanguages: Set<LanguageCode> = []
    public private(set) var modelID: ModelID?
    public var transcribe = true
    public var identifySpeakers = false
    public var speakerCount: SpeakerCount = .auto
    public var replaceEverything = false
    public var voiceProcessing: VoiceProcessingLevel = .off
    public private(set) var catalog: [ModelDescriptor] = []
    public private(set) var installed: Set<ModelID> = []
    /// Languages used recently for files, most recent first (offered first in the language list).
    public private(set) var recentLanguages: [LanguageCode] = []

    @ObservationIgnored private let editor: TranscriptEditorModel

    public init(editor: TranscriptEditorModel) {
        self.editor = editor
        let languages = editor.transcript?.languages ?? []
        if languages.count == 1, let only = languages.first {
            kind = .single
            singleLanguage = only
        } else if languages.count > 1 {
            kind = .multilingual
            multiLanguages = languages
        }
        if !editor.selection.isEmpty { scope = .selection }
    }

    public func prepare() async {
        voiceProcessing = await FileJobSettings.voiceProcessing(in: editor.settings)
        guard let models = editor.models else { return }
        catalog = await models.catalog()
        installed = await models.installedModels()
        recentLanguages = await FileJobSettings.recentLanguages(in: editor.settings)
    }

    public var selectionCount: Int { editor.selection.count }
    public var tier: HardwareTier { editor.hardware?.profile.tier ?? .tier16 }

    public var languageMode: LanguageMode {
        switch kind {
        case .single: .single(singleLanguage)
        case .autoDetect: .autoDetect
        case .multilingual: .multilingual(multiLanguages)
        }
    }

    public var languageOptions: [LanguageCode] {
        Set(LanguageCapabilityTable(models: catalog).languages()).union([singleLanguage]).union(multiLanguages).sorted()
    }

    /// The shared "Several languages" list: recents and the Mac's languages first; languages the chosen model cannot handle greyed out.
    public var languageSelector: LanguageSelectorModel {
        let options = languageOptions
        let chosen = catalog.first { $0.id == modelID }
        return LanguageSelectorModel(
            options: options, recents: recentLanguages, suggested: LanguageSelectorModel.suggestions(from: options),
            unsupportedReasons: LanguageSelectorModel.unsupportedReasons(for: chosen, options: options))
    }

    public func clearLanguages() { multiLanguages = [] }

    public var modelRows: [ModelChoiceRow] {
        ModelChoices.rows(catalog: catalog, installed: installed, mode: languageMode, tier: tier)
    }

    public var recommendedModel: ModelDescriptor? { ModelChoices.recommended(for: languageMode, tier: tier, catalog: catalog) }

    public func setKind(_ newKind: RerunLanguageKind) {
        kind = newKind
        if newKind == .multilingual, multiLanguages.isEmpty { multiLanguages = [singleLanguage] }
        reconcileModel()
    }

    public func setSingleLanguage(_ code: LanguageCode) {
        singleLanguage = code
        reconcileModel()
    }

    public func toggleLanguage(_ code: LanguageCode) {
        if multiLanguages.contains(code) { multiLanguages.remove(code) } else { multiLanguages.insert(code) }
        reconcileModel()
    }

    public func selectModel(_ id: ModelID?) { modelID = id }

    /// A model that no longer suits the chosen languages falls back to Automatic.
    private func reconcileModel() {
        if let id = modelID, !(modelRows.first { $0.id == id }?.isEnabled ?? false) { modelID = nil }
    }

    public var request: RerunRequest {
        RerunRequest(
            scope: scope, languageMode: languageMode, modelID: modelID, transcribe: transcribe,
            identifySpeakers: identifySpeakers, speakerCount: speakerCount, replaceEverything: replaceEverything && transcribe,
            voiceProcessing: voiceProcessing)
    }

    public var canStart: Bool { editor.canRerun && startBlockedReason == nil }

    /// Why Start is disabled, in words; nil when it is enabled.
    public var startBlockedReason: String? {
        if editor.mediaURL == nil { return "The media file is missing, so there is nothing to re-transcribe. Relink it first." }
        if editor.jobQueue == nil { return "Re-transcribing is unavailable right now." }
        if let locked = editor.lockedHelp { return locked }
        if editor.isReadOnly && !editor.isRerunning { return "The transcript is read-only." }
        if !transcribe && !identifySpeakers { return "Choose to re-transcribe the speech, identify speakers, or both." }
        if scope == .selection && selectionCount == 0 { return "Select some segments in the transcript, or switch to the whole transcript." }
        if kind == .multilingual && multiLanguages.isEmpty && transcribe { return "Choose at least one language." }
        return nil
    }

    /// `true` when starting needs the "Replace everything" confirmation.
    public var needsReplaceConfirmation: Bool { transcribe && replaceEverything }

    public func start() async { await editor.rerun(request) }
}

/// The Editor toolbar's Re-transcribe control.
struct RerunPanel: View {
    let model: TranscriptEditorModel
    @State private var panel: RerunPanelModel
    @State private var confirmsReplace = false

    init(model: TranscriptEditorModel) {
        self.model = model
        _panel = State(initialValue: RerunPanelModel(editor: model))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            Text("Re-transcribe").font(DSTypography.headline)
            if model.isRerunning {
                runningRow
            } else {
                controls
            }
            if let status = model.rerunStatus {
                Label(status, systemImage: "info.circle").font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                    .accessibilityIdentifier("editor.rerun.status")
            }
            Divider()
            transcriptLanguageSection
        }
        .padding(DSSpacing.lg)
        .frame(minWidth: LanguageSelectorLayout.minPopoverWidth, idealWidth: 400)
        .task { await panel.prepare() }
    }

    private var runningRow: some View {
        HStack {
            ProgressView(value: model.rerunJob?.progress ?? 0).frame(maxWidth: .infinity)
            Button("Cancel") { Task { await model.cancelRerun() } }.accessibilityIdentifier("editor.rerun.cancel")
        }
    }

    @ViewBuilder private var controls: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            SectionCaption("What to redo")
            Picker("Scope", selection: $panel.scope) {
                Text("Whole transcript").tag(RerunRequest.Scope.wholeTranscript)
                Text(panel.selectionCount == 0 ? "Selected segments (none selected)" : "Selected segments (\(panel.selectionCount))")
                    .tag(RerunRequest.Scope.selection)
            }
            .pickerStyle(.radioGroup).labelsHidden()
            .accessibilityIdentifier("editor.rerun.scope")
            Toggle("Re-transcribe the speech", isOn: $panel.transcribe).accessibilityIdentifier("editor.rerun.transcribe")
        }
        if panel.transcribe {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                SectionCaption("Language")
                Picker("Language mode", selection: Binding(get: { panel.kind }, set: { panel.setKind($0) })) {
                    ForEach(RerunLanguageKind.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().accessibilityIdentifier("editor.rerun.languageMode")
                switch panel.kind {
                case .single:
                    Picker("Language", selection: Binding(get: { panel.singleLanguage }, set: { panel.setSingleLanguage($0) })) {
                        ForEach(panel.languageOptions, id: \.self) { Text(TranscriptEditorModel.name(of: $0)).tag($0) }
                    }
                    .accessibilityIdentifier("editor.rerun.language")
                case .autoDetect: EmptyView()
                case .multilingual:
                    LanguageMultiSelectView(
                        selector: panel.languageSelector, selection: panel.multiLanguages, idPrefix: "editor.rerun.languages",
                        onToggle: { panel.toggleLanguage($0) }, onClear: { panel.clearLanguages() })
                }
            }
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                SectionCaption("Model")
                modelMenu
                if let reason = panel.modelRows.first(where: { $0.id == panel.modelID })?.disabledReason {
                    Text(reason).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                }
            }
        }
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            SectionCaption("Speakers")
            Toggle("Identify speakers again", isOn: $panel.identifySpeakers).accessibilityIdentifier("editor.rerun.identifySpeakers")
            if panel.identifySpeakers {
                Picker("Expected speakers", selection: $panel.speakerCount) {
                    ForEach(SpeakerCount.choices, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("editor.rerun.speakerCount")
                Text("Existing speaker names are kept where the same voice is found.")
                    .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
            }
        }
        if panel.transcribe {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Toggle("Replace everything", isOn: $panel.replaceEverything).accessibilityIdentifier("editor.rerun.replaceEverything")
                Text(
                    panel.replaceEverything
                        ? "Your edits, ignore choices and speaker names will be discarded."
                        : "Your edits, ignore choices and speaker names are kept.")
                    .font(DSTypography.caption)
                    .foregroundStyle(panel.replaceEverything ? DSColor.danger : DSColor.secondaryText)
            }
        }
        if panel.transcribe {
            Picker("Voice processing", selection: $panel.voiceProcessing) {
                ForEach(VoiceProcessingLevel.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("editor.rerun.voiceProcessing")
            .help(VoiceProcessingText.explanation)
        }
        if let reason = panel.startBlockedReason {
            Text(reason).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                .accessibilityIdentifier("editor.rerun.blockedReason")
        }
        HStack {
            Spacer()
            Button(panel.needsReplaceConfirmation ? "Replace Everything…" : "Start") {
                if panel.needsReplaceConfirmation { confirmsReplace = true } else { Task { await panel.start() } }
            }
            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            .disabled(!panel.canStart)
            .accessibilityIdentifier("editor.rerun.start")
            .confirmationDialog("Replace everything?", isPresented: $confirmsReplace) {
                Button("Replace Everything", role: .destructive) { Task { await panel.start() } }
            } message: {
                Text("The whole transcript is rebuilt. Edits, ignore choices and speaker names are lost, and this cannot be undone.")
            }
        }
    }

    private var modelMenu: some View {
        Menu {
            Button { panel.selectModel(nil) } label: {
                Text(panel.recommendedModel.map { "Automatic (Recommended: \($0.displayName))" } ?? "Automatic")
            }
            Divider()
            ForEach(panel.modelRows) { row in
                Button { panel.selectModel(row.id) } label: { Text(Self.title(of: row)) }
                    .disabled(!row.isEnabled)
            }
        } label: {
            Text(panel.modelRows.first { $0.id == panel.modelID }?.descriptor.displayName ?? "Automatic")
        }
        .menuStyle(.button).fixedSize()
        .accessibilityIdentifier("editor.rerun.model")
    }

    static func title(of row: ModelChoiceRow) -> String {
        if let reason = row.disabledReason { return "\(row.descriptor.displayName): \(reason)" }
        var title = row.descriptor.displayName
        if row.isRecommended { title += " (Recommended)" }
        if !row.isInstalled { title += ", download" }
        return title
    }

    /// "Set transcript language": says which language the transcript is in without running recognition.
    private var transcriptLanguageSection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            SectionCaption("Transcript language")
            let current = (model.transcript?.languages ?? []).sorted().map { TranscriptEditorModel.name(of: $0) }.joined(separator: ", ")
            Text(current.isEmpty ? "Not set" : current).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
            Menu("Set Transcript Language") {
                ForEach(panel.languageOptions, id: \.self) { code in
                    Button(TranscriptEditorModel.name(of: code)) { model.setTranscriptLanguages([code]) }
                }
            }
            .menuStyle(.button).fixedSize()
            .disabled(model.isReadOnly)
            .accessibilityIdentifier("editor.rerun.setLanguage")
        }
    }
}
