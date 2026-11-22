import AppCore
import DesignSystem
import SwiftUI

/// Per-batch settings: language mode, model (filtered by language, inline download), diarization, translation, auto-export.
struct BatchSettingsSheet: View {
    @Bindable var model: BatchSettingsModel
    let onCancel: () -> Void
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add to Queue").font(DSTypography.title).padding(DSSpacing.lg).accessibilityAddTraits(.isHeader)
            Form {
                Section("Files") {
                    Text(summary)
                    if !model.duplicates.isEmpty {
                        Toggle("Skip \(model.duplicates.count) already in the queue", isOn: $model.skipDuplicates)
                    }
                }
                languageSection
                modelSection
                Section("Options") {
                    Toggle("Identify speakers", isOn: $model.diarize)
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
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Add to Queue", action: onAdd)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canSubmit)
            }
            .padding(DSSpacing.lg)
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 480)
        .task { await model.prepare() }
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
                .frame(maxHeight: 180)
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
            switch model.kind {
            case .single:
                Picker(
                    "Language",
                    selection: Binding(get: { model.singleLanguage }, set: { model.setSingleLanguage($0) })
                ) {
                    ForEach(model.languageOptions, id: \.self) { Text(Self.name(of: $0)).tag($0) }
                }
            case .autoDetect:
                Text("The language is detected from the first 30 seconds.").font(DSTypography.caption).foregroundStyle(
                    DSColor.secondaryText)
            case .multilingual:
                ForEach(model.languageOptions, id: \.self) { code in
                    Toggle(
                        Self.name(of: code),
                        isOn: Binding(get: { model.multiLanguages.contains(code) }, set: { _ in model.toggleLanguage(code) }))
                }
            }
        }
    }

    private var modelSection: some View {
        Section("Model") {
            Picker(
                "Model",
                selection: Binding<ModelID?>(
                    get: { model.modelID }, set: { newValue in Task { await model.selectModel(newValue) } })
            ) {
                Text("Auto").tag(ModelID?.none)
                ForEach(model.availableModels) { descriptor in
                    Text(model.isInstalled(descriptor.id) ? descriptor.displayName : "\(descriptor.displayName) (download)")
                        .tag(ModelID?.some(descriptor.id))
                }
            }
            switch model.download {
            case .idle: EmptyView()
            case .downloading(let id, let fraction, let verifying):
                ProgressRow(
                    title: "Downloading \(model.catalog.first { $0.id == id }?.displayName ?? id.rawValue)",
                    detail: verifying ? "Verifying" : nil, fraction: fraction)
            case .failed(_, let reason):
                Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(DSColor.danger)
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
        .frame(width: 340)
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
