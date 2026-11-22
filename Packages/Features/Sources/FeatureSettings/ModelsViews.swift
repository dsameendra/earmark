import AppCore
import DesignSystem
import FeatureSupport
import SwiftUI
import UniformTypeIdentifiers

enum ModelFormat {
    static func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }

    static func warningText(_ warning: DownloadWarning) -> String {
        switch warning {
        case .nonCommercial(let spdx):
            "This model is licensed \(spdx), which does not allow commercial use. Use it only for personal or non-commercial work."
        case .hardwareTier:
            "This model is larger than this Mac is tuned for. It may run slowly or use a lot of memory."
        case .lowDiskSpace(let needed, let available):
            "Free disk space (\(bytes(available))) is low for a \(bytes(needed)) download."
        }
    }

    static func warningsMessage(_ warnings: [DownloadWarning]) -> String {
        warnings.map(warningText).joined(separator: "\n\n")
    }

    /// Licence chip text and tone; flags non-commercial and share-alike terms (SET-AC-03).
    static func licenseBadge(_ license: LicenseInfo) -> (text: String, tone: DSTone) {
        if license.isNonCommercial { return ("\(license.spdx) · non-commercial", .warning) }
        if license.spdx.uppercased().contains("-SA") { return ("\(license.spdx) · share-alike", .info) }
        return (license.spdx, .neutral)
    }
}

/// Language chips for a model (first few, then a "+N" overflow).
struct LanguageChips: View {
    let languages: Set<LanguageCode>
    var limit = 6

