import AppCore
import DesignSystem
import FeatureEditor
import FeatureHome
import FeatureLibrary
import FeatureLive
import FeatureMeetings
import FeatureQueue
import FeatureSupport
import SwiftUI
import UniformTypeIdentifiers

/// Main window: `NavigationSplitView` with the Liquid Glass sidebar (NAV-AC-01) and the section detail views.
///
/// Glass budget (three layers at most per screen): (1) the sidebar, the system `NavigationSplitView` material;
/// (2) the floating toolbar groups, system toolbar glass (never a full-width bar); the one primary action is a solid
/// Ember capsule; (3) one transient floater (player dock, overlay, popover) owned by the screen that shows it.
/// Content (cards, lists, inspector, transcript) is solid.
public struct ShellView: View {
    @Bindable private var model: ShellModel

    public init(model: ShellModel) { self.model = model }

    public var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {  // the navigation pane is persistent
            GeometryReader { _ in
                SidebarView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: DSLayout.sidebarWidth, max: 280)
        } detail: {
            GeometryReader { _ in
                VStack(spacing: 0) {
                    if let message = model.errorMessage { errorBanner(message) }
                    detail
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if model.showsMiniPlayer {
                        MiniPlayerView(center: model.playback) { model.openTranscript($0) }
                            .padding(DSSpacing.md)
                            .dsTransition(.settle)  // arrives on settle, leaves on the exit curve; Reduce Motion crossfades
                    }
                }
                .background(
                    SharedPlaybackShortcuts(center: model.playback) { model.showsMiniPlayer }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DSColor.paper)
            }
            .toolbar { shellToolbar }
        }
        .toolbar(removing: .sidebarToggle)
        .background(DSColor.paper)
        .frame(minWidth: DSLayout.minWindowSize.width, minHeight: DSLayout.minWindowSize.height)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            model.updateWindowWidth($0)
        }
        .environment(\.shellLayout, model.layout)
        .environment(\.inspectorPresented, model.isInspectorPresented)
        .environment(\.inspectorToggle, $model.isInspectorToggledOn)
        .dropDestination(for: URL.self) { urls, _ in model.handleDrop(urls) }
        .fileImporter(
            isPresented: $model.isImporterPresented, allowedContentTypes: [.audiovisualContent, .folder], allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { model.handleDrop(urls) }
        }
        .sheet(item: Bindable(model.queue).batch) { batch in
            BatchSettingsSheet(model: batch, onCancel: { model.cancelAdd() }, onAdd: { Task { await model.confirmAdd() } })
        }
        .task { await model.restore() }
        .task { await model.sidebar.run() }
        .task { await model.watchCaptureForPlayback() }
    }

    /// Inline error banner on a danger tint (never a blocking modal).
    private func errorBanner(_ message: String) -> some View {
        HStack {
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(DSColor.danger)
            Spacer()
            Button("Dismiss") { model.dismissError() }.accessibilityIdentifier("shell.dismissError")
        }
        .padding(DSSpacing.md)
        .background(DSColor.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: DSRadius.large, style: .continuous))
        .padding(.horizontal, DSSpacing.lg).padding(.top, DSSpacing.sm)
    }

    // MARK: Toolbar

    /// Two floating groups: search (and the inspector toggle when the window is narrow), then the primary action.
    @ToolbarContentBuilder private var shellToolbar: some ToolbarContent {
        if model.openedTranscript != nil {
            ToolbarItem(placement: .navigation) {
                Button { model.closeTranscript() } label: { DSToolbarLabel("Back", systemImage: "chevron.backward", iconOnly: true) }
                    .labelStyle(.iconOnly)
                    .dsToolbarControl()
                    .help("Back to \(model.selection.title)")
                    .keyboardShortcut("[", modifiers: [.command])
                    .accessibilityIdentifier("toolbar.back")
            }
        }
        if !model.usesLibrarySearch {
            ToolbarItem {
                Button { model.presentQuickOpen() } label: { DSToolbarLabel("Search transcripts", symbol: .search, iconOnly: true) }
                    .labelStyle(.iconOnly)
                    .dsToolbarControl()
                    .help("Quick Open (⌘K)")
                    .accessibilityLabel("Quick Open")
                    .accessibilityHint("Search transcripts by title and text")
                    .accessibilityIdentifier("toolbar.quickOpen")
                    .popover(isPresented: $model.isQuickOpenPresented, arrowEdge: .bottom) {
                        QuickOpenView(
                            model: model.quickOpen, onOpen: { model.openTranscript($0) }, onDismiss: { model.isQuickOpenPresented = false }
                        )
                        .presentationBackground(DSColor.contentBackground)
                    }
            }
        }
        if model.openedTranscript != nil && model.layout.inspectorCollapsed {
            ToolbarItem {
                Toggle(isOn: $model.isInspectorToggledOn) { DSToolbarLabel("Inspector", systemImage: "sidebar.trailing", iconOnly: true) }
                    .labelStyle(.iconOnly)
                    .dsToolbarControl()
                    .help("Show or hide the inspector")
                    .accessibilityIdentifier("toolbar.inspector")
            }
        }
        if model.selection == .home && model.openedTranscript == nil {
            ToolbarSpacer(.fixed)
            ToolbarItem(placement: .primaryAction) {
                // The system supplies the prominent capsule, padding and height; no custom style, font or frame.
                Button { model.presentImporter() } label: { DSToolbarLabel("Transcribe", systemImage: "plus") }
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.borderedProminent)
                    .dsToolbarControl()
                    .tint(DSColor.accent)
                    .help("Choose audio or video files to transcribe (⌘O)")
                    .accessibilityIdentifier("toolbar.transcribe")
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let id = model.openedTranscript {
            TranscriptEditorView(transcriptID: id, services: model.services, playbackCenter: model.playback)
                .id(id)
        } else {
            sectionDetail
        }
    }

    @ViewBuilder private var sectionDetail: some View {
        sectionContent.dsEntrance().id(model.selection)
    }

    @ViewBuilder private var sectionContent: some View {
        switch model.selection {
        case .home: HomeView(model: model.home, actions: model.homeActions).shellContentWidth()
        case .queue: QueueView(model: model.queue, onOpenTranscript: { model.openTranscript($0) }).shellContentWidth()
        case .meetings: MeetingsView(model: model.meetings, onOpenTranscript: { model.openTranscript($0) }).shellContentWidth()
        case .live: LiveView(model: model.live).shellContentWidth()
        case .library:
            LibraryView(
                model: model.library, searchFocusToken: model.librarySearchFocusToken, onOpenTranscript: { model.openTranscript($0) }
            ).shellContentWidth()
        case .recentlyDeleted:
            LibraryView(
                model: model.recentlyDeleted, searchFocusToken: model.librarySearchFocusToken,
                onOpenTranscript: { model.openTranscript($0) }
            ).shellContentWidth()
        }
    }
}

/// App-wide keyboard commands: ⌘1…⌘6 section switching and ⌘K quick open.
public struct ShellCommands: Commands {
    private let model: ShellModel

    public init(model: ShellModel) { self.model = model }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Transcribe Files…") { model.presentImporter() }
                .keyboardShortcut("o", modifiers: [.command])
        }
        CommandMenu("Go") {
            ForEach(AppSection.allCases) { section in
                Button(section.title) { model.select(section) }
                    .keyboardShortcut(KeyEquivalent(section.shortcutKey), modifiers: [.command])
            }
            Divider()
            Button("Quick Open…") { model.presentQuickOpen() }
                .keyboardShortcut("k", modifiers: [.command])
            if model.usesLibrarySearch {
                Button("Search This Library") { model.presentQuickOpen() }
                    .keyboardShortcut("f", modifiers: [.command])
            }
        }
    }
}

#Preview("Shell") { ShellView(model: ShellModel(services: .preview())) }
