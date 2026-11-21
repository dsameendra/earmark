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

    public init(transcriptID: TranscriptID, services: AppServices) {
        self.transcriptID = transcriptID
        self.services = services
    }

    public var body: some View {
        EditorContent(transcriptID: transcriptID, services: services).id(transcriptID)
    }
}

private struct EditorContent: View {
    @State private var model: TranscriptEditorModel
    @State private var find: FindReplaceModel
    @State private var export: EditorExportModel
    @State private var showSpeakers = false
    @State private var showBookmarks = false
    @State private var showOptions = false
    @State private var showExport = false
    @State private var playerWindow: PlayerWindowController?
    @FocusState private var findFocused: Bool
    @FocusState private var listFocused: Bool

    init(transcriptID: TranscriptID, services: AppServices) {
        let model = TranscriptEditorModel(transcriptID: transcriptID, services: services)
        _model = State(initialValue: model)
        _find = State(initialValue: FindReplaceModel(editor: model))
        _export = State(initialValue: EditorExportModel(editor: model))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if find.isVisible { FindBarView(model: model, find: find, fieldFocused: $findFocused) }
            content
            TransportBar(model: model)
        }
        .background(DSColor.contentBackground)
        .task { await model.load() }
        .onChange(of: model.revision) { find.refresh() }
        .onChange(of: model.selection) { if find.scope == .selection { find.refresh() } }
        .onChange(of: model.showIgnored) { find.refresh() }
        .onChange(of: model.playback.isDetached) { updateDetachedWindow() }
        .onChange(of: find.isVisible) { if !find.isVisible { listFocused = true } }
        .onChange(of: model.listFocusToken) { listFocused = true }
        .onChange(of: model.editingSegmentID) { if model.editingSegmentID == nil { listFocused = true } }
        .onChange(of: showSpeakers) { if !showSpeakers { listFocused = true } }
        .onChange(of: showBookmarks) { if !showBookmarks { listFocused = true } }
        .onChange(of: showOptions) { if !showOptions { listFocused = true } }
        .onChange(of: showExport) { if !showExport { listFocused = true } }
        .onDisappear {
            playerWindow?.close()
            Task { await model.flush() }
        }
        .sheet(isPresented: $showExport) { ExportSheet(export: export) { showExport = false } }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: DSSpacing.sm) {
            Text(model.transcript?.title ?? "Transcript").font(DSTypography.headline).lineLimit(1)
            Spacer()
            Toggle(
                isOn: Binding(get: { model.showIgnored }, set: { model.setShowIgnored($0) })
            ) {
                Text(model.hiddenIgnoredCount > 0 && !model.showIgnored ? "Show ignored (\(model.hiddenIgnoredCount))" : "Show ignored")
            }
            .toggleStyle(.checkbox)
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo || model.editingSegmentID != nil)
                .keyboardShortcut("z", modifiers: .command)
                .help(model.canUndo ? "Undo \(model.undoActionName)" : "Undo")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo || model.editingSegmentID != nil)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .help(model.canRedo ? "Redo \(model.redoActionName)" : "Redo")
            Button {
                find.open()
                findFocused = true
            } label: { Image(systemName: "magnifyingglass") }
            .keyboardShortcut("f", modifiers: .command).help("Find (⌘F)")
            Button {
                find.open(replace: true)
                findFocused = true
            } label: { Image(systemName: "arrow.triangle.swap") }
            .keyboardShortcut("f", modifiers: [.command, .option]).help("Find and Replace (⌥⌘F)")
            Button { find.next() } label: { EmptyView() }
                .keyboardShortcut("g", modifiers: .command).frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
            Button { find.previous() } label: { EmptyView() }
                .keyboardShortcut("g", modifiers: [.command, .shift]).frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
            Button { showSpeakers.toggle() } label: { Image(systemName: "person.2") }
                .help("Speakers").popover(isPresented: $showSpeakers) { SpeakersPanel(model: model) }
            Button { showBookmarks.toggle() } label: { Image(systemName: "bookmark") }
                .help("Bookmarks and highlights").popover(isPresented: $showBookmarks) { BookmarksPanel(model: model) }
            Button { showOptions.toggle() } label: { Image(systemName: "textformat.size") }
                .help("View options").popover(isPresented: $showOptions) { ViewOptionsPanel(model: model) }
            Button { showExport = true } label: { Image(systemName: "square.and.arrow.up") }
                .help("Export")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, DSSpacing.md)
        .padding(.vertical, DSSpacing.sm)
        .background(DSColor.solidChrome)
        .overlay(alignment: .bottom) { Divider() }
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
            VSplitView {
                if !model.playback.isDetached {
                    PlayerPanelView(model: model, onRelink: relink)
                        .frame(minHeight: 90, idealHeight: model.playback.isVideo ? 240 : 110)
                }
                transcriptArea.frame(minHeight: 160)
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
                .onKeyPress(phases: .down) { press in
                    guard model.editingSegmentID == nil, !findFocused,
                        let shortcut = PlaybackShortcut.resolve(key: press.key, modifiers: press.modifiers)
                    else { return .ignored }
                    model.playback.perform(shortcut)
                    return .handled
                }
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
