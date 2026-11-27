import AppCore
import AppKit
import DesignSystem
import FeatureSupport
import FeatureWorkspace
import SwiftUI

/// The transcript editor and player for one transcript (T12, EDIT-AC-01...19).
///
/// Create one per transcript; the view rebuilds its state when `transcriptID` changes.
public struct TranscriptEditorView: View {
    private let transcriptID: TranscriptID
    private let services: AppServices

    private let playbackCenter: PlaybackCenter?
    private let onNavigate: (TranscriptID) -> Void

    /// - Parameter onNavigate: opens another transcript (a meeting's final transcript replacing the live draft that is open).
    public init(
        transcriptID: TranscriptID, services: AppServices, playbackCenter: PlaybackCenter? = nil,
        onNavigate: @escaping (TranscriptID) -> Void = { _ in }
    ) {
        self.transcriptID = transcriptID
        self.services = services
        self.playbackCenter = playbackCenter
        self.onNavigate = onNavigate
    }

    public var body: some View {
        EditorContent(transcriptID: transcriptID, services: services, playbackCenter: playbackCenter, onNavigate: onNavigate).id(transcriptID)
    }
}

private enum EditorTool: String, Identifiable {
    case speakers, bookmarks, options, translation, retranscribe
    var id: String { rawValue }
}

/// The control a tool panel opens from. A popover must hang off the control that asked for it, never the whole editor.
private enum ToolAnchor { case toolbar, more }

private struct EditorContent: View {
    @Environment(\.shellLayout) private var layout
    @AppStorage("editor.stageFraction") private var stageFraction = 0.42
    @State private var editorWidth: CGFloat = 1200
    @State private var model: TranscriptEditorModel
    @State private var workspace: WorkspaceModel
    @State private var wasLive = false
    private let services: AppServices
    @State private var find: FindReplaceModel
    @State private var export: EditorExportModel
    @State private var activeTool: EditorTool?
    @State private var toolAnchor: ToolAnchor = .toolbar
    @State private var showExport = false
    @State private var playerWindow: PlayerWindowController?
    @FocusState private var findFocused: Bool
    @FocusState private var listFocused: Bool

    init(transcriptID: TranscriptID, services: AppServices, playbackCenter: PlaybackCenter?, onNavigate: @escaping (TranscriptID) -> Void) {
        let model = TranscriptEditorModel(transcriptID: transcriptID, services: services, playbackCenter: playbackCenter)
        self.services = services
        let workspace = WorkspaceModel(transcriptID: transcriptID, services: services)
        workspace.currentTime = { [weak model] in
            guard let model else { return nil }
            if model.playback.canPlay { return model.playback.currentTime }
            return workspace.isLive ? model.segments.last?.end : nil
        }
        workspace.seek = { [weak model] time in _ = model?.playback.seek(to: time) }
        workspace.onSuperseded = { final in onNavigate(final) }
        _workspace = State(initialValue: workspace)
        _model = State(initialValue: model)
        _find = State(initialValue: FindReplaceModel(editor: model))
        _export = State(initialValue: EditorExportModel(editor: model))
    }

    var body: some View {
        withTools(lifecycle(editorSurface))
    }

