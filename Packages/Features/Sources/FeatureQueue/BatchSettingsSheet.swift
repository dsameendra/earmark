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
                }
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

#Preview("Batch settings") {
    BatchSettingsSheet(
        model: BatchSettingsModel(urls: [URL(fileURLWithPath: "/tmp/a.m4a")], services: .preview()), onCancel: {}, onAdd: {})
}
