import AppCore
import DesignSystem
import FeatureSupport
import Foundation
import Observation
import SwiftUI

/// Logic behind the Translate popover: which targets are offered, what each still needs (download, language pack) and the
/// download flow through `ModelManaging.ensureAvailable` (TRN-AC-03, TRN-AC-15).
@MainActor @Observable
public final class TranslatePanelModel {
    public struct Target: Identifiable, Equatable, Sendable {
        public var language: LanguageCode
        public var readiness: TranslationReadiness
        public var id: LanguageCode { language }
    }

    public private(set) var targets: [Target] = []
    public var selected: LanguageCode?
    public private(set) var isLoading = false
    public private(set) var downloadFraction: Double?
    public private(set) var downloadMessage: String?
    public private(set) var isPreparingPack = false
    /// Name, size and licence of the model that has to be downloaded for the selected target.
    public private(set) var pendingModel: ModelDescriptor?
    public private(set) var error: String?

    @ObservationIgnored private let editor: TranscriptEditorModel

    public init(editor: TranscriptEditorModel) { self.editor = editor }

    public var source: LanguageCode? { editor.translationSource }

    public var selectedReadiness: TranslationReadiness? { targets.first { $0.language == selected }?.readiness }

    public func load() async {
        guard let service = editor.translationService, let source else {
            targets = []
            return
        }
        isLoading = true
        defer { isLoading = false }
        targets = await service.targets(from: source).map { Target(language: $0.language, readiness: $0.readiness) }
        if selected == nil || !targets.contains(where: { $0.language == selected }) {
            selected = editor.translationChoice.target.flatMap { t in targets.first { $0.language == t }?.language }
                ?? targets.first(where: Self.isOffered)?.language
        }
        await refreshPending()
    }

    private static func isOffered(_ target: Target) -> Bool {
        if case .unavailable = target.readiness { return false }
        return true
    }

    public func select(_ language: LanguageCode) async {
        selected = language
        error = nil
        await refreshPending()
    }

    private func refreshPending() async {
        pendingModel = nil
        if case .needsModel(let id) = selectedReadiness, let models = editor.models {
            pendingModel = await models.catalog().first { $0.id == id }
        }
    }

    /// Downloads the model the selected target needs, then re-checks readiness.
    public func downloadModel() async {
        guard let models = editor.models, case .needsModel(let id) = selectedReadiness else { return }
        error = nil
        downloadFraction = 0
        defer {
            downloadFraction = nil
            downloadMessage = nil
        }
        do {
            for try await event in models.ensureAvailable(id) {
                switch event {
                case .progress(let fraction, _, _):
                    downloadFraction = fraction
                    downloadMessage = "Downloading"
                case .verifying: downloadMessage = "Verifying"
                case .completed: break
                }
            }
        } catch {
            self.error = "The download failed: \(error.localizedDescription)"
        }
        await load()
    }

    /// Installs Apple's language pack through the system sheet, then re-checks readiness.
    public func installApplePack() async {
        guard let service = editor.translationService, let source, let target = selected,
            case .needsApplePack = selectedReadiness
        else { return }
        error = nil
        isPreparingPack = true
        defer { isPreparingPack = false }
        if await !service.prepareApplePack(source: source, target: target) {
            error = "The language pack was not installed."
        }
        await load()
    }

    public func translate() async {
        guard let target = selected, selectedReadiness == .ready else { return }
        await editor.translate(to: target)
    }
}

/// The Editor toolbar's translation control: view mode (Original / Translated / Bilingual) plus "Translate…" (TRN-AC-08).
struct TranslatePanel: View {
    let model: TranscriptEditorModel
    @State private var panel: TranslatePanelModel

    init(model: TranscriptEditorModel) {
        self.model = model
        _panel = State(initialValue: TranslatePanelModel(editor: model))
    }

