import AppCore
import DesignSystem
import FeatureSupport
import SwiftUI

/// Finite supported directions, rather than an unbounded list of lookalike checkpoints.
struct OPUSPairPackBrowser<RowContent: View>: View {
    let model: ModelManagerModel
    let rows: [ModelManagerModel.Row]
    @ViewBuilder let rowContent: (ModelManagerModel.Row) -> RowContent
    @State private var source: LanguageCode = "en"
    @State private var target: LanguageCode = "de"
    @State private var bothDirections = true
    @State private var warnings: [DownloadWarning]?

    private var pairs: [LanguagePair] { rows.flatMap { $0.descriptor.capabilities.translationPairs ?? [] } }
    private var sources: [LanguageCode] { Set(pairs.map(\.source)).sorted() }
    private var targets: [LanguageCode] { Set(pairs.filter { $0.source == source }.map(\.target)).sorted() }
    private var selected: [ModelManagerModel.Row] { model.pairPacks(source: source, target: target, bothDirections: bothDirections) }
    private var busy: Bool { !model.activePairPackIDs.isEmpty }
    private var locked: Bool { busy || warnings != nil }
    private var missing: [ModelManagerModel.Row] { selected.filter { !$0.isInstalled } }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            Text("Small offline packs for one language direction. Add both directions to translate either way.")
                .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
            HStack {
                Picker("From", selection: $source) {
                    ForEach(sources, id: \.self) { Text(LanguageSelectionModel.displayName($0)).tag($0) }
                }.accessibilityIdentifier("models.opus.source")
                Picker("To", selection: $target) {
                    ForEach(targets, id: \.self) { Text(LanguageSelectionModel.displayName($0)).tag($0) }
                }.accessibilityIdentifier("models.opus.target")
            }.disabled(locked)
            Toggle("Include reverse direction", isOn: $bothDirections)
                .disabled(locked || !hasReverse)
                .accessibilityIdentifier("models.opus.reverse")
            if !selected.isEmpty {
                let bytes = missing.reduce(Int64(0)) { $0 + $1.descriptor.sizeBytes }
                let licences = Set(selected.map { $0.descriptor.license.spdx }).sorted().joined(separator: ", ")
                Text("\(selected.count) packs · \(ModelFormat.bytes(bytes)) to download · \(licences)")
                    .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                    .accessibilityIdentifier("models.opus.summary")
                ForEach(selected) { row in rowContent(row) }
            }
            HStack {
                Button(missing.isEmpty ? "Selected packs installed" : "Add selected packs") { start(confirmed: false) }
                    .disabled(locked || selected.isEmpty || missing.isEmpty)
                    .accessibilityIdentifier("models.opus.add")
                if busy {
                    Button("Cancel pack downloads") { Task { await model.cancelPairPackDownloads() } }
                        .accessibilityIdentifier("models.opus.cancel")
                }
            }
        }
        .onAppear { reconcile() }
        .onChange(of: source) { reconcile() }
        .onChange(of: rows.map(\.id)) { reconcile() }
        .alert("Download language packs?", isPresented: Binding(get: { warnings != nil }, set: { if !$0 { warnings = nil } })) {
            Button("Download") { warnings = nil; start(confirmed: true) }
            Button("Cancel", role: .cancel) { warnings = nil }
        } message: { Text(ModelFormat.warningsMessage(warnings ?? [])) }
    }

    private var hasReverse: Bool {
        !model.pairPacks(source: source, target: target, bothDirections: true).isEmpty
    }

    private func reconcile() {
        guard !locked else { return }
        if !sources.contains(source), let first = sources.first { source = first }
        if !targets.contains(target), let first = targets.first { target = first }
        if !hasReverse { bothDirections = false }
    }

    private func start(confirmed: Bool) {
        // Capture the reviewed pair; changing a picker must never change an in-flight batch.
        let (from, to, reverse) = (source, target, bothDirections)
        Task {
            if case .needsConfirmation(let value) = await model.downloadPairPacks(
                source: from, target: to, bothDirections: reverse, confirmed: confirmed
            ) { warnings = value }
        }
    }
}
