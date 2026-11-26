import AppCore
import DesignSystem
import FeatureSupport
import SwiftUI

/// The Notes tab: a Markdown page written by hand, a formatting bar, version history and Summarise.
struct NotesView: View {
    let workspace: WorkspaceModel
    @State private var commands = MarkdownEditorCommands()
    @State private var showsSummarizeSheet = false
    @State private var showsHistory = false

    private var notes: NotesModel { workspace.notes }

    var body: some View {
        VStack(spacing: 0) {
            formattingBar
            Divider()
            notices
            ZStack(alignment: .topLeading) {
                MarkdownTextEditor(
                    text: Binding(get: { notes.markdown }, set: { notes.markdown = $0 }), commands: commands,
                    onSeek: { workspace.seek($0) }, isEditable: !notes.isSummarizing)
                    .opacity(notes.isSummarizing ? 0.45 : 1)
                if notes.markdown.isEmpty && notes.isLoaded && !notes.isSummarizing { placeholder }
                if notes.isSummarizing { SummaryProgressCard(notes: notes) }
            }
        }
        .background(DSColor.contentBackground)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.panel))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notes.page")
        .sheet(isPresented: $showsSummarizeSheet) { SummarizeSheet(workspace: workspace) { showsSummarizeSheet = false } }
    }

    // MARK: Formatting

    private var formattingBar: some View {
        HStack(spacing: DSSpacing.xs) {
            tool("Bold", "bold", id: "notes.bold") { commands.wrap("**") }
            tool("Italic", "italic", id: "notes.italic") { commands.wrap("*") }
            tool("Heading", "textformat.size", id: "notes.heading") { commands.prefixLines("## ") }
            tool("Bulleted list", "list.bullet", id: "notes.bullets") { commands.prefixLines("- ") }
            tool("Checklist", "checklist", id: "notes.checklist") { commands.prefixLines("- [ ] ") }
            tool("Insert time", "clock", id: "notes.timestamp") {
                if let time = workspace.currentTime() { commands.insert(NotesModel.timestamp(time) + " ") }
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(workspace.currentTime() == nil)
            Spacer(minLength: DSSpacing.sm)
            Button { showsHistory.toggle() } label: { Label("History", systemImage: "clock.arrow.circlepath") }  // stock-chrome: version history
                .labelStyle(.titleAndIcon).buttonStyle(.bordered).controlSize(.small)
                .disabled(notes.versions.isEmpty)
                .popover(isPresented: $showsHistory, arrowEdge: .bottom) { NotesHistory(notes: notes) { showsHistory = false } }
                .accessibilityIdentifier("notes.history")
            summarizeButton
        }
        .padding(.horizontal, DSSpacing.md).padding(.vertical, DSSpacing.sm)
        .disabled(notes.isSummarizing)
    }

    private func tool(_ title: String, _ symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 22, height: 22) }  // stock-chrome: editor formatting glyphs
            .buttonStyle(.dsHoverIcon).help(title).accessibilityLabel(title).accessibilityIdentifier(id)
    }

    private var summarizeButton: some View {
        let reason = workspace.summarizeUnavailableReason()
        return Button { showsSummarizeSheet = true } label: { Label("Summarise", systemImage: "sparkles") }  // stock-chrome: AI action glyph
            .labelStyle(.titleAndIcon).dsProminentButton().controlSize(.small)
            .disabled(reason != nil)
            .help(reason ?? "Write a summary of this recording into the notes")
            .accessibilityHint(reason ?? "Replaces the page with a summary. The page as it is now is kept as a version.")
            .accessibilityIdentifier("notes.summarize")
    }

    // MARK: Notices

    @ViewBuilder private var notices: some View {
        if notes.showsSummaryNotice {
            notice(symbol: "sparkles", tint: DSColor.accentTint) {
                Text("Summary written from the transcript\(notes.includeNotes ? " and your notes" : ""). Your earlier page is kept in History.")
                Spacer(minLength: DSSpacing.sm)
                Button("Undo summary") { Task { await notes.undoSummary() } }.buttonStyle(.bordered).controlSize(.small)
                    .accessibilityIdentifier("notes.undoSummary")
                Button("Dismiss", systemImage: "xmark") { notes.dismissSummaryNotice() }.labelStyle(.iconOnly).buttonStyle(.dsHoverIcon)
            }
            .accessibilityIdentifier("notes.summaryNotice")
        }
        if !notes.skippedParts.isEmpty {
            notice(symbol: "exclamationmark.triangle", tint: DSColor.warning.opacity(0.14)) {
                Text("Part \(notes.skippedParts.map(String.init).joined(separator: ", ")) could not be summarised because the system declined to process it. The summary covers the rest.")
                Spacer(minLength: 0)
            }
        }
        if case .failed(let message) = notes.summaryState {
            notice(symbol: "exclamationmark.triangle", tint: DSColor.danger.opacity(0.12)) {
                Text(message)
                Spacer(minLength: DSSpacing.sm)
                Button("Dismiss", systemImage: "xmark") { notes.dismissFailure() }.labelStyle(.iconOnly).buttonStyle(.dsHoverIcon)
            }
            .accessibilityIdentifier("notes.summaryError")
        }
    }

    private func notice<Content: View>(symbol: String, tint: Color, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: DSSpacing.sm) {
            Image(systemName: symbol).accessibilityHidden(true)  // stock-chrome: notice glyph
            content()
        }
        .font(DSTypography.caption)
        .padding(.horizontal, DSSpacing.md).padding(.vertical, DSSpacing.sm)
        .background(tint)
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text(workspace.isLive ? "Take notes while the meeting runs." : "Start typing, or press Summarise to write a summary.")
                .font(DSTypography.body).foregroundStyle(DSColor.tertiaryText)
            if workspace.isLive {
                Text("Summarise is available when the meeting ends and the full transcript is ready.")
                    .font(DSTypography.caption).foregroundStyle(DSColor.tertiaryText)
            }
        }
        .padding(.horizontal, 19).padding(.vertical, 14)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Progress while a summary is being written (long recordings take minutes and can be cancelled).