    var body: some View {
        let sorted = languages.sorted()
        HStack(spacing: DSSpacing.xs) {
            ForEach(sorted.prefix(limit), id: \.self) { LanguageBadge($0) }
            if sorted.count > limit {
                Text("+\(sorted.count - limit)").font(DSTypography.badge).foregroundStyle(DSColor.secondaryText)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Languages: \(sorted.map { LanguageSelectionModel.displayName($0) }.joined(separator: ", "))")
    }
}

struct ModelRowView: View {
    let row: ModelManagerModel.Row
    let isActive: Bool
    var recommendations: [ModelRecommendation] = []
    let onDownload: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void
    @State private var showsLanguages = false

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            HStack(alignment: .top, spacing: DSSpacing.md) {
                VStack(alignment: .leading, spacing: DSSpacing.xs) {
                    Text(row.descriptor.displayName).font(DSTypography.headline).fixedSize(horizontal: false, vertical: true)
                    if !row.descriptor.notes.isEmpty {
                        Text(row.descriptor.notes).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: DSSpacing.md)
                HStack(spacing: DSSpacing.sm) { actions }.fixedSize()
            }
            if isActive || row.descriptor.isCustom || !recommendations.isEmpty { badges }
            if let why = recommendations.first?.why {
                Text(why).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("models.recommendedWhy.\(row.id.rawValue)")
            }
            WrappingChips(spacing: DSSpacing.xs) {
                if row.descriptor.kind == .asr { languagesButton }
                ForEach(ModelCapabilitySummary.chips(for: row.descriptor).filter { $0.id != "languages" }) { CapabilityChipView($0) }
            }
            statusLine
        }
        .padding(.vertical, DSSpacing.sm)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("models.row.\(row.id.rawValue)")
    }

    private var badges: some View {
        WrappingChips(spacing: DSSpacing.xs) {
            ForEach(recommendations, id: \.useCase) { recommendation in
                StatusPill(LocalizedStringKey(recommendation.badgeText), systemImage: "star.fill", tone: .success)
                    .accessibilityIdentifier("models.recommended.\(row.id.rawValue).\(recommendation.useCase.rawValue)")
            }
            if isActive { StatusPill("Default", systemImage: "checkmark", tone: .success) }
            if row.descriptor.isCustom { StatusPill("Custom", tone: .info) }
        }
    }

    /// Languages as a chip that opens the full list (a long list never crowds the row).
    private var languagesButton: some View {
        let chip = ModelCapabilitySummary.chips(for: row.descriptor).first { $0.id == "languages" }
        return Button { showsLanguages = true } label: {
            HStack(spacing: DSSpacing.xs) {
                DSIcon(.language).accessibilityHidden(true)
                Text(chip?.text ?? "Languages")
                Image(systemName: "chevron.down").imageScale(.small).accessibilityHidden(true)
            }
            .font(DSTypography.badge)
            .foregroundStyle(DSColor.primaryText)
            .padding(.horizontal, DSSpacing.sm).padding(.vertical, DSSpacing.xxs + 1)
            .background(DSColor.primaryText.opacity(0.08), in: Capsule())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(chip?.spoken ?? "Languages")
        .accessibilityHint("Shows the full list")
        .accessibilityIdentifier("models.languages.\(row.id.rawValue)")
        .popover(isPresented: $showsLanguages) {
            let names = ModelCapabilitySummary.languageNames(row.descriptor)
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                Text("\(names.count) \(names.count == 1 ? "language" : "languages")").font(DSTypography.headline)
                ScrollView {
                    Text(names.joined(separator: ", ")).font(DSTypography.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxHeight: 240)
            }
            .padding(DSSpacing.lg)
            .frame(width: 300)
        }
    }

    @ViewBuilder private var actions: some View {
        switch row.state {
        case .notInstalled:
            Button("Download", symbol: .download, action: onDownload).accessibilityLabel(
                "Download \(row.descriptor.displayName)"
            ).accessibilityIdentifier("models.download.\(row.id.rawValue)")
        case .downloading:
            Button("Pause", systemImage: "pause.circle", action: onPause).labelStyle(.iconOnly).accessibilityLabel("Pause download")
            Button("Cancel", systemImage: "xmark.circle", action: onCancel).labelStyle(.iconOnly).accessibilityLabel("Cancel download")
        case .paused:
            Button("Resume", symbol: .play, action: onResume).labelStyle(.iconOnly).accessibilityLabel("Resume download")
            Button("Cancel", systemImage: "xmark.circle", action: onCancel).labelStyle(.iconOnly).accessibilityLabel("Cancel download")
        case .installed:
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)  // stock-chrome: destructive action
                .labelStyle(.iconOnly)
                .accessibilityLabel("Delete \(row.descriptor.displayName)")
        case .failed:
            Button("Retry", symbol: .retry, action: onDownload).accessibilityIdentifier("models.retry.\(row.id.rawValue)")
            Button("Cancel", systemImage: "xmark.circle", action: onCancel).accessibilityLabel("Cancel and discard \(row.descriptor.displayName)")
                .accessibilityIdentifier("models.cancel.\(row.id.rawValue)")
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch row.state {
        case .notInstalled:
            EmptyView()
        case .downloading(let fraction):
            if let progress = row.progress, progress.isVerifying {
                ProgressRow(title: "Verifying…", detail: nil, fraction: nil)
            } else {
                ProgressRow(title: "Downloading", detail: detail(fraction), fraction: fraction)
            }
        case .paused(let fraction):
            ProgressRow(title: "Paused", detail: "\(Int(fraction * 100))%", fraction: fraction)
        case .installed(let bytes):
            Label("Installed · \(ModelFormat.bytes(bytes)) on disk", systemImage: "checkmark.circle.fill")
                .font(DSTypography.caption).foregroundStyle(DSColor.success)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill").font(DSTypography.caption).foregroundStyle(DSColor.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func detail(_ fraction: Double) -> String {
        var parts = ["\(Int(fraction * 100))%"]
        if let progress = row.progress {
            let total = progress.bytesTotal ?? row.descriptor.sizeBytes
            parts.append("\(ModelFormat.bytes(progress.bytesReceived)) of \(ModelFormat.bytes(total))")
            if let eta = progress.eta() {
                parts.append("about \(Duration.seconds(eta).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))) left")
            }
        }
        return parts.joined(separator: " · ")
    }
}

struct ModelsSettingsView: View {
    let model: ModelManagerModel
    var kinds: Set<ModelKind>?
    @State private var pendingDownload: (id: ModelID, warnings: [DownloadWarning])?
    @State private var showImporter = false
    @State private var importFolder: URL?
    @State private var importName = ""
    @State private var importLanguages = "en"

    private var visibleRows: [ModelManagerModel.Row] {
        model.rows.filter { kinds?.contains($0.descriptor.kind) ?? true }
    }

    private var visibleKinds: [ModelKind] {
        [ModelKind.asr, .diarization, .translation, .languageID, .vad].filter { kind in visibleRows.contains { $0.descriptor.kind == kind } }
    }

    static func title(for kind: ModelKind) -> LocalizedStringKey {
        switch kind {
        case .asr: "Speech recognition"
        case .diarization: "Speaker labels"
        case .translation: "Translation"
        case .languageID: "Language detection"
        case .vad: "Voice activity"
        }
    }

    var body: some View {
        Form {
            ForEach(visibleKinds, id: \.self) { kind in
                Section {
                    ForEach(model.rows(of: kind)) { row in
                        ModelRowView(
                            row: row, isActive: row.id == model.activeModelID, recommendations: model.recommendations(for: row.id),
                            onDownload: { start(row.id) }, onPause: { Task { await model.pause(row.id) } },
                            onResume: { Task { await model.resume(row.id) } }, onCancel: { Task { await model.cancel(row.id) } },
                            onDelete: { Task { await model.requestDelete(row.id) } })
                    }
                } header: {
                    HStack {
                        Text(Self.title(for: kind))
                        Spacer()
                        if kind == visibleKinds.first {
                            Text("Disk usage: \(ModelFormat.bytes(model.totalDiskUsage))").font(DSTypography.caption)
                        }
                    }
                } footer: {
                    if kind == visibleKinds.last {
                        Text("Models are downloaded only when you choose to. Your audio stays on this Mac.")
                    }
                }
            }
            if visibleRows.isEmpty { Section { Text("No models available.").foregroundStyle(DSColor.secondaryText) } }
            if kinds == nil {
                Section("Custom model") {
                    Button("Import WhisperKit CoreML folder…", systemImage: "folder.badge.plus") { showImporter = true }
                }
            }
            if let message = model.errorMessage {
                Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(DSColor.danger) }
            }
        }
        .formStyle(.grouped)
        .task {
            await model.load()
            await model.observe()
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                importName = url.lastPathComponent
                importFolder = url
            }
        }
        .sheet(item: Binding(get: { importFolder.map(ImportItem.init) }, set: { importFolder = $0?.url })) { item in
            importSheet(item.url)
        }
        .alert(
            "Download model?", isPresented: Binding(get: { pendingDownload != nil }, set: { if !$0 { pendingDownload = nil } }),
            presenting: pendingDownload?.id
        ) { id in
            Button("Download") {
                pendingDownload = nil
                Task { await model.download(id, confirmed: true) }
            }
            Button("Cancel", role: .cancel) { pendingDownload = nil }
        } message: { _ in
            Text(ModelFormat.warningsMessage(pendingDownload?.warnings ?? []))
        }
        .alert(
            "Delete the default model?",
            isPresented: Binding(get: { model.pendingDeletion != nil }, set: { if !$0 { model.pendingDeletion = nil } })
        ) {
            Button("Delete", role: .destructive) { Task { await model.confirmPendingDeletion() } }
            Button("Cancel", role: .cancel) { model.pendingDeletion = nil }
        } message: {
            Text("\(model.pendingDeletion?.displayName ?? "This model") is your default. Transcription will download it again when needed.")
        }
    }

    private func start(_ id: ModelID) {
        Task {
            if case .needsConfirmation(let warnings) = await model.download(id) { pendingDownload = (id, warnings) }
        }
    }

    private struct ImportItem: Identifiable {
        let url: URL
        var id: URL { url }
    }

    private func importSheet(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            Text("Import custom model").font(DSTypography.title)
            TextField("Name", text: $importName)
            TextField("Language codes (comma separated)", text: $importLanguages)
            Text(url.path).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText).lineLimit(1).truncationMode(.middle)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { importFolder = nil }
                Button("Import") {
                    let codes = Set(importLanguages.split(separator: ",").map { LanguageCode($0.trimmingCharacters(in: .whitespaces)) })
                    Task {
                        if await model.importModel(folder: url, displayName: importName, languages: codes) != nil { importFolder = nil }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DSSpacing.xl)
        .frame(width: 420)
    }
}

struct LanguagesSettingsView: View {
    let model: LanguageSelectionModel

