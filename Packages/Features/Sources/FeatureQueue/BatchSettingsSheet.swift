import AppCore
import DesignSystem
import FeatureSupport
import SwiftUI

/// The compact "Transcribe" sheet shown before files are enqueued (SCR-013): language(s), model (unsupported ones greyed out with
/// a reason), speaker identification with an expected count, translation and auto-export.
public struct BatchSettingsSheet: View {
    @Bindable var model: BatchSettingsModel
    let onCancel: () -> Void
    let onAdd: () -> Void

    public init(model: BatchSettingsModel, onCancel: @escaping () -> Void, onAdd: @escaping () -> Void) {
        self.model = model
        self.onCancel = onCancel
        self.onAdd = onAdd
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Transcribe").font(DSTypography.title).padding(DSSpacing.lg).accessibilityAddTraits(.isHeader)
            Form {
                Section("Files") {
                    Text(summary)
                    if !model.duplicates.isEmpty {
                        Toggle("Skip \(model.duplicates.count) already in the queue", isOn: $model.skipDuplicates)
                    }
                }
                languageSection
                modelSection
                speakersSection
                voiceProcessingSection
                Section("Options") {
                    Picker("Translate to", selection: $model.translateTo) {
                        Text("None").tag(LanguageCode?.none)
                        ForEach(model.translationOptions, id: \.self) { Text(Self.name(of: $0)).tag(LanguageCode?.some($0)) }
                    }
                    Picker("Auto-export", selection: $model.autoExportPresetID) {
                        Text("Off").tag(PresetID?.none)
                        ForEach(model.presets) { Text($0.name).tag(PresetID?.some($0.id)) }
                    }
                    Toggle("Copy into library", isOn: $model.copyIntoLibrary)
                        .accessibilityIdentifier("batch.copyIntoLibrary")
                    Text(
                        model.copyIntoLibrary
                            ? "Each file is copied into the library and stays playable if the original moves."
                            : "Files stay where they are; Earmark remembers their location."
                    )
                    .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                }
                perFileSection
                if let message = model.errorMessage {
                    Text(message).foregroundStyle(DSColor.danger)
                }
            }
            .formStyle(.grouped)
            if let reason = model.submitBlockReason {
                Text(reason).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, DSSpacing.lg)
                    .accessibilityIdentifier("batch.blockReason")
            }
            HStack {
                Toggle("Don't ask again, use these settings", isOn: $model.dontAskAgain)
                    .toggleStyle(.checkbox)
                    .help("Add files straight away next time. Turn this back on in Settings > General.")
                    .accessibilityIdentifier("batch.dontAskAgain")
                Spacer()
                Button("Cancel", role: .cancel) {
                    Task { await model.cancelDownloads() }
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("batch.cancel")
                Button("Transcribe", action: onAdd)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canSubmit)
                    .help(model.submitBlockReason ?? "Add the files to the queue")
                    .accessibilityIdentifier("batch.add")
            }
            .padding(DSSpacing.lg)
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 480, idealHeight: 640, maxHeight: 760)
        .task { await model.prepare() }
        // Esc or a click outside also dismisses the sheet: an unfinished download started here is not wanted then.
        .onDisappear { Task { await model.cancelDownloads() } }
    }

    /// FILE-AC-04: any file or folder can deviate from the batch settings.
    private var perFileSection: some View {
        Section("Per-file settings") {
            DisclosureGroup("Customize individual files") {
                ScrollView {
                    VStack(alignment: .leading, spacing: DSSpacing.sm) {
                        ForEach(Array(model.urls.enumerated()), id: \.offset) { index, url in
                            PerFileRow(model: model, url: url, index: index)
                        }
                    }
                }
                .frame(minHeight: 80, idealHeight: 140, maxHeight: 220)
            }
            .accessibilityIdentifier("batch.perFile")
            if !model.overrides.isEmpty {
                Button("Reset all per-file settings") { model.clearAllOverrides() }
                    .accessibilityIdentifier("batch.perFile.resetAll")
            }
        }
    }

    private var summary: String {
        let count = model.urls.count
        let first = model.urls.first?.lastPathComponent ?? ""
        return count == 1 ? first : "\(first) and \(count - 1) more (folders are scanned for media files)"
    }

    private var languageSection: some View {
        Section("Language") {
            Picker(
                "Language mode",
                selection: Binding(get: { model.kind }, set: { model.setKind($0) })
            ) {
                ForEach(LanguageModeKind.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("batch.languageMode")
            switch model.kind {
            case .single:
                Picker(
                    "Language",
                    selection: Binding(get: { model.singleLanguage }, set: { model.setSingleLanguage($0) })
                ) {
                    ForEach(model.recentFirstLanguageOptions, id: \.self) { Text(Self.name(of: $0)).tag($0) }
                }
                .accessibilityIdentifier("batch.language")
            case .autoDetect:
                Text("The language is detected from the first 30 seconds.").font(DSTypography.caption).foregroundStyle(
                    DSColor.secondaryText)
            case .multilingual:
                LanguageMultiSelectView(
                    selector: model.languageSelector, selection: model.multiLanguages, idPrefix: "batch.languages",
                    onToggle: { model.toggleLanguage($0) }, onClear: { model.clearLanguages() })
            }
        }
    }

    /// Every runnable model; the ones that cannot handle the chosen language(s) are greyed out and say why.
    private var modelSection: some View {
        Section("Model") {
            LabeledContent("Model") {
                Menu {
                    Button { Task { await model.selectModel(nil) } } label: {
                        Label(automaticTitle, systemImage: model.modelID == nil ? "checkmark" : "sparkles")
                    }
                    Divider()
                    ForEach(model.modelRows) { row in
                        Button { Task { await model.selectModel(row.id) } } label: {
                            if model.modelID == row.id {
                                Label(Self.title(of: row), systemImage: "checkmark")
                            } else {
                                Text(Self.title(of: row))
                            }
                        }
                        .disabled(!row.isEnabled)
                    }
                } label: {
                    Text(currentModelTitle)
                }
                .menuStyle(.button)
                .fixedSize()
                .accessibilityIdentifier("batch.model")
            }
            if let reason = selectedRowReason {
                Text(reason).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
            }
            switch model.download {
            case .idle: EmptyView()
            case .downloading(let id, let fraction, let verifying):
                ProgressRow(
                    title: "Downloading \(model.catalog.first { $0.id == id }?.displayName ?? id.rawValue)",
                    detail: verifying ? "Verifying" : nil, fraction: fraction)
                if !verifying {
                    Button("Cancel Download") { Task { await model.cancelDownloads() } }
                        .accessibilityIdentifier("batch.model.cancelDownload")
                }
            case .failed(let id, let reason):
                Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(DSColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { Task { await model.selectModel(id) } }
                    .accessibilityIdentifier("batch.model.retry")
            }
        }
    }

    private var automaticTitle: String {
        model.recommendedModel.map { "Automatic (Recommended: \($0.displayName))" } ?? "Automatic"
    }

    private var currentModelTitle: String {
        guard let id = model.modelID else { return automaticTitle }
        return model.catalog.first { $0.id == id }?.displayName ?? id.rawValue
    }

    private var selectedRowReason: String? { model.modelRows.first { $0.id == model.modelID }?.disabledReason }

    /// "Whisper small, 216 MB (download)", "Qwen3 ASR, Recommended", or "Whisper small: No Sinhala support" when greyed out.
    static func title(of row: ModelChoiceRow) -> String {
        var title = row.descriptor.displayName
        if let reason = row.disabledReason { return "\(title): \(reason)" }
        if row.isRecommended { title += " (Recommended)" }
        if !row.isInstalled { title += ", \(ByteCountFormatter.string(fromByteCount: row.descriptor.sizeBytes, countStyle: .file)) download" }
        return title
    }

    /// "Identify speakers" with an expected count; offers to download the speaker model when it is missing.
    private var speakersSection: some View {
        Section("Speakers") {
            Toggle("Identify speakers", isOn: $model.diarize)
                .accessibilityIdentifier("batch.diarize")
            if model.diarize {
                Picker("Expected speakers", selection: $model.speakerCount) {
                    ForEach(SpeakerCount.choices, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("batch.speakerCount")
                if model.needsSpeakerModel { speakerModelRow }
            }
        }
    }

    /// SCR-014: offline noise reduction and level evening before transcribing.
    private var voiceProcessingSection: some View {
        Section("Voice processing") {
            Toggle("Voice processing", isOn: $model.voiceProcessingEnabled)
                .accessibilityIdentifier("batch.voiceProcessing")
            if model.voiceProcessingEnabled {
                Picker("Level", selection: $model.voiceProcessing) {
                    ForEach(VoiceProcessingLevel.allCases.filter { $0 != .off }) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("batch.voiceProcessing.level")
            }
            Text(VoiceProcessingText.explanation).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
        }
    }

    @ViewBuilder private var speakerModelRow: some View {
        switch model.speakerDownload {
        case .downloading(_, let fraction, let verifying):
            ProgressRow(title: "Downloading the speaker model", detail: verifying ? "Verifying" : nil, fraction: fraction)
            if !verifying {
                Button("Cancel Download") { Task { await model.cancelDownloads() } }
                    .accessibilityIdentifier("batch.speakerModel.cancelDownload")
            }
        case .failed(_, let reason):
            Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(DSColor.danger)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try Again") { Task { await model.downloadSpeakerModel() } }
                .accessibilityIdentifier("batch.speakerModel.retry")
        case .idle:
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text("Identifying speakers needs a \(model.speakerModelSizeText) model that is not downloaded yet.")
                    .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                if let preflight = model.speakerModelPreflight, !preflight.issues.isEmpty {
                    ForEach(Array(preflight.issues.enumerated()), id: \.offset) { _, issue in
                        Text(issue.message).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                    }
                }
                Button("Download Speaker Model") { Task { await model.downloadSpeakerModel() } }
                    .accessibilityIdentifier("batch.speakerModel.download")
            }
        }
    }

    static func name(of code: LanguageCode) -> String {
        Locale.current.localizedString(forLanguageCode: code.rawValue) ?? code.rawValue
    }
}

/// One file in the per-file list with its override popover.
private struct PerFileRow: View {
    let model: BatchSettingsModel
    let url: URL
    let index: Int
    @State private var showEditor = false

    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
            Spacer()
            if model.hasOverride(url) { StatusPill("Custom", tone: .neutral) }
            Button("Customize…") { showEditor = true }
                .accessibilityIdentifier("batch.file.\(index).customize")
                .popover(isPresented: $showEditor, arrowEdge: .trailing) {
                    FileOverrideEditor(model: model, url: url, index: index)
                }
        }
    }
}

/// Edits one file's override; "Same as batch" leaves a value inherited.
private struct FileOverrideEditor: View {
    let model: BatchSettingsModel
    let url: URL
    let index: Int

    private static let inherit = "inherit"
    private static let auto = "auto"

    var body: some View {
        let current = model.override(for: url)
        Form {
            Section(url.lastPathComponent) {
                Picker("Language", selection: languageTag) {
                    Text("Same as batch").tag(Self.inherit)
                    Text("Detect automatically").tag(Self.auto)
                    ForEach(model.languageOptions, id: \.self) { Text(BatchSettingsSheet.name(of: $0)).tag($0.rawValue) }
                }
                .accessibilityIdentifier("batch.file.\(index).language")
                Picker("Model", selection: modelTag) {
                    Text("Same as batch").tag(Self.inherit)
                    Text("Auto").tag(Self.auto)
                    ForEach(model.availableModels(for: url)) { descriptor in
                        Text(model.isInstalled(descriptor.id) ? descriptor.displayName : "\(descriptor.displayName) (download)")
                            .tag(descriptor.id.rawValue)
                    }
                }
                .accessibilityIdentifier("batch.file.\(index).model")
                Picker("Identify speakers", selection: diarizeTag) {
                    Text("Same as batch").tag(Self.inherit)
                    Text("On").tag("on")
                    Text("Off").tag("off")
                }
                .accessibilityIdentifier("batch.file.\(index).diarize")
                Picker("Voice processing", selection: voiceTag) {
                    Text("Same as batch").tag(Self.inherit)
                    ForEach(VoiceProcessingLevel.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .accessibilityIdentifier("batch.file.\(index).voiceProcessing")
                Picker("Translate to", selection: translateTag) {
                    Text("Same as batch").tag(Self.inherit)
                    Text("None").tag(Self.auto)
                    ForEach(model.translationOptions, id: \.self) { Text(BatchSettingsSheet.name(of: $0)).tag($0.rawValue) }
                }
                .accessibilityIdentifier("batch.file.\(index).translate")
                Picker("Auto-export", selection: exportTag) {
                    Text("Same as batch").tag(Self.inherit)
                    Text("Off").tag(Self.auto)
                    ForEach(model.presets) { Text($0.name).tag($0.id.rawValue.uuidString) }
                }
                .accessibilityIdentifier("batch.file.\(index).export")
            }
            if !current.isEmpty {
                Button("Use batch settings") { model.clearOverride(for: url) }
                    .accessibilityIdentifier("batch.file.\(index).reset")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(minWidth: 380, idealWidth: 400)
        .fixedSize(horizontal: false, vertical: true)
        .padding(DSSpacing.sm)
    }

    private var languageTag: Binding<String> {
        Binding(
            get: {
                switch model.override(for: url).languageMode {
                case nil: Self.inherit
                case .autoDetect?: Self.auto
                case .single(let code)?: code.rawValue
                case .multilingual?: Self.inherit
                }
            },
            set: { tag in
                model.updateOverride(for: url) {
                    $0.languageMode = tag == Self.inherit ? nil : tag == Self.auto ? .autoDetect : .single(LanguageCode(tag))
                }
            })
    }

    private var modelTag: Binding<String> {
        Binding(
            get: {
                guard let choice = model.override(for: url).model else { return Self.inherit }
                return choice.value?.rawValue ?? Self.auto
            },
            set: { tag in
                model.updateOverride(for: url) {
                    $0.model = tag == Self.inherit ? nil : .init(tag == Self.auto ? nil : ModelID(tag))
                }
            })
    }

    private var diarizeTag: Binding<String> {
        Binding(
            get: { model.override(for: url).diarize.map { $0 ? "on" : "off" } ?? Self.inherit },
            set: { tag in model.updateOverride(for: url) { $0.diarize = tag == Self.inherit ? nil : tag == "on" } })
    }

    private var voiceTag: Binding<String> {
        Binding(
            get: { model.override(for: url).voiceProcessing?.rawValue ?? Self.inherit },
            set: { tag in
                model.updateOverride(for: url) { $0.voiceProcessing = tag == Self.inherit ? nil : VoiceProcessingLevel(storedValue: tag) }
            })
    }

    private var translateTag: Binding<String> {
        Binding(
            get: {
                guard let choice = model.override(for: url).translateTo else { return Self.inherit }
                return choice.value?.rawValue ?? Self.auto
            },
            set: { tag in
                model.updateOverride(for: url) {
                    $0.translateTo = tag == Self.inherit ? nil : .init(tag == Self.auto ? nil : LanguageCode(tag))
                }
            })
    }

    private var exportTag: Binding<String> {
        Binding(
            get: {
                guard let choice = model.override(for: url).autoExportPresetID else { return Self.inherit }
                return choice.value.map { $0.rawValue.uuidString } ?? Self.auto
            },
            set: { tag in
                model.updateOverride(for: url) {
                    if tag == Self.inherit {
                        $0.autoExportPresetID = nil
                    } else if tag == Self.auto {
                        $0.autoExportPresetID = .init(nil)
                    } else {
                        $0.autoExportPresetID = .init(model.presets.first { $0.id.rawValue.uuidString == tag }?.id)
                    }
                }
            })
    }
}

#Preview("Batch settings") {
    BatchSettingsSheet(
        model: BatchSettingsModel(urls: [URL(fileURLWithPath: "/tmp/a.m4a")], services: .preview()), onCancel: {}, onAdd: {})
}
