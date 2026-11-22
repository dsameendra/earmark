import AppCore
import DesignSystem
import FeatureSupport
import Observation
import SwiftUI

/// One row in the ⌘K palette.
public struct QuickOpenResult: Identifiable, Sendable, Equatable {
    public var id: TranscriptID
    public var title: String
    public var snippet: String?
}

/// Searches transcript titles and full text (NAV-AC-03).
@MainActor @Observable
public final class QuickOpenModel {
    public var query = ""
    public private(set) var results: [QuickOpenResult] = []
    public var highlighted = 0

    @ObservationIgnored private let transcripts: any TranscriptRepository

    public init(transcripts: any TranscriptRepository) { self.transcripts = transcripts }

    /// Runs the search for the current `query`; titles first, then full-text hits.
    public func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            results = []
            return
        }
        var merged: [QuickOpenResult] = []
        var seen = Set<TranscriptID>()
        if let titled = try? await transcripts.list(LibraryQuery(text: text, limit: 20)) {
            for item in titled where seen.insert(item.id).inserted { merged.append(QuickOpenResult(id: item.id, title: item.title)) }
        }
        if let hits = try? await transcripts.search(text, limit: 20) {
            for hit in hits where seen.insert(hit.transcriptID).inserted {
                let title = (try? await transcripts.transcript(hit.transcriptID))?.title ?? "Transcript"
                merged.append(QuickOpenResult(id: hit.transcriptID, title: title, snippet: hit.snippet))
            }
        }
        results = merged
        highlighted = 0
    }

    public func moveHighlight(by delta: Int) {
        guard !results.isEmpty else { return }
        highlighted = max(0, min(results.count - 1, highlighted + delta))
    }

    public var highlightedResult: QuickOpenResult? { results.indices.contains(highlighted) ? results[highlighted] : nil }
}

/// ⌘K palette sheet. Return opens the highlighted result; Escape dismisses.
struct QuickOpenView: View {
    @Bindable var model: QuickOpenModel
    let onOpen: (TranscriptID) -> Void
    let onDismiss: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            TextField("Search transcripts", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .focused($focused)
                .onSubmit { if let result = model.highlightedResult { onOpen(result.id) } }
                .onKeyPress(.downArrow) {
                    model.moveHighlight(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    model.moveHighlight(by: -1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    onDismiss()
                    return .handled
                }
                .accessibilityLabel("Quick open")
                .accessibilityHint("Type to search titles and transcript text. Return opens the selected result.")
            if model.results.isEmpty {
                Text(model.query.isEmpty ? "Search titles and full text across your library." : "No matches.")
                    .foregroundStyle(DSColor.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DSSpacing.xxs) {
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                            Button {
                                onOpen(result.id)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(result.title)
                                    if let snippet = result.snippet {
                                        Text(snippet).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText).lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(DSSpacing.sm)
                                .background(
                                    index == model.highlighted ? DSColor.accent.opacity(0.2) : .clear,
                                    in: .rect(cornerRadius: DSRadius.small))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("quickOpen.result.\(result.id)")
                            .accessibilityLabel(result.title)
                            .accessibilityAddTraits(index == model.highlighted ? .isSelected : [])
                        }
                    }
                }
                .frame(minHeight: 120, maxHeight: 280)
            }
        }
        .padding(DSSpacing.lg)
        .frame(width: 520)
        .task { focused = true }
        .task(id: model.query) {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await model.search()
        }
    }
}

#Preview("Quick open") {
    QuickOpenView(model: QuickOpenModel(transcripts: InMemoryTranscripts()), onOpen: { _ in }, onDismiss: {})
}
