import AppCore
import DesignSystem
import FeatureSupport
import SwiftUI

/// The folders row at the top of the Library root: compact cards that open a folder, accept dropped transcripts and carry the
/// folder actions (rename, colour, pin, delete).
struct FolderCardsRow: View {
    let model: LibraryModel
    let onNewFolder: () -> Void

    private var newFolderOutline: some View {
        RoundedRectangle(cornerRadius: DSRadius.medium).strokeBorder(DSColor.hairline, style: StrokeStyle(lineWidth: 1, dash: [4]))
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: DSSpacing.md) {
                ForEach(model.folders) { folder in FolderCard(model: model, folder: folder) }
                Button(action: onNewFolder) {
                    VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                        Label("New folder", symbol: .folder).font(DSTypography.body.weight(.medium))
                        Text("Drop transcripts on a folder to file them").font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                    }
                    .padding(DSSpacing.md)
                    .frame(width: 210, alignment: .leading)
                    .overlay(newFolderOutline)
                    .contentShape(RoundedRectangle(cornerRadius: DSRadius.medium))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("library.folders.new")
            }
            .padding(.horizontal, DSSpacing.lg).padding(.vertical, DSSpacing.sm)
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.folders")
    }
}

struct FolderCard: View {
    let model: LibraryModel
    let folder: Folder
    @State private var isTargeted = false
    @State private var renaming = false
    @State private var name = ""
    @State private var confirmDelete = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: DSRadius.medium) }
    private var fill: Color { isTargeted ? DSColor.accentTint : DSColor.contentBackground }
    private var stroke: Color { isTargeted ? DSColor.accent : DSColor.hairline }

    private var count: Int { model.folderCounts[folder.id] ?? 0 }

    private var label: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xxs) {
            HStack(spacing: DSSpacing.xs) {
                Circle().fill(SpeakerPalette.color(forSlot: folder.colorIndex)).frame(width: 9, height: 9).accessibilityHidden(true)
                Text(folder.name).font(DSTypography.body.weight(.medium)).lineLimit(1)
                if folder.isPinned {
                    Image(systemName: "pin.fill")  // stock-chrome: pin badge
                        .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText).accessibilityHidden(true)
                }
            }
            Text(count == 1 ? "1 item" : "\(count) items").font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
        }
        .padding(DSSpacing.md)
        .frame(width: 210, alignment: .leading)
        .background(fill, in: shape)
        .overlay(shape.strokeBorder(stroke, lineWidth: 1))
        .contentShape(shape)
    }

    private var card: some View {
        Button { model.openFolder(folder.id) } label: { label }
            .buttonStyle(.plain)
            .dropDestination(for: DraggedTranscripts.self) { dropped, _ in
                guard let ids = dropped.first?.ids, !ids.isEmpty else { return false }
                Task { await model.move(ids, to: folder.id) }
                return true
            } isTargeted: { isTargeted = $0 }
    }

    private var menu: some View {
        FolderMenu(model: model, folder: folder, onRename: { name = folder.name; renaming = true }, onDelete: { confirmDelete = true })
    }

    var body: some View {
        card
            .contextMenu { menu }
            .alert("Rename Folder", isPresented: $renaming) {
                TextField("Name", text: $name)
                Button("Rename") { Task { await model.renameFolder(folder.id, to: name) } }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete \(folder.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Folder", role: .destructive) { Task { await model.deleteFolder(folder.id) } }
            } message: {
                Text("Its transcripts move to the Library. Nothing else is deleted.")
            }
            .accessibilityLabel("Folder \(folder.name), \(count) items")
            .accessibilityIdentifier("library.folder.\(folder.id)")
    }
}

/// Folder actions, shared by the card, the breadcrumb and the sidebar.
public struct FolderMenu: View {
    let model: LibraryModel
    let folder: Folder
    let onRename: () -> Void
    let onDelete: () -> Void

