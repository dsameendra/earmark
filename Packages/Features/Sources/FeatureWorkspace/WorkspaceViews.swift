import AppCore
import DesignSystem
import FeatureSupport
import SwiftUI

/// The Video / Slides switch. Shown only once a slide deck is attached.
public struct WorkspaceStageSwitch: View {
    private let workspace: WorkspaceModel
    private let hasMedia: Bool
    public init(workspace: WorkspaceModel, hasMedia: Bool) {
        self.workspace = workspace
        self.hasMedia = hasMedia
    }

    public var body: some View {
        if workspace.deck != nil {
            DSSegmentedControl(
                selection: Binding(get: { workspace.stage }, set: { $0 == .slides ? workspace.showSlides() : workspace.showVideo() }),
                options: [.init(hasMedia ? "Video" : "Hide slides", value: WorkspaceModel.Stage.video), .init("Slides", value: WorkspaceModel.Stage.slides)],
                identifier: "stage.switch")
                .frame(height: 30)
                .help("Show the slides instead of the video")
                .transition(.opacity)
        }
    }
}

/// The tabs above the transcript page: Transcript, Notes, Chat, Files, with the Video / Slides switch and a live badge.
public struct WorkspaceTabBar: View {
    private let workspace: WorkspaceModel
    private let hasMedia: Bool
    private let showsStageSwitch: Bool

    /// - Parameter showsStageSwitch: `false` in the two-column layout, where the Video / Slides switch sits above the stage.
    public init(workspace: WorkspaceModel, hasMedia: Bool, showsStageSwitch: Bool = true) {
        self.workspace = workspace
        self.hasMedia = hasMedia
        self.showsStageSwitch = showsStageSwitch
    }

    public var body: some View {
        HStack(spacing: DSSpacing.md) {
            DSSegmentedControl(
                selection: Binding(get: { workspace.tab }, set: { workspace.tab = $0 }),
                options: WorkspaceModel.Tab.allCases.map { .init(title(for: $0), value: $0) }, identifier: "workspace.tabs")
                .frame(height: 30)
            if workspace.isLive {
                Label("Live", systemImage: "circle.fill")  // stock-chrome: live badge dot
                    .labelStyle(.titleAndIcon).font(DSTypography.caption.weight(.semibold)).foregroundStyle(DSColor.recordingText)
                    .accessibilityLabel("This meeting is being transcribed now")
                    .accessibilityIdentifier("workspace.live")
            }
            Spacer(minLength: DSSpacing.sm)
            if showsStageSwitch { WorkspaceStageSwitch(workspace: workspace, hasMedia: hasMedia) }
        }
        .padding(.horizontal, DSSpacing.md).padding(.vertical, DSSpacing.sm)
        .background(DSColor.paper)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.tabBar")
    }

    private func title(for tab: WorkspaceModel.Tab) -> String {
        switch tab {
        case .files where !workspace.files.attachments.isEmpty: "Files · \(workspace.files.attachments.count)"
        default: tab.title
        }
    }
}

/// The content of the Notes, Chat and Files tabs (the Transcript tab stays the editor's own list).
public struct WorkspaceTabContent: View {
    private let workspace: WorkspaceModel
    public init(workspace: WorkspaceModel) { self.workspace = workspace }

    public var body: some View {
        Group {
            switch workspace.tab {
            case .transcript: EmptyView()
            case .notes: NotesView(workspace: workspace)
            case .chat: ChatView(workspace: workspace)
            case .files: FilesView(workspace: workspace)
            }
        }
        .padding(.horizontal, DSSpacing.md)
        .padding(.bottom, DSSpacing.xs)
    }
}

/// The slide viewer shown in the player area while the stage is on Slides.
public struct WorkspaceSlideStage: View {
    private let workspace: WorkspaceModel
    public init(workspace: WorkspaceModel) { self.workspace = workspace }
    public var body: some View { SlideStageView(workspace: workspace, showsVideoSwitch: false) }
}

/// The toolbar's Summarise button: opens Notes with the options sheet. It is the page's primary action (the orange prominent
/// button) until a summary exists; after that it is an ordinary button that offers to summarise again.
public struct WorkspaceSummarizeButton: View {
    private let workspace: WorkspaceModel
    @State private var showsSheet = false
    public init(workspace: WorkspaceModel) { self.workspace = workspace }

    public var body: some View {
        let reason = workspace.summarizeUnavailableReason()
        let again = workspace.notes.summarizedAt != nil
        Group {
            if again {
                button(again: true, reason: reason)
            } else {
                button(again: false, reason: reason).dsProminentButton().tint(DSColor.accent)
            }
        }
        .sheet(isPresented: $showsSheet) { SummarizeSheet(workspace: workspace) { showsSheet = false } }
    }

    private func button(again: Bool, reason: String?) -> some View {
        Button {
            workspace.tab = .notes
            showsSheet = true
        } label: {
            DSToolbarLabel(again ? "Summarise again" : "Summarise", systemImage: "sparkles")
        }
        .labelStyle(.titleAndIcon)
        .dsToolbarControl()
        .disabled(reason != nil || workspace.notes.isSummarizing)
        .help(reason ?? "Write a summary of this recording into the notes")
        .accessibilityIdentifier("editor.summarize")
    }
}

/// Shown after the final transcript replaced a live draft that was open.
public struct WorkspaceFinalizingBanner: View {
    private let workspace: WorkspaceModel
    public init(workspace: WorkspaceModel) { self.workspace = workspace }

    public var body: some View {
        if workspace.isFinalizing && !workspace.isLive {
            HStack(spacing: DSSpacing.sm) {
                ProgressView().controlSize(.small)
                Text("The full transcript is being prepared. Summarise will be available when it is ready.").font(DSTypography.caption)
                Spacer()
            }
            .padding(.horizontal, DSSpacing.md).padding(.vertical, DSSpacing.xs).background(DSColor.solidChrome)
            .accessibilityIdentifier("workspace.finalizing")
        }
    }
}
