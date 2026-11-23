import AppCore
import DesignSystem
import FeatureSupport
import SwiftUI
import UniformTypeIdentifiers

/// Library and Recently Deleted: search, filters, sort, list/grid, item actions, empty/loading/error states.
public struct LibraryView: View {
    @Bindable private var model: LibraryModel
    private let searchFocusToken: Int
    @FocusState private var searchFocused: Bool
    private let onOpenTranscript: (TranscriptID) -> Void

    @State private var confirmPurge = false
    @State private var renaming: Transcript?
    @State private var renameText = ""
    @State private var tagging: Transcript?
    @State private var tagText = ""
    @State private var isCreatingFolder = false
    @State private var folderName = ""
    @State private var relinking: Transcript?
    @State private var isRelinkerPresented = false

    public init(model: LibraryModel, searchFocusToken: Int = 0, onOpenTranscript: @escaping (TranscriptID) -> Void = { _ in }) {
        self.model = model
        self.searchFocusToken = searchFocusToken
        self.onOpenTranscript = onOpenTranscript
    }

    private var title: LocalizedStringKey { model.mode == .library ? "Library" : "Recently Deleted" }

    public var body: some View {
        VStack(spacing: 0) {
            if model.mode == .library { LibraryFilterBar(model: model) { isCreatingFolder = true } }
            if model.mode == .recentlyDeleted {
                Text(
                    model.retentionDays == 0
                        ? "Deleted items stay here until you remove them permanently."
                        : "Deleted items stay here for \(model.retentionDays) days. You can restore them at any time."
                )
                .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading).padding(DSSpacing.lg)
                .accessibilityIdentifier("library.retention")
            }
            if model.layout == .list && !model.items.isEmpty { LibraryColumnsHeader() }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dsSolidSurface(.sheet, radius: DSRadius.panel)
        .dsPanelInset()
        .background(DSColor.paper)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.surface")
        .navigationTitle(title)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search transcripts")
        .searchFocused($searchFocused)
        .onChange(of: searchFocusToken) { searchFocused = true }
        .toolbar { toolbarContent }
        .confirmationDialog(
            "Delete \(model.selection.count) permanently?", isPresented: $confirmPurge, titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) { Task { await model.purgeSelected() } }
        } message: {
            Text("The transcript, its segments and library-owned media are removed. This cannot be undone.")
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Rename") { if let item = renaming { Task { await model.rename(item.id, to: renameText) } } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Add Tag", isPresented: Binding(get: { tagging != nil }, set: { if !$0 { tagging = nil } })) {
            TextField("Tag", text: $tagText)
            Button("Add") { if let item = tagging { Task { await model.addTag(tagText, to: [item.id]) } } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New Folder", isPresented: $isCreatingFolder) {
            TextField("Name", text: $folderName)
            Button("Create") { Task { await model.createFolder(named: folderName) } }
            Button("Cancel", role: .cancel) {}
        }
        .fileImporter(isPresented: $isRelinkerPresented, allowedContentTypes: [.audiovisualContent]) { result in
            if case .success(let url) = result, let item = relinking { Task { await model.relink(item, to: url) } }
        }
        // Debounced reload on any query change; no timers while idle (NAV non-functional).
        .task(id: model.currentQuery) {
            try? await Task.sleep(for: .milliseconds(model.searchText.isEmpty ? 0 : 200))
            guard !Task.isCancelled else { return }
            await model.refresh()
        }
        .dsAnimation(.settle, value: model.items.map(\.id))
        .dsAnimation(.glide, value: model.newlyAddedIDs)
        .task { await model.watchJobCompletions() }
    }