    public var body: some View {
        Button("Open", symbol: .folder) { model.openFolder(folder.id) }
        Button(folder.isPinned ? "Unpin from Sidebar" : "Pin to Sidebar", systemImage: folder.isPinned ? "pin.slash" : "pin") {
            Task { await model.togglePin(folder: folder.id) }
        }
        Button("Rename…", systemImage: "pencil", action: onRename)
        Menu("Colour", systemImage: "paintpalette") {
            ForEach(0..<8, id: \.self) { index in
                Button { Task { await model.setFolderColor(folder.id, index: index) } } label: {
                    Label("Colour \(index + 1)", systemImage: folder.colorIndex == index ? "checkmark.circle.fill" : "circle.fill")
                }
            }
        }
        Divider()
        Button("Delete Folder…", systemImage: "trash", role: .destructive, action: onDelete)  // stock-chrome: destructive action
    }

    public init(model: LibraryModel, folder: Folder, onRename: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.model = model
        self.folder = folder
        self.onRename = onRename
        self.onDelete = onDelete
    }
}

/// "Library › Physics 201" with the folder actions, shown while a folder is open.
struct FolderBreadcrumb: View {
    let model: LibraryModel
    let folderID: FolderID
    @State private var renaming = false
    @State private var name = ""
    @State private var confirmDelete = false

    var body: some View {
        let folder = model.folders.first { $0.id == folderID }
        HStack(spacing: DSSpacing.sm) {
            Button("Library") { model.openFolder(nil) }.buttonStyle(.dsLink).accessibilityIdentifier("library.breadcrumb.root")
            Image(systemName: "chevron.right").font(DSTypography.caption).foregroundStyle(DSColor.tertiaryText).accessibilityHidden(true)
            if let folder {
                Circle().fill(SpeakerPalette.color(forSlot: folder.colorIndex)).frame(width: 9, height: 9).accessibilityHidden(true)
                Text(folder.name).font(DSTypography.headline)
                Spacer()
                Button(folder.isPinned ? "Unpin" : "Pin", systemImage: folder.isPinned ? "pin.slash" : "pin") {
                    Task { await model.togglePin(folder: folder.id) }
                }
                .accessibilityIdentifier("library.folder.pin")
                Menu {
                    FolderMenu(model: model, folder: folder, onRename: { name = folder.name; renaming = true }, onDelete: { confirmDelete = true })
                } label: { Label("Folder actions", systemImage: "ellipsis.circle") }
                    .labelStyle(.iconOnly).menuStyle(.borderlessButton).fixedSize()
                    .accessibilityIdentifier("library.folder.menu")
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, DSSpacing.lg).padding(.vertical, DSSpacing.sm)
        .alert("Rename Folder", isPresented: $renaming) {
            TextField("Name", text: $name)
            Button("Rename") { Task { await model.renameFolder(folderID, to: name) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this folder?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Folder", role: .destructive) { Task { await model.deleteFolder(folderID) } }
        } message: {
            Text("Its transcripts move to the Library. Nothing else is deleted.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.breadcrumb")
    }
}

/// A collapsible group header in the Library list.
struct GroupHeader: View {
    let group: LibraryGroup
    let model: LibraryModel

    var body: some View {
        let collapsed = model.isCollapsed(group.id)
        Button { Task { await model.toggleCollapsed(group.id) } } label: {
            HStack(spacing: DSSpacing.xs) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(DSTypography.caption).frame(width: 12)
                Text(group.title).font(DSTypography.label.weight(.semibold))
                Text("\(group.items.count)").font(DSTypography.caption).foregroundStyle(DSColor.tertiaryText)
                Spacer()
            }
            .foregroundStyle(DSColor.secondaryText)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .listRowBackground(DSColor.contentBackground)
        .accessibilityLabel("\(group.title), \(group.items.count) items, \(collapsed ? "collapsed" : "expanded")")
        .accessibilityHint("Shows or hides this group")
        .accessibilityIdentifier("library.group.\(group.id)")
    }
}
