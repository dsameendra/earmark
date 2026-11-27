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
            if model.showsFolderCards { FolderCardsRow(model: model) { isCreatingFolder = true } }
            if model.mode == .library, let id = model.filters.folderID { FolderBreadcrumb(model: model, folderID: id) }
            if model.layout == .list && !model.items.isEmpty { LibraryColumnsHeader(isSelecting: model.isSelecting) }
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
        .overlay(alignment: .bottom) {
            if let undo = model.undoDelete { UndoToast(message: undo.message, onUndo: { Task { await model.undoLastDelete() } }, onDismiss: { model.dismissUndo() }) }
        }
        .background { selectionShortcuts }
        .dsAnimation(.glide, value: model.undoDelete)
        .dsAnimation(.settle, value: model.items.map(\.id))
        .dsAnimation(.glide, value: model.newlyAddedIDs)
        .task { await model.watchJobCompletions() }
        .task { await model.watchWorkspace() }
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

    // MARK: List and grid

    /// A click on an item: opens it, or in Select mode toggles it (Shift extends the range). In Recently Deleted, where items
    /// cannot be opened, a click starts a selection.
    private func activate(_ item: Transcript) {
        let flags = NSEvent.modifierFlags
        if model.isSelecting {
            if flags.contains(.shift) { model.selectRange(to: item.id) } else { model.toggleSelection(item.id) }
        } else if model.mode == .library, !flags.contains(.command) {
            onOpenTranscript(item.id)
        } else {
            model.toggleSelection(item.id)
        }
    }

    private func dragPayload(for item: Transcript) -> WorkspaceDrag {
        let ids = model.isSelecting && model.selection.contains(item.id) ? Array(model.selection) : [item.id]
        return WorkspaceDragState.shared.begin(WorkspaceDrag(transcripts: ids))
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(model.groups) { group in
                    Section {
                        if model.grouping == .none || !model.isCollapsed(group.id) {
                            ForEach(group.items) { item in row(item) }
                        }
                    } header: {
                        if model.grouping != .none { GroupHeader(group: group, model: model) }
                    }
                }
            }
            .padding(.bottom, DSSpacing.lg)
        }
        .accessibilityLabel(Text(title))
    }

    private func row(_ item: Transcript) -> some View {
        let selected = model.selection.contains(item.id)
        return Button { activate(item) } label: {
            HStack(spacing: DSSpacing.md) {
                if model.isSelecting { SelectionMark(selected: selected).transition(.scale(scale: 0.5).combined(with: .opacity)) }
                LibraryRow(item: item, model: model)
            }
            .padding(.vertical, DSSpacing.xs)
        }
        .buttonStyle(LibraryRowButtonStyle(selected: selected))
        .dsAnimation(.glide, value: model.isSelecting)
        .transition(.opacity)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(model.isSelecting ? "Selects or deselects" : (model.mode == .library ? "Opens the transcript" : "Starts a selection"))
        .accessibilityIdentifier("library.item.\(item.id)")
        .contextMenu { menu(for: item) }
        .draggable(dragPayload(for: item)) { Text(item.title).padding(.horizontal, 10).padding(.vertical, 6).background(DSColor.contentBackground, in: Capsule()) }
        .task { await model.checkMedia(for: item) }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 220), spacing: DSSpacing.md)], spacing: DSSpacing.md, pinnedViews: [.sectionHeaders]
            ) {
                ForEach(model.groups) { group in
                    Section {
                        if model.grouping == .none || !model.isCollapsed(group.id) {
                            ForEach(group.items) { item in card(item) }
                        }
                    } header: {
                        if model.grouping != .none { GroupHeader(group: group, model: model).padding(.horizontal, -DSSpacing.lg) }
                    }
                }
            }
            .padding(DSSpacing.lg)
        }
    }

    private func card(_ item: Transcript) -> some View {
        let selected = model.selection.contains(item.id) || model.newlyAddedIDs.contains(item.id)
        return Button { activate(item) } label: {
            LibraryCard(item: item, model: model, isSelected: selected)
                .overlay(alignment: .topLeading) {
                    if model.isSelecting {
                        SelectionMark(selected: model.selection.contains(item.id))
                            .padding(DSSpacing.sm)
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                }
        }
        .buttonStyle(LibraryCardButtonStyle())
        .dsAnimation(.glide, value: model.isSelecting)
        .transition(.opacity)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(model.isSelecting ? "Selects or deselects" : (model.mode == .library ? "Opens the transcript" : "Starts a selection"))
        .accessibilityIdentifier("library.item.\(item.id)")
        .contextMenu { menu(for: item) }
        .draggable(dragPayload(for: item)) { Text(item.title).padding(.horizontal, 10).padding(.vertical, 6).background(DSColor.contentBackground, in: Capsule()) }
        .task { await model.checkMedia(for: item) }
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
            Button(item.pinOrder == nil ? "Pin to Sidebar" : "Unpin from Sidebar", systemImage: item.pinOrder == nil ? "pin" : "pin.slash") {
                Task { await model.togglePin(transcript: item.id) }
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
                DSSegmentedControl(
                    selection: Binding(get: { model.layout }, set: { value in Task { await model.setLayout(value) } }),
                    options: [
                        .init("List", value: LibraryLayout.list, systemImage: "list.bullet"),
                        .init("Grid", value: LibraryLayout.grid, systemImage: "square.grid.2x2"),
                    ],
                    identifier: "library.layout"
                )
                .padding(.horizontal, DSSpacing.xs)
                .help("Show the library as a list or a grid")
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
                Menu {
                    Picker(
                        "Group by", selection: Binding(get: { model.grouping }, set: { value in Task { await model.setGrouping(value) } })
                    ) {
                        ForEach(LibraryGrouping.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    DSToolbarLabel(model.grouping == .none ? "Group" : "Group: \(model.grouping.title)", systemImage: "rectangle.3.group")
                }
                .labelStyle(.titleAndIcon)
                .dsToolbarControl()
                .help("Group the library by date, folder, type, language or tag")
                .accessibilityIdentifier("library.group")
                .accessibilityLabel("Group by")
            }
            ToolbarSpacer(.fixed)
            ToolbarItem { LibrarySelectToolbar(model: model, confirmPurge: $confirmPurge) }
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
            ToolbarItem { LibrarySelectToolbar(model: model, confirmPurge: $confirmPurge) }
        }
    }
}

extension LibraryView {
    /// Hidden controls that carry the Select-mode keyboard shortcuts: Command-A selects everything, Command-Delete removes the
    /// selection, Escape leaves Select mode.
    @ViewBuilder fileprivate var selectionShortcuts: some View {
        Group {
            Button("Select All") { model.selectAll() }.keyboardShortcut("a", modifiers: .command).disabled(!model.isSelecting)
            Button("Delete Selection") {
                if model.mode == .library { Task { await model.deleteSelected() } } else { confirmPurge = true }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(!model.isSelecting || model.selection.isEmpty)
            Button("Done") { model.setSelecting(false) }.keyboardShortcut(.escape, modifiers: []).disabled(!model.isSelecting)
        }
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }
}

/// The toolbar's Select control. It is one capsule that grows when Select mode is on: the count, the actions for the selection
/// (Move, Pin, Delete; or Restore and Delete Permanently in Recently Deleted) and Done. Its own view, because toolbar closures
/// are not observation-tracked.
struct LibrarySelectToolbar: View {
    let model: LibraryModel
    @Binding var confirmPurge: Bool

    var body: some View {
        HStack(spacing: DSSpacing.xs) {
            if model.isSelecting {
                Text(model.selection.isEmpty ? "No items selected" : "\(model.selection.count) selected")
                    .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText).monospacedDigit()
                    .padding(.horizontal, DSSpacing.xs)
                    .accessibilityIdentifier("library.selectionCount")
                if !model.selection.isEmpty { actions.transition(.opacity.combined(with: .scale(scale: 0.9))) }
            }
            Button { model.toggleSelecting() } label: { DSToolbarLabel(model.isSelecting ? "Done" : "Select", systemImage: model.isSelecting ? "checkmark" : "checkmark.circle") }
                .labelStyle(.titleAndIcon)
                .dsToolbarControl()
                .help(model.isSelecting ? "Leave Select mode" : "Select transcripts to delete, move or pin them")
                .accessibilityIdentifier("library.select")
        }
        .dsAnimation(.glide, value: model.isSelecting)
        .dsAnimation(.glide, value: model.selection.isEmpty)
    }

    @ViewBuilder private var actions: some View {
        if model.mode == .library {
            Menu {
                Button("Library Root") { Task { await model.move(Array(model.selection), to: nil) } }
                ForEach(model.folders) { folder in Button(folder.name) { Task { await model.move(Array(model.selection), to: folder.id) } } }
            } label: { DSToolbarLabel("Move to folder", symbol: .folder, iconOnly: true) }
                .labelStyle(.iconOnly).dsToolbarControl().help("Move the selected transcripts to a folder")
                .accessibilityIdentifier("library.moveSelection")
            Button { Task { await model.pinSelected() } } label: {
                DSToolbarLabel(model.selectionIsPinned ? "Unpin" : "Pin", systemImage: model.selectionIsPinned ? "pin.slash" : "pin", iconOnly: true)  // stock-chrome: pin
            }
            .labelStyle(.iconOnly).dsToolbarControl().help(model.selectionIsPinned ? "Remove the selection from the sidebar" : "Pin the selection to the sidebar")
            .accessibilityIdentifier("library.pinSelection")
            Button(role: .destructive) { Task { await model.deleteSelected() } } label: {
                DSToolbarLabel("Delete", systemImage: "trash")  // stock-chrome: destructive action
            }
            .labelStyle(.titleAndIcon).dsToolbarControl()
            .help("Move the selected transcripts to Recently Deleted")
            .accessibilityLabel("Delete \(model.selection.count) transcripts")
            .accessibilityIdentifier("library.delete")
        } else {
            Button { Task { await model.restoreSelected() } } label: { DSToolbarLabel("Restore", systemImage: "arrow.uturn.backward") }
                .labelStyle(.titleAndIcon).dsToolbarControl()
                .help("Move the selected transcripts back to the Library")
                .accessibilityIdentifier("library.restore")
            Button(role: .destructive) { confirmPurge = true } label: { DSToolbarLabel("Delete Permanently", systemImage: "trash.slash") }
                .labelStyle(.titleAndIcon).dsToolbarControl()
                .help("Permanently delete the selected transcripts")
                .accessibilityIdentifier("library.purge")
        }
    }
}

/// "Moved 2 to Recently Deleted · Undo", at the bottom of the Library for a few seconds.
private struct UndoToast: View {
    let message: String
    let onUndo: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: DSSpacing.md) {
            Text(message).font(DSTypography.body)
            Button("Undo", action: onUndo).buttonStyle(.dsLink).accessibilityIdentifier("library.undoDelete")
            Button("Dismiss", systemImage: "xmark", action: onDismiss).labelStyle(.iconOnly).buttonStyle(.dsHoverIcon)  // stock-chrome: dismiss
        }
        .padding(.horizontal, DSSpacing.lg).padding(.vertical, DSSpacing.sm)
        .dsSolidSurface(.sheet, radius: DSRadius.large)
        .padding(.bottom, DSSpacing.lg)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.undoToast")
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
