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

private struct EditorContent: View {
    @Environment(\.shellLayout) private var layout
    @Environment(\.inspectorPresented) private var inspectorPresented
    @Environment(\.inspectorToggle) private var inspectorToggle
    @State private var model: TranscriptEditorModel
    @State private var find: FindReplaceModel
    @State private var export: EditorExportModel
    @State private var activeTool: EditorTool?
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
                if inspectorPresented { activeTool = .inspector } else if activeTool == .inspector { activeTool = nil }
            }
            .onChange(of: showExport) { if !showExport { listFocused = true } }
            .onDisappear {
                model.acknowledgeReconciliation()
                playerWindow?.close()
                playerWindow = nil
                model.leaveEditor()
                Task { await model.flush() }
            }
            .sheet(isPresented: $showExport) { ExportSheet(export: export) { showExport = false }.dsEntrance() }
            .popover(item: $activeTool) { tool in
                toolContent(tool).dsEntrance().presentationBackground(DSColor.contentBackground).presentationSizing(.fitted)
            }
    }

    private var editorSurface: some View {
        VStack(spacing: 0) {
            if find.isVisible { FindBarView(model: model, find: find, fieldFocused: $findFocused).dsTransition(.glide) }
            if let message = model.languageError {
                HStack {
                    Label(message, systemImage: "exclamationmark.triangle").font(DSTypography.caption).foregroundStyle(DSColor.danger)
                    Spacer()
                    Button("Dismiss") { model.dismissLanguageError() }.buttonStyle(.link)
                }
                .padding(.horizontal, DSSpacing.md).padding(.vertical, DSSpacing.xs).background(DSColor.solidChrome)
            }
            if let report = model.reconciliation { ReconciliationBanner(report: report) { model.acknowledgeReconciliation() } }
            HStack(alignment: .top, spacing: DSSpacing.md) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: DSRadius.panel))
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        TransportBar(model: model).padding(DSSpacing.md)
                    }
                if !layout.inspectorCollapsed {
                    inspector.frame(width: 260)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(DSSpacing.md)
        }
        .background(DSColor.paper)
        .dsAnimation(.glide, value: find.isVisible)
        .dsAnimation(.glide, value: find.showsReplace)
        .navigationTitle(model.transcript?.title ?? "Transcript")
        .toolbar { editorToolbar }
    }

    // MARK: Header

    @ToolbarContentBuilder private var editorToolbar: some ToolbarContent {
        // Groups: [Find] | [Speakers, Translate] | [More]; icon-only, system-sized, with fixed spacers.
        ToolbarItem {
            Button("Find", symbol: .find) {
                find.open()
                findFocused = true
            }
            .keyboardShortcut("f", modifiers: .command)
            .accessibilityIdentifier("editor.find")
        }
        ToolbarSpacer(.fixed)
        ToolbarItemGroup {
            Button("Speakers", symbol: .speaker) { presentTool(.speakers) }
                .accessibilityIdentifier("editor.speakers")
            Button("Translate", symbol: .translate) { presentTool(.translation) }
                .accessibilityIdentifier("editor.translation")
            Button("Re-transcribe", symbol: .retry) { presentTool(.retranscribe) }
                .help("Re-transcribe, identify speakers again, or set the transcript language")
                .accessibilityIdentifier("editor.retranscribe")
        }
        ToolbarSpacer(.fixed)
        ToolbarItem {
            Menu("More", systemImage: "ellipsis") {
                Toggle(
                    "Show ignored (\(model.hiddenIgnoredCount))",
                    isOn: Binding(get: { model.showIgnored }, set: { model.setShowIgnored($0) }))
                Button("Find and Replace", symbol: .replace) {
                    find.open(replace: true)
                    findFocused = true
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
                Button("Next Match") { find.next() }.keyboardShortcut("g", modifiers: .command)
                Button("Previous Match") { find.previous() }.keyboardShortcut("g", modifiers: [.command, .shift])
                Divider()
                Button("Undo \(model.undoActionName)") { model.undo() }
                    .disabled(!model.canUndo || model.editingSegmentID != nil).keyboardShortcut("z", modifiers: .command)
                Button("Redo \(model.redoActionName)") { model.redo() }
                    .disabled(!model.canRedo || model.editingSegmentID != nil).keyboardShortcut("z", modifiers: [.command, .shift])
                Divider()
                Button("Bookmarks and highlights", symbol: .earmark) { presentTool(.bookmarks) }
                Button("View options", systemImage: "textformat.size") { presentTool(.options) }
            }
            .accessibilityIdentifier("editor.more")
        }
        ToolbarSpacer(.fixed)
        ToolbarItem(placement: .primaryAction) {
            // System prominent capsule: padding, height and pressed/disabled behaviour come from the toolbar.
            Button { showExport = true } label: { Label("Export", symbol: .export) }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.borderedProminent).tint(DSColor.accent)
                .accessibilityIdentifier("editor.export")
        }
    }

    private var inspector: some View {
        EditorInspector(model: model, onSpeakers: { presentTool(.speakers) }, onBookmarks: { presentTool(.bookmarks) })
    }

    private func presentTool(_ tool: EditorTool) {
        activeTool = tool
        inspectorToggle.wrappedValue = false
    }

    @ViewBuilder private func toolContent(_ tool: EditorTool) -> some View {
        switch tool {
        case .inspector: inspector.frame(width: 300).padding(DSSpacing.md)
        case .speakers: SpeakersPanel(model: model)
        case .bookmarks: BookmarksPanel(model: model)
        case .options: ViewOptionsPanel(model: model)
        case .translation: TranslatePanel(model: model)
        case .retranscribe: RerunPanel(model: model)
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
        if model.visibleSegments.isEmpty {
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
