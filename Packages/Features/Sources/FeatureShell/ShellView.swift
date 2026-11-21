import AppCore
import DesignSystem
import FeatureHome
import FeatureLibrary
import FeatureLive
import FeatureMeetings
import FeatureQueue
import FeatureSupport
import SwiftUI
import UniformTypeIdentifiers

/// Main window: `NavigationSplitView` with the Liquid Glass sidebar (NAV-AC-01) and the section detail views.
public struct ShellView: View {
    @Bindable private var model: ShellModel

    public init(model: ShellModel) { self.model = model }

    public var body: some View {
        NavigationSplitView {
            List(
                AppSection.allCases,
                selection: Binding<AppSection?>(get: { model.selection }, set: { if let section = $0 { model.select(section) } })
            ) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
                    .accessibilityLabel(section.title)
                    .accessibilityHint("Command \(section.shortcutNumber)")
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
            .accessibilityLabel("Sidebar")
        } detail: {
            VStack(spacing: 0) {
                if let message = model.errorMessage {
                    HStack {
                        Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(DSColor.danger)
                        Spacer()
                        Button("Dismiss") { model.dismissError() }
                    }
                    .padding(DSSpacing.md)
                }
                detail
            }
            .toolbar {
                ToolbarItem {
                    Button("Quick Open", systemImage: "magnifyingglass") { model.presentQuickOpen() }
                        .help("Quick Open (⌘K)")
                        .accessibilityHint("Search transcripts by title and text")
                }
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        .dropDestination(for: URL.self) { urls, _ in model.handleDrop(urls) }
        .fileImporter(
            isPresented: $model.isImporterPresented, allowedContentTypes: [.audiovisualContent, .folder], allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { model.handleDrop(urls) }
        }
        .sheet(isPresented: $model.isQuickOpenPresented) {
            QuickOpenView(
                model: model.quickOpen, onOpen: { model.openTranscript($0) }, onDismiss: { model.isQuickOpenPresented = false })
        }
        .task { await model.restore() }
    }

    @ViewBuilder private var detail: some View {
        switch model.selection {
        case .home: HomeView(model: model.home, actions: model.homeActions)
        case .queue: QueueView(model: model.queue)
        case .meetings: MeetingsView(model: model.meetings)
        case .live: LiveView(model: model.live)
        case .library: LibraryView(model: model.library)
        case .recentlyDeleted: LibraryView(model: model.recentlyDeleted)
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
                    .keyboardShortcut(KeyEquivalent(Character(String(section.shortcutNumber))), modifiers: [.command])
            }
            Divider()
            Button("Quick Open…") { model.presentQuickOpen() }
                .keyboardShortcut("k", modifiers: [.command])
        }
    }
}

#Preview("Shell") { ShellView(model: ShellModel(services: .preview())) }