struct SummaryProgressCard: View {
    let notes: NotesModel

    var body: some View {
        let state = notes.summaryState
        VStack(spacing: DSSpacing.sm) {
            if case .running(let fraction, let detail) = state {
                ProgressView(value: fraction).progressViewStyle(.linear).frame(width: 240)
                Text(detail).font(DSTypography.body)
                Text("Summarising on this Mac. You can keep using Earmark.").font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                Button("Cancel") { notes.cancelSummary() }.accessibilityIdentifier("notes.summarize.cancel")
            }
        }
        .padding(DSSpacing.lg)
        .dsSolidSurface(.sheet, radius: DSRadius.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notes.progress")
    }
}

/// The options sheet before Summarise runs.
struct SummarizeSheet: View {
    let workspace: WorkspaceModel
    let dismiss: () -> Void

    var body: some View {
        @Bindable var notes = workspace.notes
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            Text("Summarise").font(DSTypography.title2).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text("Style").font(DSTypography.label).foregroundStyle(DSColor.secondaryText)
                DSSegmentedControl(
                    selection: $notes.style,
                    options: [.init("Meeting", value: SummaryStyle.meeting), .init("Lecture", value: SummaryStyle.lecture), .init("General", value: SummaryStyle.general)],
                    identifier: "summarize.style")
                    .frame(height: 30)
                Text(Self.styleHelp(notes.style)).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
            }
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text("Use").font(DSTypography.label).foregroundStyle(DSColor.secondaryText)
                Toggle("The transcript", isOn: .constant(true)).disabled(true)
                Toggle("My notes on this page", isOn: $notes.includeNotes).accessibilityIdentifier("summarize.includeNotes")
                Toggle("Slides and files (\(workspace.files.attachments.filter(\.usedInContext).count))", isOn: $notes.includeFiles)
                    .disabled(workspace.files.attachments.isEmpty).accessibilityIdentifier("summarize.includeFiles")
            }
            Text("This replaces the page with the summary. The page as it is now is saved in History, so nothing is lost. Everything is processed on this Mac with Apple Intelligence.")
                .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Summarise") {
                    dismiss()
                    workspace.notes.summarize()
                }
                .dsProminentButton().keyboardShortcut(.defaultAction).accessibilityIdentifier("summarize.run")
            }
        }
        .padding(DSSpacing.xl)
        .frame(width: 420)
        .background(DSColor.contentBackground)
        .accessibilityIdentifier("summarize.sheet")
    }

    static func styleHelp(_ style: SummaryStyle) -> String {
        switch style {
        case .meeting: "Summary, discussion points, decisions, action items, risks and open questions."
        case .lecture: "Summary, key concepts, definitions, examples, deadlines and questions to review."
        case .general: "Summary, key points and details."
        }
    }
}

/// Earlier versions of the page, newest first, each restorable.
struct NotesHistory: View {
    let notes: NotesModel
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            HStack {
                Text("History").font(DSTypography.headline)
                Spacer()
                Button("Save version") { Task { await notes.saveCheckpoint() } }.controlSize(.small).accessibilityIdentifier("notes.history.save")
            }
            if notes.versions.isEmpty {
                Text("Versions appear here when you summarise or restore.").font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: DSSpacing.xs) {
                        ForEach(notes.versions) { version in
                            HStack(alignment: .top, spacing: DSSpacing.sm) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Self.title(version.reason)).font(DSTypography.body.weight(.medium))
                                    Text(version.createdAt, format: .dateTime.month().day().hour().minute()).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                                    Text(version.markdown.isEmpty ? "Empty page" : String(version.markdown.prefix(90)))
                                        .font(DSTypography.caption).foregroundStyle(DSColor.tertiaryText).lineLimit(2)
                                }
                                Spacer(minLength: DSSpacing.sm)
                                Button("Restore") {
                                    Task {
                                        await notes.restore(version)
                                        dismiss()
                                    }
                                }
                                .controlSize(.small)
                            }
                            .padding(DSSpacing.sm)
                            .background(DSColor.paper, in: RoundedRectangle(cornerRadius: DSRadius.small))
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .padding(DSSpacing.lg)
        .frame(width: 360)
        .background(DSColor.contentBackground)
    }

    static func title(_ reason: NotesVersion.Reason) -> String {
        switch reason {
        case .beforeSummary: "Before the summary"
        case .beforeRestore: "Before restoring"
        case .checkpoint: "Saved version"
        }
    }
}
