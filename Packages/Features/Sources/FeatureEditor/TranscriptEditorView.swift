import AppCore
import AppKit
import DesignSystem
import FeatureSupport
import SwiftUI

/// The transcript editor and player for one transcript (T12, EDIT-AC-01...19).
///
/// Create one per transcript; the view rebuilds its state when `transcriptID` changes.
public struct TranscriptEditorView: View {
    private let transcriptID: TranscriptID
    private let services: AppServices

    private let playbackCenter: PlaybackCenter?

    public init(transcriptID: TranscriptID, services: AppServices, playbackCenter: PlaybackCenter? = nil) {
        self.transcriptID = transcriptID
        self.services = services
        self.playbackCenter = playbackCenter
    }

    public var body: some View {
        EditorContent(transcriptID: transcriptID, services: services, playbackCenter: playbackCenter).id(transcriptID)
    }
}

private enum EditorTool: String, Identifiable {
    case inspector, speakers, bookmarks, options, translation, retranscribe
    var id: String { rawValue }
}

/// The control a tool panel opens from. A popover must hang off the control that asked for it, never the whole editor.
private enum ToolAnchor { case toolbar, more, inspector, corner }

private struct EditorContent: View {
    @Environment(\.shellLayout) private var layout
    @Environment(\.inspectorPresented) private var inspectorPresented
    @Environment(\.inspectorToggle) private var inspectorToggle
    @State private var model: TranscriptEditorModel
    @State private var find: FindReplaceModel
    @State private var export: EditorExportModel
    @State private var activeTool: EditorTool?
    @State private var toolAnchor: ToolAnchor = .toolbar
    @State private var showExport = false
    @State private var playerWindow: PlayerWindowController?
    @FocusState private var findFocused: Bool
    @FocusState private var listFocused: Bool

    init(transcriptID: TranscriptID, services: AppServices, playbackCenter: PlaybackCenter?) {
        let model = TranscriptEditorModel(transcriptID: transcriptID, services: services, playbackCenter: playbackCenter)
        _model = State(initialValue: model)
        _find = State(initialValue: FindReplaceModel(editor: model))
        _export = State(initialValue: EditorExportModel(editor: model))
    }

    var body: some View {
        editorSurface
            .dsEntrance()
            .dsAnimation(.glide, value: find.isVisible)
            .background(
                PlaybackKeyboardCapture(playback: model.playback) {
                    model.editingSegmentID == nil && !findFocused && activeTool == nil && !showExport
                }.allowsHitTesting(false)
            )
            .task { await model.load() }
            .onChange(of: model.revision) { find.refresh() }
            .onChange(of: model.selection) { if find.scope == .selection { find.refresh() } }
            .onChange(of: model.showIgnored) { find.refresh() }
            .onChange(of: model.playback.isDetached) { updateDetachedWindow() }
            .onChange(of: find.isVisible) { if !find.isVisible { listFocused = true } }
            .onChange(of: model.listFocusToken) { listFocused = true }
            .onChange(of: model.editingSegmentID) { if model.editingSegmentID == nil { listFocused = true } }
            .onChange(of: activeTool) {
                if activeTool == nil {
                    inspectorToggle.wrappedValue = false
                    listFocused = true
                }
            }
            .onChange(of: layout.inspectorCollapsed) {
                if !layout.inspectorCollapsed && activeTool == .inspector { activeTool = nil }
            }
            .onChange(of: inspectorPresented, initial: true) {
                guard layout.inspectorCollapsed else { return }
                if inspectorPresented { toolAnchor = .corner; activeTool = .inspector } else if activeTool == .inspector { activeTool = nil }
            }
            .onChange(of: showExport) { if showExport { export.adoptViewState() } else { listFocused = true } }
            .onChange(of: model.translationChoice) { find.refresh() }
            .onAppear { PlayerZoomRegistry.shared.activate(model.playback.zoom) }
            // The shared session's player replaces the editor's private one once it loads; View > Zoom must follow it.
            .onChange(of: ObjectIdentifier(model.playback)) {
                PlayerZoomRegistry.shared.activate(model.playback.zoom)
            }
            .onDisappear {
                PlayerZoomRegistry.shared.deactivate(model.playback.zoom)
                model.acknowledgeReconciliation()
                playerWindow?.close()
                playerWindow = nil
                model.leaveEditor()
                Task { await model.flush() }
            }
            .sheet(isPresented: $showExport) { ExportSheet(export: export) { showExport = false }.dsEntrance() }
            // The More menu sits at the trailing window edge, where a popover centred on it would hang outside the window. Its panels
            // open from an anchor just inside the edge instead, directly under the toolbar button.
            .overlay(alignment: .topTrailing) {
                Color.clear.frame(width: 1, height: 1).allowsHitTesting(false).accessibilityHidden(true)
                    .popover(
                        isPresented: Binding(
                            get: { (activeTool == .bookmarks || activeTool == .options) && toolAnchor == .more },
                            set: { if !$0 && toolAnchor == .more { activeTool = nil } }),
                        arrowEdge: .bottom
                    ) {
                        if let tool = activeTool {
                            toolContent(tool).dsEntrance().presentationBackground(DSColor.contentBackground).presentationSizing(.fitted)
                        }
                    }
                    .padding(.trailing, 200)  // after the popover, so the anchor is the point itself, not the padded box
            }
            // Fallback anchor for the collapsed inspector (its button lives in the shell toolbar): top-trailing corner.
            .overlay(alignment: .topTrailing) {
                Color.clear.frame(width: 1, height: 1).allowsHitTesting(false).accessibilityHidden(true)
                    // One popover for everything opened from the corner, so the inspector panel can swap to Speakers or Bookmarks in place.
                    .popover(
                        isPresented: Binding(
                            get: { activeTool != nil && toolAnchor == .corner },
                            set: { if !$0 && toolAnchor == .corner { activeTool = nil } }),
                        arrowEdge: .bottom
                    ) {
                        if let tool = activeTool {
                            toolContent(tool).dsEntrance().presentationBackground(DSColor.contentBackground).presentationSizing(.fitted)
                        }
                    }
            }
    }

