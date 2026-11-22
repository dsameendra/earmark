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
        NavigationSplitView(columnVisibility: $model.columnVisibility) {
            GeometryReader { _ in
                SidebarView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: DSLayout.sidebarWidth, max: 280)
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
                            .transition(.opacity)
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
                Button("Back", systemImage: "chevron.backward") { model.closeTranscript() }
                    .help("Back to \(model.selection.title)")
                    .keyboardShortcut("[", modifiers: [.command])
                    .accessibilityIdentifier("toolbar.back")
            }
        }
        if !model.usesLibrarySearch {
            ToolbarItem {
                Button("Search transcripts", symbol: .search) { model.presentQuickOpen() }
                    .labelStyle(.titleAndIcon)
                    .controlSize(.large)
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
                Toggle(isOn: $model.isInspectorToggledOn) { Label("Inspector", systemImage: "sidebar.trailing") }
                    .help("Show or hide the inspector")
                    .accessibilityIdentifier("toolbar.inspector")
            }
        }
        if model.selection == .home && model.openedTranscript == nil {
            ToolbarSpacer(.fixed)
            ToolbarItem(placement: .primaryAction) {
                PrimaryToolbarButton(title: "Transcribe", systemImage: "plus") { model.presentImporter() }
                    .help("Choose audio or video files to transcribe")
                    .accessibilityIdentifier("toolbar.transcribe")
            }
            .sharedBackgroundVisibility(.hidden)
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

/// The one primary action of a view: a solid Ember capsule in every appearance.
private struct PrimaryToolbarButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { Label(title, systemImage: systemImage) }
            .labelStyle(.titleAndIcon)
            .buttonStyle(EmberButtonStyle())
    }
}
