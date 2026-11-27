import AppCore
import AppKit
import DesignSystem
import FeatureSupport
import SwiftUI
import UniformTypeIdentifiers

/// The Files tab: slides and reference documents attached to this recording.
struct FilesView: View {
    let workspace: WorkspaceModel
    @State private var importerRole: Attachment.Role?
    @State private var isTargeted = false
    @State private var expanded: Set<AttachmentID> = []

    private var files: FilesModel { workspace.files }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(files.attachments.isEmpty ? "No files yet" : "\(files.attachments.count) \(files.attachments.count == 1 ? "file" : "files")")
                    .font(DSTypography.headline)
                Spacer()
                Menu {
                    Button("Slides (PDF or images)…") { importerRole = .slides }
                    Button("Reference file (PDF or images)…") { importerRole = .reference }
                } label: { Label("Add files", systemImage: "plus") }  // stock-chrome: add
                    .menuStyle(.borderlessButton).fixedSize()
                    .disabled(!files.canAdd || files.isImporting)
                    .accessibilityIdentifier("files.add")
            }
            .padding(.horizontal, DSSpacing.lg).padding(.vertical, DSSpacing.md)
            Divider()
            if let message = files.errorMessage {
                HStack(alignment: .top, spacing: DSSpacing.sm) {
                    Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)  // stock-chrome: error glyph
                    Text(message).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Dismiss", systemImage: "xmark") { files.dismissError() }.labelStyle(.iconOnly).buttonStyle(.dsHoverIcon)
                }
                .font(DSTypography.caption).foregroundStyle(DSColor.danger)
                .padding(DSSpacing.md).background(DSColor.danger.opacity(0.1))
                .accessibilityIdentifier("files.error")
            }
            if files.attachments.isEmpty { empty } else { list }
        }
        .background(DSColor.contentBackground)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.panel))
        .overlay { if isTargeted { RoundedRectangle(cornerRadius: DSRadius.panel).strokeBorder(DSColor.accent, lineWidth: 2) } }
        .dropDestination(for: URL.self) { urls, _ in
            guard files.canAdd, !urls.isEmpty else { return false }
            Task { await files.add(urls, role: files.slideDecks.isEmpty ? .slides : .reference) }
            return true
        } isTargeted: { isTargeted = $0 }
        .fileImporter(
            isPresented: Binding(get: { importerRole != nil }, set: { if !$0 { importerRole = nil } }),
            allowedContentTypes: [.pdf, .image], allowsMultipleSelection: true
        ) { result in
            let role = importerRole ?? .reference
            importerRole = nil
            if case .success(let urls) = result { Task { await files.add(urls, role: role) } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("files.page")
    }

    private var empty: some View {
        EmptyState(
            systemImage: "doc.richtext", title: "Add slides or documents",  // stock-chrome: files glyph
            message: "Attach a PDF or images to view slides instead of the video, summarise them and ask questions about them. For PowerPoint or Keynote, export to PDF first (File, Export To, PDF).",
            actionTitle: files.canAdd ? "Add slides…" : nil,
            action: files.canAdd ? { importerRole = .slides } : nil)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: DSSpacing.sm) {
                ForEach(files.attachments) { attachment in card(attachment) }
                Text("PDF and images are supported. Files are copied into your library, read on this Mac, and used in summaries and chat while the switch is on. For PowerPoint or Keynote, export to PDF first.")
                    .font(DSTypography.caption).foregroundStyle(DSColor.tertiaryText).padding(.top, DSSpacing.sm)
            }
            .padding(DSSpacing.md)
        }
    }

    private func card(_ attachment: Attachment) -> some View {
        let busy = files.summarizing.contains(attachment.id)
        let reason = workspace.chatUnavailableReason()
        return VStack(alignment: .leading, spacing: DSSpacing.sm) {
            HStack(alignment: .top, spacing: DSSpacing.md) {
                Image(systemName: attachment.kind == .pdf ? "doc.richtext" : "photo.on.rectangle").font(.system(size: 22))  // stock-chrome: file glyph
                    .foregroundStyle(DSColor.secondaryText).frame(width: 30).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DSSpacing.xs) {
                        Text(attachment.title).font(DSTypography.body.weight(.medium)).lineLimit(2)
                        StatusPill(attachment.role == .slides ? "Slides" : "Reference")
                    }
                    Text(detail(attachment)).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                }
            }
            HStack(spacing: DSSpacing.sm) {
                if attachment.role == .slides {
                    Button("View") {
                        workspace.open(ChatSource(kind: .page, label: attachment.title, attachmentID: attachment.id, page: 0))
                        workspace.tab = .transcript
                    }
                    .controlSize(.small).accessibilityIdentifier("files.view.\(attachment.id)")
                } else {
                    Button("Open") { Task { if let url = await files.location(of: attachment) { NSWorkspace.shared.open(url) } } }
                        .controlSize(.small)
                }
                Button { Task { await files.summarize(attachment) } } label: {
                    if busy { ProgressView().controlSize(.small) } else { Label("Summarise", systemImage: "sparkles") }  // stock-chrome: AI action glyph
                }
                .controlSize(.small).disabled(busy || reason != nil).help(reason ?? "Summarise this file on this Mac")
                .accessibilityIdentifier("files.summarize.\(attachment.id)")
                Menu {
                    Button(attachment.role == .slides ? "Use as reference" : "Use as slides") {
                        Task { await files.setRole(attachment, attachment.role == .slides ? .reference : .slides) }
                    }
                    Divider()
                    Button("Remove", role: .destructive) { Task { await files.remove(attachment) } }
                } label: { Image(systemName: "ellipsis.circle") }  // stock-chrome: more
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("More actions")
                Spacer(minLength: 0)
            }
            .padding(.leading, 30 + DSSpacing.md)
            Toggle("Use in summaries and chat", isOn: Binding(
                get: { attachment.usedInContext }, set: { value in Task { await files.setUsedInContext(attachment, value) } }))
                .font(DSTypography.caption).toggleStyle(.switch).controlSize(.mini)
                .padding(.leading, 30 + DSSpacing.md)
            if let summary = attachment.summary, !summary.isEmpty {
                DisclosureGroup(
                    isExpanded: Binding(get: { expanded.contains(attachment.id) }, set: { if $0 { expanded.insert(attachment.id) } else { expanded.remove(attachment.id) } })
                ) {
                    Text(summary).font(DSTypography.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, DSSpacing.xs)
                } label: { Text("Summary of this file").font(DSTypography.caption.weight(.semibold)) }
            }
        }
        .padding(DSSpacing.md)
        .background(DSColor.paper, in: RoundedRectangle(cornerRadius: DSRadius.medium))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("files.item.\(attachment.id)")
    }

    private func detail(_ attachment: Attachment) -> String {
        var text = "\(attachment.pageCount) \(attachment.pageCount == 1 ? "page" : "pages")"
        if attachment.recognizedPageCount > 0 { text += " · \(attachment.recognizedPageCount) read with text recognition" }
        return text
    }
}