    @ViewBuilder private var content: some View {
        if model.isLoading {
            skeleton
        } else if let message = model.errorMessage, model.items.isEmpty {
            ErrorState(message: message) { Task { await model.reload() } }
        } else if model.items.isEmpty {
            emptyState.accessibilityIdentifier("library.empty")
        } else {
            VStack(spacing: 0) {
                if let message = model.errorMessage {
                    HStack {
                        Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(DSColor.danger)
                        Spacer()
                        Button("Dismiss") { model.dismissError() }
                    }
                    .padding(DSSpacing.md)
                }
                if model.layout == .grid { grid } else { list }
            }
        }
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            ForEach(0..<6, id: \.self) { _ in Skeleton(height: 36) }
            Spacer()
        }
        .padding(DSSpacing.xl)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }

    private var list: some View {
        List(model.items, selection: $model.selection) { item in
            LibraryRow(item: item, model: model)
                .tag(item.id)
                .padding(.vertical, DSSpacing.xs)
                .listRowSeparator(.hidden)
                .listRowBackground(
                    model.selection.contains(item.id) || model.newlyAddedIDs.contains(item.id)
                        ? DSColor.accentTint : DSColor.contentBackground
                )
                .dsTransition(.settle)
                .accessibilityIdentifier("library.item.\(item.id)")
                .contextMenu { menu(for: item) }
                .task { await model.checkMedia(for: item) }
        }
        .contextMenu(forSelectionType: TranscriptID.self) { _ in
        } primaryAction: { ids in
            if model.mode == .library, let id = ids.first { onOpenTranscript(id) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .accessibilityLabel(Text(title))
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: DSSpacing.md)], spacing: DSSpacing.md) {
                ForEach(model.items) { item in
                    LibraryCard(
                        item: item, model: model, isSelected: model.selection.contains(item.id) || model.newlyAddedIDs.contains(item.id)
                    )
                    .dsTransition(.settle)
                    .onTapGesture(count: 2) { if model.mode == .library { onOpenTranscript(item.id) } }
                    .onTapGesture { model.selection = [item.id] }
                    .contextMenu { menu(for: item) }
                    .accessibilityAddTraits(model.selection.contains(item.id) ? .isSelected : [])
                    .accessibilityAction(named: "Open") { if model.mode == .library { onOpenTranscript(item.id) } }
                    .task { await model.checkMedia(for: item) }
                }
            }
            .padding(DSSpacing.lg)
        }
    }

    @ViewBuilder private var emptyState: some View {
        if model.isNarrowed {
            EmptyState(
                symbol: .search, title: "No matching transcripts",
                message: "Nothing matches your search and filters.", actionTitle: "Clear Search and Filters"
            ) { model.clearFilters() }
        } else if model.mode == .library {
            EmptyState(
                symbol: .library, title: "Your library is empty",
                message: "Transcripts you create appear here, searchable by title and full text. Add files from Home or the Queue.")
        } else {
            EmptyState(
                symbol: .recentlyDeleted, title: "Nothing in Recently Deleted",
                message: model.retentionDays == 0
                    ? "Deleted transcripts stay here until you remove them."
                    : "Deleted transcripts stay here for \(model.retentionDays) days before they are removed.")
        }
    }

    @ViewBuilder private func menu(for item: Transcript) -> some View {
        let ids = model.selection.contains(item.id) && model.selection.count > 1 ? Array(model.selection) : [item.id]
        if model.mode == .library {
            Button("Open", symbol: .library) { onOpenTranscript(item.id) }
            Button("Rename…", systemImage: "pencil") {
                renameText = item.title
                renaming = item
            }
            Button("Duplicate", systemImage: "plus.square.on.square") { Task { await model.duplicate(item.id) } }
            Menu("Move to Folder", symbol: .folder) {
                Button("Library Root") { Task { await model.move(ids, to: nil) } }
                ForEach(model.folders) { folder in Button(folder.name) { Task { await model.move(ids, to: folder.id) } } }
            }
            Button("Add Tag…", systemImage: "tag") {
                tagText = ""
                tagging = item
            }
            if !item.tags.isEmpty {
                Menu("Remove Tag", systemImage: "tag.slash") {
                    ForEach(item.tags, id: \.self) { tag in Button(tag) { Task { await model.removeTag(tag, from: ids) } } }
                }
            }
            Button("Re-transcribe", systemImage: "arrow.triangle.2.circlepath") { Task { await model.retranscribe(item.id) } }
            if model.mediaStates[item.id] == .missing {
                Button("Relink Media…", systemImage: "link") {
                    relinking = item
                    isRelinkerPresented = true
                }
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {  // stock-chrome: destructive action
                Task { await model.delete(ids) }
            }
        } else {
            Button("Restore", systemImage: "arrow.uturn.backward") { Task { await model.restore(ids) } }
            Button("Delete Permanently…", systemImage: "trash.slash", role: .destructive) {
                model.selection = Set(ids)
                confirmPurge = true
            }
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        // Functional groups with fixed spacers: [Layout] | [Sort] | [Delete]; each control is its own item so a
        // segmented picker or menu never nests inside another control's glass capsule.
        if model.mode == .library {
            ToolbarItem {
                // Segmented: segments are the highlight, so size via controlSize(.large) with no outside padding.
                Picker("Layout", selection: Binding(get: { model.layout }, set: { value in Task { await model.setLayout(value) } })) {
                    Label("List", systemImage: "list.bullet").tag(LibraryLayout.list)
                    Label("Grid", systemImage: "square.grid.2x2").tag(LibraryLayout.grid)
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .dsToolbarControl()
                .help("Show the library as a list or a grid")
                .accessibilityLabel("Layout")
            }
            ToolbarSpacer(.fixed)
            ToolbarItem {
                // A menu with an inline picker (not a `.menu` Picker) so the label can carry its padding inside the highlight.
                Menu {
                    Picker("Sort by", selection: $model.sort) {
                        Text("Newest").tag(LibrarySort.createdDesc)
                        Text("Oldest").tag(LibrarySort.createdAsc)
                        Text("Title").tag(LibrarySort.titleAsc)
                        Text("Longest").tag(LibrarySort.durationDesc)
                        Text("Recently modified").tag(LibrarySort.modifiedDesc)
                    }
                    .pickerStyle(.inline)
                } label: {
                    DSToolbarLabel("Sort", systemImage: "arrow.up.arrow.down")
                }
                .labelStyle(.titleAndIcon)
                .dsToolbarControl()
                .help("Choose how the library is ordered")
                .accessibilityLabel("Sort by")
            }
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Button {
                    Task { await model.deleteSelected() }  // stock-chrome: destructive action
                } label: {
                    DSToolbarLabel("Delete", systemImage: "trash")  // stock-chrome: destructive action
                }
                    .labelStyle(.titleAndIcon)
                    .dsToolbarControl()
                    .disabled(model.selection.isEmpty)
                    .help(model.selection.isEmpty ? "Select transcripts to delete" : "Move the selected transcripts to Recently Deleted")
                    .accessibilityIdentifier("library.delete")
            }
        } else {
            ToolbarItem {
                Menu {
                    Picker(
                        "Keep deleted items",
                        selection: Binding(get: { model.retentionDays }, set: { value in Task { await model.setRetention(days: value) } })
                    ) {
                        ForEach(LibraryModel.retentionOptions, id: \.self) { days in
                            Text(days == 0 ? "Forever" : "\(days) days").tag(days)
                        }
                    }
                } label: {
                    DSToolbarLabel("Keep deleted items", systemImage: "clock.arrow.circlepath", iconOnly: true)
                }
                .labelStyle(.iconOnly)
                .dsToolbarControl()
                .help("How long deleted items are kept before they are removed")
                .accessibilityHint("How long deleted items are kept before they are removed")
            }
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Button {
                    Task { await model.restoreSelected() }
                } label: {
                    DSToolbarLabel("Restore", systemImage: "arrow.uturn.backward")
                }
                    .labelStyle(.titleAndIcon)
                    .dsToolbarControl()
                    .disabled(model.selection.isEmpty)
                    .help(model.selection.isEmpty ? "Select transcripts to restore" : "Move the selected transcripts back to the Library")
            }
            ToolbarItem {
                Button { confirmPurge = true } label: { DSToolbarLabel("Delete Permanently", systemImage: "trash.slash") }
                    .labelStyle(.titleAndIcon)
                    .dsToolbarControl()
                    .disabled(model.selection.isEmpty)
                    .help(model.selection.isEmpty ? "Select transcripts to delete for good" : "Permanently delete the selected transcripts")
            }
        }
    }
}

#Preview("Library - items") {
    LibraryView(
        model: LibraryModel(
            services: .preview(transcripts: [
                Transcript(title: "Weekly sync", source: .meeting, duration: 1830, languages: ["en"], tags: ["work"]),
                Transcript(title: "සම්මුඛ සාකච්ඡාව", source: .file, duration: 412, languages: ["si"]),
            ]), mode: .library)
    )
    .frame(width: 760, height: 460)
}

#Preview("Library - empty") { LibraryView(model: LibraryModel(services: .preview(), mode: .library)).frame(width: 640, height: 400) }

#Preview("Recently Deleted - empty") {
    LibraryView(model: LibraryModel(services: .preview(), mode: .recentlyDeleted)).frame(width: 640, height: 400)
}