    var body: some View {
        Form {
            Section("Language") {
                Picker("Mode", selection: Binding(get: { model.kind }, set: { kind in Task { await model.setKind(kind) } })) {
                    ForEach(LanguageModeKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if model.kind == .autoDetect {
                    Text("Earmark identifies the language from the first 30 seconds and uses it for the whole job.")
                        .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                } else {
                    ForEach(model.availableLanguages, id: \.self) { code in languageRow(code) }
                }
            }
            Section {
                Picker("Model", selection: modelBinding) {
                    Text("Auto (recommended)").tag(ModelID?.none)
                    ForEach(model.availableModels) { descriptor in
                        Text(label(descriptor)).tag(ModelID?.some(descriptor.id))
                    }
                }
                Toggle("Show models for any language", isOn: Binding(get: { model.showAllModels }, set: { model.showAllModels = $0 }))
                if let id = model.downloadingModel, let row = model.manager.row(id) {
                    inlineProgress(row)
                }
                if let message = model.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(DSColor.danger)
                }
            } header: {
                Text("Advanced")
            } footer: {
                Text("Auto picks the best engine for your languages. Choosing a model limits the languages to those it supports.")
            }
        }
        .formStyle(.grouped)
        .task { await model.load() }
        .alert(
            "Download model?", isPresented: Binding(get: { model.pendingChoice != nil }, set: { if !$0 { model.dismissPendingChoice() } })
        ) {
            Button("Download") { Task { await model.confirmPendingChoice() } }
            Button("Cancel", role: .cancel) { model.dismissPendingChoice() }
        } message: {
            Text(ModelFormat.warningsMessage(model.pendingChoice?.warnings ?? []))
        }
        .alert(
            "Download model?",
            isPresented: Binding(get: { model.pendingDownload != nil }, set: { if !$0 { model.dismissPendingDownload() } })
        ) {
            Button("Download") { Task { await model.confirmPendingDownload() } }
            Button("Cancel", role: .cancel) { model.dismissPendingDownload() }
        } message: {
            Text(ModelFormat.warningsMessage(model.pendingDownload?.warnings ?? []))
        }
    }

    private var modelBinding: Binding<ModelID?> {
        Binding(get: { model.selectedModel }, set: { id in Task { await model.chooseModel(id) } })
    }

    private func label(_ descriptor: ModelDescriptor) -> String {
        let installed = model.manager.row(descriptor.id)?.isInstalled ?? false
        return installed ? descriptor.displayName : "\(descriptor.displayName) — \(ModelFormat.bytes(descriptor.sizeBytes)), not downloaded"
    }

    @ViewBuilder
    private func languageRow(_ code: LanguageCode) -> some View {
        let availability = model.availability(for: code)
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            languageButton(code, isUnavailable: availability.isUnavailable)
            switch availability {
            case .available: EmptyView()
            case .needsDownload(let descriptor):
                HStack {
                    Text(
                        "Needs \(descriptor.displayName): \(ModelFormat.bytes(descriptor.sizeBytes)), "
                            + "licence \(descriptor.license.spdx). Not downloaded yet."
                    )
                    .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                    Spacer()
                    Button(model.downloadingModel == descriptor.id ? "Downloading…" : "Download") {
                        Task { await model.downloadModel(for: code) }
                    }
                    .disabled(model.downloadingModel != nil)
                    .accessibilityIdentifier("settings.languages.download.\(code.rawValue)")
                }
            case .unavailable(let reason):
                Label(reason, systemImage: "exclamationmark.circle").font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
            }
        }
    }

    private func languageButton(_ code: LanguageCode, isUnavailable: Bool) -> some View {
        let selected = model.languages.contains(code)
        return Button {
            Task { await model.selectLanguage(code) }
        } label: {
            HStack {
                Image(
                    systemName: selected
                        ? (model.kind == .single ? "largecircle.fill.circle" : "checkmark.square.fill")
                        : (model.kind == .single ? "circle" : "square")
                )
                .foregroundStyle(selected ? DSColor.accent : DSColor.secondaryText)
                Text(LanguageSelectionModel.displayName(code))
                if model.isExperimental(code) { StatusPill("Experimental", systemImage: "flask", tone: .warning) }
                Spacer()
                LanguageBadge(code)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isUnavailable)
        .opacity(isUnavailable ? 0.5 : 1)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private func inlineProgress(_ row: ModelManagerModel.Row) -> some View {
        if case .downloading(let fraction) = row.state {
            ProgressRow(
                title: row.progress?.isVerifying == true
                    ? "Verifying \(row.descriptor.displayName)…" : "Downloading \(row.descriptor.displayName)",
                detail: "\(Int(fraction * 100))%", fraction: row.progress?.isVerifying == true ? nil : fraction)
        }
    }
}