    private var editorSurface: some View {
        VStack(spacing: 0) {
            if find.isVisible { FindBarView(model: model, find: find, fieldFocused: $findFocused).dsTransition(.glide) }
            if let message = model.languageError {
                HStack {
                    Label(message, systemImage: "exclamationmark.triangle").font(DSTypography.caption).foregroundStyle(DSColor.danger)
                    Spacer()
                    Button("Dismiss") { model.dismissLanguageError() }.buttonStyle(.dsLink)
                }
                .padding(.horizontal, DSSpacing.md).padding(.vertical, DSSpacing.xs).background(DSColor.solidChrome)
            }
            TranscriptionBanner(model: model).dsTransition(.glide)
            if model.isRerunning {
                // The editor is read-only while the merge runs; say so wherever the user is, not only inside the popover.
                HStack(spacing: DSSpacing.sm) {
                    ProgressView(value: model.rerunJob?.progress ?? 0).progressViewStyle(.linear).frame(width: 120)
                    Text("Re-transcribing. The transcript is read-only until this finishes.")
                        .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                    Spacer()
                    Button("Cancel") { Task { await model.cancelRerun() } }.buttonStyle(.dsLink).font(DSTypography.caption)
                        .accessibilityIdentifier("editor.rerun.banner.cancel")
                }
                .padding(.horizontal, DSSpacing.md).padding(.vertical, DSSpacing.xs).background(DSColor.solidChrome)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("editor.rerun.banner")
            }
            if let report = model.reconciliation { ReconciliationBanner(report: report) { model.acknowledgeReconciliation() } }
            HStack(alignment: .top, spacing: DSSpacing.md) {
                // The transport bar is laid out below the transcript, not as a safe-area inset: the video layout's AppKit split
                // view ignores that inset, so the list ran underneath the bar and its last lines could never be scrolled into view.
                VStack(spacing: 0) {
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: DSRadius.panel))
                    TransportBar(model: model).padding(DSSpacing.md)
                }
                if !layout.inspectorCollapsed {
                    makeInspector(inline: true).frame(width: 260)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(DSSpacing.md)
        }
        .background(DSColor.paper)
        .dsAnimation(.glide, value: find.isVisible)
        .dsAnimation(.glide, value: find.showsReplace)
        .dsAnimation(.glide, value: model.transcriptionJob?.state)
        .navigationTitle(model.transcript?.title ?? "Transcript")
        .toolbar { editorToolbar }
    }

    // MARK: Header