    var body: some View {
        // A plain stack (not a grouped Form) so the popover sizes to its full content instead of a scroll-backed height.
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                SectionCaption("View")
                Picker(
                    "Show", selection: Binding(get: { model.translationChoice.mode }, set: { model.setTranslationMode($0) })
                ) {
                    ForEach(TranslationDisplayMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Show")
                .accessibilityIdentifier("editor.translation.mode")
                if model.translationLanguages.count > 1 {
                    Picker(
                        "Language",
                        selection: Binding(
                            get: { model.translationChoice.target ?? model.translationLanguages[0] },
                            set: { model.setTranslationTarget($0) })
                    ) {
                        ForEach(model.translationLanguages, id: \.self) { Text(TranscriptEditorModel.name(of: $0)).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                if model.translationLanguages.isEmpty {
                    Text("This transcript has no translations yet.").font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                }
            }
            if model.canTranslate {
                Divider()
                translateSection
            }
        }
        .padding(DSSpacing.lg)
        .frame(minWidth: 340, idealWidth: 380)
        .fixedSize(horizontal: false, vertical: true)
        .task { await panel.load() }
    }

    @ViewBuilder
    private var translateSection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            SectionCaption("Translate")
            if model.translationSource == nil {
                Label("The language of this transcript is unknown. Set it on a segment first.", systemImage: "questionmark.circle")
                    .font(DSTypography.caption)
            } else if panel.targets.isEmpty {
                if panel.isLoading { ProgressView() } else { Text("No translation targets are available.").font(DSTypography.caption) }
            } else {
                Picker("Into", selection: Binding(get: { panel.selected }, set: { value in if let value { Task { await panel.select(value) } } })) {
                    ForEach(panel.targets) { target in
                        Text(label(for: target)).tag(Optional(target.language)).disabled(!isEnabled(target))
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("editor.translation.target")
                readinessView
            }
            if let job = model.translationJob, model.isTranslating {
                HStack(alignment: .center, spacing: DSSpacing.md) {
                    ProgressRow(title: "Translating", detail: "\(Int(job.progress * 100))%", fraction: job.progress)
                    Button("Cancel") { Task { await model.cancelTranslation() } }
                        .buttonStyle(.bordered).controlSize(.small)
                        .accessibilityLabel("Cancel translation")
                        .accessibilityIdentifier("editor.translation.cancel")
                }
                .padding(.top, DSSpacing.sm)
            }
            if let status = model.translationStatus ?? panel.error {
                Label(status, systemImage: "exclamationmark.triangle").font(DSTypography.caption).foregroundStyle(DSColor.danger)
            }
            if model.hasStaleTranslations {
                Label("Some translations are out of date because the text changed.", systemImage: "clock.arrow.circlepath")
                    .font(DSTypography.caption).foregroundStyle(DSColor.warning)
            }
        }
    }

    private func isEnabled(_ target: TranslatePanelModel.Target) -> Bool {
        if case .unavailable = target.readiness { return false }
        return true
    }

    private func label(for target: TranslatePanelModel.Target) -> String {
        let name = TranscriptEditorModel.name(of: target.language)
        switch target.readiness {
        case .ready: return name
        case .needsModel, .needsApplePack: return "\(name) (needs download)"
        case .unavailable: return "\(name) (unavailable)"
        }
    }

    @ViewBuilder
    private var readinessView: some View {
        switch panel.selectedReadiness {
        case .ready:
            Button { Task { await panel.translate() } } label: {
                Label("Translate", symbol: .translate).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(DSColor.accent).controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(model.isTranslating).accessibilityIdentifier("editor.translation.start")
        case .needsModel:
            if let descriptor = panel.pendingModel {
                Text("\(descriptor.displayName): \(ByteCountFormatter.string(fromByteCount: descriptor.sizeBytes, countStyle: .file)), licence \(descriptor.license.spdx).")
                    .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                if descriptor.license.isNonCommercial {
                    Label("Non-commercial licence: not for commercial use.", systemImage: "exclamationmark.triangle")
                        .font(DSTypography.caption).foregroundStyle(DSColor.warning)
                }
            }
            if let fraction = panel.downloadFraction {
                ProgressRow(title: panel.downloadMessage ?? "Downloading", detail: "\(Int(fraction * 100))%", fraction: fraction)
            } else {
                Button { Task { await panel.downloadModel() } } label: {
                    Label("Download model", symbol: .download).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(DSColor.accent).controlSize(.large)
            }
        case .needsApplePack:
            Text("Apple's on-device language pack for this pair is not installed yet.").font(DSTypography.caption)
            Button { Task { await panel.installApplePack() } } label: {
                Label("Install language pack…", symbol: .download).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(DSColor.accent).controlSize(.large)
            .disabled(panel.isPreparingPack)
        case .unavailable(let reason):
            Label(reason, systemImage: "exclamationmark.circle").font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
        case nil:
            EmptyView()
        }
    }
}
