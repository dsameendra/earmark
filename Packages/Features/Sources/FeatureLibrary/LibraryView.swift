import AppCore
import DesignSystem
import FeatureSupport
import SwiftUI

/// Library and Recently Deleted list (skeleton while loading, empty and error states). Full feature: T11.
public struct LibraryView: View {
    @Bindable private var model: LibraryModel
    @State private var confirmPurge = false

    public init(model: LibraryModel) { self.model = model }

    private var title: LocalizedStringKey { model.mode == .library ? "Library" : "Recently Deleted" }

    public var body: some View {
        Group {
            if model.isLoading {
                VStack(alignment: .leading, spacing: DSSpacing.md) {
                    ForEach(0..<6, id: \.self) { _ in Skeleton(height: 22) }
                    Spacer()
                }
                .padding(DSSpacing.xl)
                .accessibilityLabel("Loading")
            } else if let message = model.errorMessage {
                ErrorState(message: message) { Task { await model.reload() } }
            } else if model.items.isEmpty {
                emptyState
            } else {
                List(model.visibleItems, selection: $model.selection) { item in
                    LibraryRow(item: item)
                }
                .accessibilityLabel(Text(title))
            }
        }
        .navigationTitle(title)
        .searchable(text: $model.searchText, prompt: "Filter by title")
        .toolbar { toolbarContent }
        .confirmationDialog("Delete permanently?", isPresented: $confirmPurge) {
            Button("Delete Permanently", role: .destructive) { Task { await model.purgeSelected() } }
        } message: {
            Text("This cannot be undone.")
        }
        .task { await model.reload() }
    }

    @ViewBuilder private var emptyState: some View {
        if model.mode == .library {
            EmptyState(
                systemImage: "books.vertical", title: "Your library is empty",
                message: "Transcripts you create appear here, searchable by title and full text.")
        } else {
            EmptyState(
                systemImage: "trash", title: "Nothing deleted",
                message: "Deleted transcripts stay here for 30 days before they are removed.")
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            if model.mode == .library {
                Button("Delete", systemImage: "trash") { Task { await model.deleteSelected() } }
                    .disabled(model.selection.isEmpty)
            } else {
                Button("Restore", systemImage: "arrow.uturn.backward") { Task { await model.restoreSelected() } }
                    .disabled(model.selection.isEmpty)
                Button("Delete Permanently", systemImage: "trash.slash") { confirmPurge = true }
                    .disabled(model.selection.isEmpty)
            }
        }
    }
}

private struct LibraryRow: View {
    let item: Transcript

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                Text(item.title).lineLimit(1)
                Text(item.createdAt, style: .date).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
            }
            Spacer()
            ForEach(item.languages.sorted(), id: \.self) { LanguageBadge($0) }
            Text(Duration.seconds(item.duration).formatted(.time(pattern: .hourMinuteSecond)))
                .font(DSTypography.timestamp)
                .foregroundStyle(DSColor.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Library - items") {
    LibraryView(
        model: LibraryModel(
            services: .preview(transcripts: [
                Transcript(title: "Weekly sync", source: .meeting, duration: 1830, languages: ["en"]),
                Transcript(title: "සම්මුඛ සාකච්ඡාව", source: .file, duration: 412, languages: ["si"]),
            ]), mode: .library)
    )
    .frame(width: 640, height: 400)
}

#Preview("Library - empty") { LibraryView(model: LibraryModel(services: .preview(), mode: .library)).frame(width: 640, height: 400) }

#Preview("Recently Deleted - empty") {
    LibraryView(model: LibraryModel(services: .preview(), mode: .recentlyDeleted)).frame(width: 640, height: 400)
}