    /// The load, follow and change handlers. Split from `body` so Swift 6.3 can type-check the chain.
    private func lifecycle(_ content: some View) -> some View {
        content
            .dsEntrance()
            .dsAnimation(.glide, value: find.isVisible)
            .background(
                PlaybackKeyboardCapture(playback: model.playback) {
                    model.editingSegmentID == nil && !findFocused && activeTool == nil && !showExport
                }.allowsHitTesting(false)
            )
            .task { await model.load() }
            .task { await workspace.start() }
            .task(id: workspace.isLive) { await followLiveSession() }
            .onChange(of: model.playback.currentTime) { workspace.follow(time: model.playback.currentTime) }
            .onChange(of: model.revision) { find.refresh() }
            .onChange(of: model.selection) { if find.scope == .selection { find.refresh() } }
            .onChange(of: model.showIgnored) { find.refresh() }
            .onChange(of: model.playback.isDetached) { updateDetachedWindow() }
            .onChange(of: find.isVisible) { if !find.isVisible { listFocused = true } }
            .onChange(of: model.listFocusToken) { listFocused = true }
            .onChange(of: model.editingSegmentID) { if model.editingSegmentID == nil { listFocused = true } }
            .onChange(of: activeTool) { if activeTool == nil { listFocused = true } }
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
                Task {
                    await model.flush()
                    await workspace.stop()
                }
            }
    }

    /// The export sheet and the tool popovers.
    private func withTools(_ content: some View) -> some View {
        content
            .sheet(isPresented: $showExport) { ExportSheet(export: export) { showExport = false }.dsEntrance() }
            // The More menu sits at the trailing window edge, where a popover centred on it would hang outside the window. Its panels
            // open from an anchor just inside the edge instead, directly under the toolbar button.
            .overlay(alignment: .topTrailing) {
                Color.clear.frame(width: 1, height: 1).allowsHitTesting(false).accessibilityHidden(true)
                    .popover(
                        isPresented: Binding(
                            get: { (activeTool == .bookmarks || activeTool == .options || activeTool == .retranscribe) && toolAnchor == .more },
                            set: { if !$0 && toolAnchor == .more { activeTool = nil } }),
                        arrowEdge: .bottom
                    ) {
                        if let tool = activeTool {
                            toolContent(tool).dsEntrance().presentationBackground(DSColor.contentBackground).presentationSizing(.fitted)
                        }
                    }
                    .padding(.trailing, 200)  // after the popover, so the anchor is the point itself, not the padded box
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
            mainArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(DSSpacing.md)
        }
        .background(DSColor.paper)
        .dsAnimation(.glide, value: find.isVisible)
        .dsAnimation(.glide, value: find.showsReplace)
        .dsAnimation(.glide, value: model.transcriptionJob?.state)
        .navigationTitle(model.transcript?.title ?? "Transcript")
        .toolbar { editorToolbar }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { editorWidth = $0 }
    }

    // MARK: Two columns

    /// The video or slides stage is on screen (not in the pop-out window).
    private var hasStage: Bool { workspace.showsSlides || (!model.playback.isDetached && model.playback.isVideo) }
    /// Stage left, tabs right: when there is a stage and the page is wide enough. Narrower, the stage stacks over the tabs.
    private var usesColumns: Bool { hasStage && editorWidth >= DSLayout.stageColumnsMinWidth }

    @ViewBuilder
    private var mainArea: some View {
        if usesColumns {
            let gap = DSSpacing.md
            let stageWidth = min(max(editorWidth * stageFraction, 300), max(300, editorWidth - 420 - gap * 2))
            HStack(spacing: 0) {
                VStack(spacing: DSSpacing.md) {
                    stageColumn.clipShape(RoundedRectangle(cornerRadius: DSRadius.panel))
                    TransportBar(model: model)
                }
                .frame(width: stageWidth)
                .transition(.move(edge: .leading).combined(with: .opacity))
                StageDivider(width: editorWidth, fraction: $stageFraction)
                workspaceContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: DSRadius.panel))
            }
            .dsAnimation(.glide, value: usesColumns)
        } else {
            // The transport bar is laid out below the transcript, not as a safe-area inset: the video layout's AppKit split
            // view ignores that inset, so the list ran underneath the bar and its last lines could never be scrolled into view.
            VStack(spacing: 0) {
                workspaceContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: DSRadius.panel))
                TransportBar(model: model).padding(.top, DSSpacing.md)
            }
        }
    }

    /// Left column: the Video / Slides switch (once slides exist) over the stage.
    private var stageColumn: some View {
        VStack(spacing: DSSpacing.sm) {
            if workspace.deck != nil {
                WorkspaceStageSwitch(workspace: workspace, hasMedia: model.playback.canPlay)
                    .padding(.vertical, DSSpacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if workspace.showsSlides {
                WorkspaceSlideStage(workspace: workspace)
            } else {
                PlayerPanelView(model: model, onRelink: relink)
            }
        }
    }

    // MARK: Header

    /// Below this window width the secondary toolbar buttons show icons only, so Summarise and More stay on screen.
    private var compactToolbar: Bool { layout.width < 1280 }

    @ToolbarContentBuilder private var editorToolbar: some ToolbarContent {
        // Left to right: [Find] | [Speakers, Translate] | [Pin, Folder] | [Export] | [Summarise] | [More]. The page's one primary
        // action (Summarise, orange) sits next to the end; rarely used actions (Re-transcribe, view options, ignored segments)
        // live in More.
        ToolbarItem {
            Button {
                find.open()
                findFocused = true
            } label: {
                DSToolbarLabel("Find", symbol: .find, iconOnly: compactToolbar)
            }
            .toolbarLabelStyle(iconOnly: compactToolbar)
            .dsToolbarControl()
            .keyboardShortcut("f", modifiers: .command)
            .accessibilityIdentifier("editor.find")
        }
        ToolbarSpacer(.fixed)
        ToolbarItemGroup {
            Button { presentTool(.speakers) } label: { DSToolbarLabel("Speakers", symbol: .speaker, iconOnly: compactToolbar) }
                .toolbarLabelStyle(iconOnly: compactToolbar)
                .dsToolbarControl()
                .disabled(model.isLockedByJob)
                .help(model.lockedHelp ?? "Name, add or merge speakers")
                .toolPopover(.speakers, from: .toolbar, active: $activeTool, anchor: toolAnchor, edge: .bottom) { toolContent($0) }
                .accessibilityIdentifier("editor.speakers")
            Button { presentTool(.translation) } label: { DSToolbarLabel("Translate", symbol: .translate, iconOnly: compactToolbar) }
                .toolbarLabelStyle(iconOnly: compactToolbar)
                .dsToolbarControl()
                .disabled(model.isLockedByJob)
                .help(model.lockedHelp ?? "Translate this transcript")
                .toolPopover(.translation, from: .toolbar, active: $activeTool, anchor: toolAnchor, edge: .bottom) { toolContent($0) }
                .accessibilityIdentifier("editor.translation")
        }
        ToolbarSpacer(.fixed)
        ToolbarItemGroup {
            EditorPinButton(model: model, services: services)
            EditorFolderMenu(model: model, services: services, iconOnly: compactToolbar)
        }
        ToolbarSpacer(.fixed)
        trailingToolbar
    }

    /// [Export] | [Summarise] | [More]. A separate builder: a toolbar builder takes at most ten children.
    @ToolbarContentBuilder private var trailingToolbar: some ToolbarContent {
        ToolbarItem {
            // An ordinary toolbar button: Export is common but not the page's primary action.
            Button { showExport = true } label: { DSToolbarLabel("Export", symbol: .export, iconOnly: compactToolbar) }
                .toolbarLabelStyle(iconOnly: compactToolbar)
                .dsToolbarControl()
                .disabled(model.isLockedByJob)
                .help(model.lockedHelp ?? "Export this transcript")
                .accessibilityIdentifier("editor.export")
        }
        ToolbarSpacer(.fixed)
        ToolbarItem(placement: .primaryAction) { WorkspaceSummarizeButton(workspace: workspace) }
        ToolbarSpacer(.fixed)
        ToolbarItem { EditorMoreMenu(model: model, find: find, findFocused: $findFocused, present: { presentTool($0, from: .more) }) }
    }

    private func presentTool(_ tool: EditorTool, from source: ToolAnchor = .toolbar) {
        toolAnchor = source
        activeTool = tool
    }


    fileprivate func toolContent(_ tool: EditorTool) -> AnyView {
        switch tool {
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
            stagedLayout { transcriptArea }
        }
    }

    /// The tab bar over the active tab. The Transcript tab is the editor's own list; the other tabs sit under the same stage
    /// (video or slides) so the recording stays in view while writing notes or asking questions.
    @ViewBuilder
    private var workspaceContent: some View {
        VStack(spacing: 0) {
            if model.loadState == .loaded {
                WorkspaceTabBar(workspace: workspace, hasMedia: model.playback.canPlay, showsStageSwitch: !usesColumns)
                WorkspaceFinalizingBanner(workspace: workspace)
            }
            switch workspace.tab {
            case .transcript: content
            default: stagedLayout { WorkspaceTabContent(workspace: workspace) }
            }
        }
    }

    /// Stage on top (slides, or the video player), `body` below. Audio-only recordings show the compact player strip.
    @ViewBuilder
    private func stagedLayout<Body: View>(@ViewBuilder _ body: () -> Body) -> some View {
        if usesColumns {
            body().frame(minHeight: 160)
        } else if workspace.showsSlides {
            VSplitView {
                WorkspaceSlideStage(workspace: workspace).frame(minHeight: 140, idealHeight: 300)
                body().frame(minHeight: 160)
            }
        } else if !model.playback.isDetached && model.playback.isVideo {
            VSplitView {
                PlayerPanelView(model: model, onRelink: relink).frame(minHeight: 90, idealHeight: 240)
                body().frame(minHeight: 160)
            }
        } else {
            VStack(spacing: 0) {
                if !model.playback.isDetached && !model.playback.canPlay && !workspace.isLive {
                    PlayerPanelView(model: model, onRelink: relink).frame(height: 110)
                }
                body().frame(minHeight: 160)
            }
        }
    }

    /// While a meeting or live session is writing this transcript: read-only, and the list follows what has been said.
    private func followLiveSession() async {
        guard workspace.isLive else {
            if wasLive {
                wasLive = false
                model.setReadOnly(false)
                await model.refreshSegmentsFromStore()
            }
            return
        }
        wasLive = true
        model.setReadOnly(true)
        let lines = services.live.lines()
        var last = ContinuousClock.now
        for await _ in lines {
            if ContinuousClock.now - last < .seconds(1) { continue }
            last = .now
            await model.refreshSegmentsFromStore()
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
    @ViewBuilder func toolbarLabelStyle(iconOnly: Bool) -> some View {
        if iconOnly { labelStyle(.iconOnly) } else { labelStyle(.titleAndIcon) }
    }

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


/// Pins the transcript to the sidebar (or unpins it). Goes through the editor's header so a later title edit cannot undo it.
private struct EditorPinButton: View {
    let model: TranscriptEditorModel
    let services: AppServices

    var body: some View {
        let pinned = model.transcript?.pinOrder != nil
        Button {
            Task {
                let order = await PinOrder.next(services: services)
                model.updateHeader { $0.pinOrder = pinned ? nil : order }
                try? await Task.sleep(for: .milliseconds(400))
                services.workspace.events.send(.libraryChanged)
            }
        } label: {
            DSToolbarLabel(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin", iconOnly: true)  // stock-chrome: pin
        }
        .labelStyle(.iconOnly)
        .dsToolbarControl()
        .help(pinned ? "Remove from the sidebar" : "Pin to the sidebar")
        .accessibilityLabel(pinned ? "Unpin from sidebar" : "Pin to sidebar")
        .accessibilityIdentifier("editor.pin")
    }
}

/// Moves the transcript into a folder.
private struct EditorFolderMenu: View {
    let model: TranscriptEditorModel
    let services: AppServices
    var iconOnly = false
    @State private var folders: [Folder] = []

    var body: some View {
        let current = folders.first { $0.id == model.transcript?.folderID }
        Menu {
            Button("Library (no folder)") { move(to: nil) }
            Divider()
            ForEach(folders) { folder in
                Button { move(to: folder.id) } label: {
                    if folder.id == current?.id { Label(folder.name, systemImage: "checkmark") } else { Text(folder.name) }
                }
            }
        } label: {
            DSToolbarLabel(current?.name ?? "Folder", systemImage: "folder", iconOnly: iconOnly)  // stock-chrome: folder chip
        }
        .toolbarLabelStyle(iconOnly: iconOnly)
        .dsToolbarControl()
        .help("Move this transcript to a folder")
        .accessibilityIdentifier("editor.folder")
        .task { folders = (try? await services.workspace.folders.folders()) ?? [] }
        .task {
            for await _ in services.workspace.folders.changes() { folders = (try? await services.workspace.folders.folders()) ?? [] }
        }
    }

    private func move(to folder: FolderID?) {
        model.updateHeader { $0.folderID = folder }
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            services.workspace.events.send(.libraryChanged)
        }
    }
}


/// The More menu: find and replace, undo and redo, ignored segments, Bookmarks and highlights, View options and Re-transcribe.
/// Its own view so the menu tracks the model (toolbar closures are not observation-tracked).
private struct EditorMoreMenu: View {
    let model: TranscriptEditorModel
    let find: FindReplaceModel
    var findFocused: FocusState<Bool>.Binding
    let present: (EditorTool) -> Void

    var body: some View {
        Menu {
            Toggle(
                "Show ignored (\(model.hiddenIgnoredCount))",
                isOn: Binding(get: { model.showIgnored }, set: { model.setShowIgnored($0) }))
            Button("Find and Replace", symbol: .replace) {
                find.open(replace: true)
                findFocused.wrappedValue = true
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
            Button("Bookmarks and highlights", symbol: .earmark) { present(.bookmarks) }
            Button("View options", systemImage: "textformat.size") { present(.options) }  // stock-chrome: view options
            Button("Re-transcribe…", symbol: .retry) { present(.retranscribe) }
                .disabled(model.isLockedByJob)
        } label: {
            DSToolbarLabel("More", systemImage: "ellipsis", iconOnly: true)  // stock-chrome: overflow
        }
        .labelStyle(.iconOnly)
        .dsToolbarControl()
        .help(model.hiddenIgnoredCount > 0 && !model.showIgnored ? "More (\(model.hiddenIgnoredCount) ignored segments hidden)" : "More")
        .accessibilityIdentifier("editor.more")
    }
}

/// The draggable divider between the stage and the tabs. Drag to resize, double-click to reset, arrow keys when focused.
/// The width is remembered across transcripts.
private struct StageDivider: View {
    let width: CGFloat
    @Binding var fraction: Double
    @State private var dragStart: Double?
    @State private var hovering = false

    private static let range = 0.28...0.62
    private static let standard = 0.42

    private func nudge(_ delta: Double) {
        let proposed = fraction + delta
        fraction = min(max(proposed, Self.range.lowerBound), Self.range.upperBound)
    }

    var body: some View {
        Color.clear
            .frame(width: DSSpacing.md)
            .overlay {
                Capsule().fill(hovering || dragStart != nil ? DSColor.accent.opacity(0.7) : DSColor.hairlineStrong)
                    .frame(width: hovering || dragStart != nil ? 3 : 1, height: hovering || dragStart != nil ? 44 : 28)
                    .dsAnimation(.glide, value: hovering)
            }
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? fraction
                        dragStart = start
                        guard width > 0 else { return }
                        fraction = min(max(start + value.translation.width / width, Self.range.lowerBound), Self.range.upperBound)
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .onTapGesture(count: 2) { fraction = Self.standard }
            .accessibilityElement()
            .accessibilityLabel("Resize video and transcript")
            .accessibilityValue("\(Int((fraction * 100).rounded())) percent video")
            .accessibilityAdjustableAction { direction in nudge(direction == .increment ? 0.04 : -0.04) }
            .accessibilityIdentifier("editor.stageDivider")
            .help("Drag to resize, double-click to reset")
    }
}