    @ToolbarContentBuilder private var editorToolbar: some ToolbarContent {
        // Groups: [Find] | [Speakers, Translate] | [More]; icon-only, system-sized, with fixed spacers.
        ToolbarItem {
            Button {
                find.open()
                findFocused = true
            } label: {
                DSToolbarLabel("Find", symbol: .find)
            }
            .labelStyle(.titleAndIcon)
            .dsToolbarControl()
            .keyboardShortcut("f", modifiers: .command)
            .accessibilityIdentifier("editor.find")
        }
        ToolbarSpacer(.fixed)
        ToolbarItemGroup {
            Button { presentTool(.speakers) } label: { DSToolbarLabel("Speakers", symbol: .speaker) }
                .labelStyle(.titleAndIcon)
                .dsToolbarControl()
                .disabled(model.isLockedByJob)
                .help(model.lockedHelp ?? "Name, add or merge speakers")
                .toolPopover(.speakers, from: .toolbar, active: $activeTool, anchor: toolAnchor, edge: .bottom) { toolContent($0) }
                .accessibilityIdentifier("editor.speakers")
            Button { presentTool(.translation) } label: { DSToolbarLabel("Translate", symbol: .translate) }
                .labelStyle(.titleAndIcon)
                .dsToolbarControl()
                .disabled(model.isLockedByJob)
                .help(model.lockedHelp ?? "Translate this transcript")
                .toolPopover(.translation, from: .toolbar, active: $activeTool, anchor: toolAnchor, edge: .bottom) { toolContent($0) }
                .accessibilityIdentifier("editor.translation")
            Button { presentTool(.retranscribe) } label: { DSToolbarLabel("Re-transcribe", symbol: .retry, iconOnly: true) }
                .labelStyle(.iconOnly)
                .help(model.lockedHelp ?? "Re-transcribe, identify speakers again, or set the transcript language")
                .dsToolbarControl()
                .disabled(model.isLockedByJob)
                .toolPopover(.retranscribe, from: .toolbar, active: $activeTool, anchor: toolAnchor, edge: .bottom) { toolContent($0) }
                .accessibilityIdentifier("editor.retranscribe")
        }
        ToolbarSpacer(.fixed)
        ToolbarItem {
            Menu {
                Toggle(
                    "Show ignored (\(model.hiddenIgnoredCount))",
                    isOn: Binding(get: { model.showIgnored }, set: { model.setShowIgnored($0) }))
                Button("Find and Replace", symbol: .replace) {
                    find.open(replace: true)
                    findFocused = true
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(model.isLockedByJob)
                .help(model.lockedHelp ?? "")
                Button("Next Match") { find.next() }.keyboardShortcut("g", modifiers: .command)
                Button("Previous Match") { find.previous() }.keyboardShortcut("g", modifiers: [.command, .shift])
                Divider()
                Button("Undo \(model.undoActionName)") { model.undo() }
                    .disabled(!model.canUndo || model.editingSegmentID != nil).keyboardShortcut("z", modifiers: .command)
                Button("Redo \(model.redoActionName)") { model.redo() }
                    .disabled(!model.canRedo || model.editingSegmentID != nil).keyboardShortcut("z", modifiers: [.command, .shift])
                Divider()
                Button("Bookmarks and highlights", symbol: .earmark) { presentTool(.bookmarks, from: .more) }
                Button("View options", systemImage: "textformat.size") { presentTool(.options, from: .more) }
            } label: {
                DSToolbarLabel("More", systemImage: "ellipsis", iconOnly: true)
            }
            .labelStyle(.iconOnly)
            .dsToolbarControl()
            .accessibilityIdentifier("editor.more")
        }
        ToolbarSpacer(.fixed)
        ToolbarItem(placement: .primaryAction) {
            // System prominent capsule: padding, height and pressed/disabled behaviour come from the toolbar.
            Button { showExport = true } label: { DSToolbarLabel("Export", symbol: .export) }
                .labelStyle(.titleAndIcon)
                .dsProminentButton().tint(DSColor.accent)
                .dsToolbarControl()
                .disabled(model.isLockedByJob)
                .help(model.lockedHelp ?? "Export this transcript")
                .accessibilityIdentifier("editor.export")
        }
    }

    /// The inspector cards. Inline, their panels hang off the card's own button; inside the collapsed-inspector popover they
    /// open from the window corner instead, because that popover closes as soon as another tool is presented.
    private func makeInspector(inline: Bool) -> EditorInspector {
        let source: ToolAnchor = inline ? .inspector : .corner
        return EditorInspector(
            model: model,
            onSpeakers: { presentTool(.speakers, from: source) }, onBookmarks: { presentTool(.bookmarks, from: source) },
            speakersPopover: { anchorView in
                guard inline else { return anchorView }
                return AnyView(
                    anchorView.toolPopover(.speakers, from: .inspector, active: $activeTool, anchor: toolAnchor, edge: .leading) {
                        toolContent($0)
                    })
            },
            bookmarksPopover: { anchorView in
                guard inline else { return anchorView }
                return AnyView(
                    anchorView.toolPopover(.bookmarks, from: .inspector, active: $activeTool, anchor: toolAnchor, edge: .leading) {
                        toolContent($0)
                    })
            })
    }

    private func presentTool(_ tool: EditorTool, from source: ToolAnchor = .toolbar) {
        toolAnchor = source
        activeTool = tool
        inspectorToggle.wrappedValue = false
    }


    fileprivate func toolContent(_ tool: EditorTool) -> AnyView {
        switch tool {
        case .inspector: AnyView(makeInspector(inline: false).frame(width: 300).padding(DSSpacing.md))
        case .speakers: AnyView(SpeakersPanel(model: model))
        case .bookmarks: AnyView(BookmarksPanel(model: model))
        case .options: AnyView(ViewOptionsPanel(model: model))
        case .translation: AnyView(TranslatePanel(model: model))
        case .retranscribe: AnyView(RerunPanel(model: model))
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch model.loadState {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ErrorState(message: message) { Task { await model.load() } }
        case .loaded:
            if !model.playback.isDetached && model.playback.isVideo {
                VSplitView {
                    PlayerPanelView(model: model, onRelink: relink).frame(minHeight: 90, idealHeight: 240)
                    transcriptArea.frame(minHeight: 160)
                }
            } else {
                VStack(spacing: 0) {
                    if !model.playback.isDetached && !model.playback.canPlay {
                        PlayerPanelView(model: model, onRelink: relink).frame(height: 110)
                    }
                    transcriptArea.frame(minHeight: 160)
                }
            }
        }
    }

    @ViewBuilder
    private var transcriptArea: some View {
        if model.visibleSegments.isEmpty && model.isTranscribing {
            EmptyState(
                systemImage: "text.bubble", title: "Transcribing",
                message: "Text appears here as each part of the recording is transcribed. You can already play the recording.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.visibleSegments.isEmpty && model.transcriptionInterrupted {
            EmptyState(
                systemImage: "text.bubble", title: "Nothing transcribed yet",
                message: "The job stopped before any text was saved. Retry it, or remove it from the queue.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.visibleSegments.isEmpty {
            VStack(spacing: DSSpacing.sm) {
                EmptyState(
                    systemImage: "text.bubble", title: model.hiddenIgnoredCount > 0 ? "Everything here is ignored" : "No speech detected",
                    message: model.hiddenIgnoredCount > 0
                        ? "\(model.hiddenIgnoredCount) segments are hidden because they match ignore rules (silence or music markers)."
                        : "This recording contains no recognisable speech.")
                if model.hiddenIgnoredCount > 0 { Button("Show ignored") { model.setShowIgnored(true) } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TranscriptListView(model: model, find: find)
                .focusable()
                .focusEffectDisabled()
                .focused($listFocused)
                .onAppear { listFocused = true }
        }
    }

    // MARK: Player window and relink

    private func updateDetachedWindow() {
        if model.playback.isDetached {
            let controller = playerWindow ?? PlayerWindowController(model: model, onRelink: relink)
            playerWindow = controller
            controller.show()
        } else {
            playerWindow?.close()
            playerWindow = nil
        }
    }

    private func relink() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose the audio or video file for this transcript."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.relink(to: url) }
    }
}

private extension View {
    /// Presents `tool` as a popover from this view, only while that tool was opened from `source`, so two controls that can open
    /// the same panel never present it twice.
    func toolPopover<Content: View>(
        _ tool: EditorTool, from source: ToolAnchor, active: Binding<EditorTool?>, anchor: ToolAnchor, edge: Edge,
        @ViewBuilder content: @escaping (EditorTool) -> Content
    ) -> some View {
        popover(
            isPresented: Binding(
                get: { active.wrappedValue == tool && anchor == source },
                set: { if !$0 && active.wrappedValue == tool { active.wrappedValue = nil } }),
            arrowEdge: edge
        ) {
            content(tool).dsEntrance().presentationBackground(DSColor.contentBackground).presentationSizing(.fitted)
        }
    }
}
