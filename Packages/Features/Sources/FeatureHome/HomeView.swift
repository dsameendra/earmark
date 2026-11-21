import AppCore
import DesignSystem
import FeatureSupport
import SwiftUI

/// Callbacks the shell supplies to Home.
public struct HomeActions {
    public var transcribeFile: () -> Void
    public var startLive: () -> Void
    public var openQueue: () -> Void
    public var openTranscript: (TranscriptID) -> Void
    public init(
        transcribeFile: @escaping () -> Void = {}, startLive: @escaping () -> Void = {}, openQueue: @escaping () -> Void = {},
        openTranscript: @escaping (TranscriptID) -> Void = { _ in }
    ) {
        self.transcribeFile = transcribeFile
        self.startLive = startLive
        self.openQueue = openQueue
        self.openTranscript = openTranscript
    }
}

/// Home: quick actions, drop zone, recent transcripts, active jobs and model status (NAV-AC-05/06/07/08).
public struct HomeView: View {
    private let model: HomeModel
    private let actions: HomeActions

    public init(model: HomeModel, actions: HomeActions = HomeActions()) {
        self.model = model
        self.actions = actions
    }

    public var body: some View {
        Group {
            if model.recent.isEmpty && !model.isLoadingRecent && !model.summary.isActive {
                emptyHome
            } else {
                populatedHome
            }
        }
        .navigationTitle("Home")
        .task { await model.run() }
    }

    private var emptyHome: some View {
        ContentUnavailableView {
            Label("No transcripts yet", systemImage: "waveform.badge.magnifyingglass")
        } description: {
            Text("Drop audio or video files anywhere in this window, or start live captions.")
        } actions: {
            Button("Transcribe a file", action: actions.transcribeFile)
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Choose audio or video files to transcribe")
            Button("Start live captions", action: startLive)
                .accessibilityHint("Open the Live section")
        }
    }

    private var populatedHome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpacing.xl) {
                if let message = model.errorMessage {
                    ErrorState(message: message) { model.dismissError() }
                        .frame(maxHeight: 160)
                }
                quickActions
                if let download = model.download { downloadRow(download) }
                if model.summary.isActive { jobsSummary }
                recentSection
                modelStatus
            }
            .padding(DSSpacing.xl)
        }
    }

    /// Ensures the model is installed (inline progress), then continues into Live (NAV-AC-07).
    private func startLive() {
        Task {
            if await model.ensureDefaultModel() { actions.startLive() }
        }
    }

    private var quickActions: some View {
        DSGlassGroup(spacing: DSSpacing.md) {
            ViewThatFits {
                HStack(spacing: DSSpacing.md) { actionButtons }
                VStack(spacing: DSSpacing.md) { actionButtons }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick actions")
    }

    @ViewBuilder private var actionButtons: some View {
        QuickActionButton(title: "Transcribe File", systemImage: "doc.badge.waveform", action: actions.transcribeFile)
        QuickActionButton(title: "Start Live Captions", systemImage: "captions.bubble", action: startLive)
        QuickActionButton(title: "Start Meeting Capture", systemImage: "person.2.wave.2", action: {}, isEnabled: false)
        QuickActionButton(title: "Dictation", systemImage: "mic", action: {}, isEnabled: false, caption: "Not set up")
    }

    private func downloadRow(_ status: ModelDownloadStatus) -> some View {
        GlassCard {
            ProgressRow(
                title: "Downloading \(status.modelName)", detail: status.isVerifying ? "Verifying" : nil, fraction: status.fraction)
        }
    }

    private var jobsSummary: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                ProgressRow(
                    title: "Active jobs", detail: "\(model.summary.running) running, \(model.summary.pending) waiting",
                    fraction: model.summary.aggregateProgress)
                Button("Open Queue", action: actions.openQueue)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Active jobs summary")
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Text("Recent transcripts").font(DSTypography.headline).accessibilityAddTraits(.isHeader)
            if model.isLoadingRecent {
                ForEach(0..<3, id: \.self) { _ in Skeleton(height: 18) }
            } else if model.recent.isEmpty {
                Text("Nothing here yet.").foregroundStyle(DSColor.secondaryText)
            } else {
                ForEach(model.recent) { item in
                    Button {
                        actions.openTranscript(item.id)
                    } label: {
                        HStack {
                            Text(item.title).lineLimit(1)
                            Spacer()
                            Text(item.createdAt, style: .date).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.title)
                    .accessibilityHint("Opens in the Library")
                }
            }
        }
    }

    private var modelStatus: some View {
        HStack(spacing: DSSpacing.sm) {
            Image(systemName: "cpu").accessibilityHidden(true)
            Text("This Mac: \(model.hardwareDescription). Models run on-device.")
                .font(DSTypography.caption)
                .foregroundStyle(DSColor.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct QuickActionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void
    var isEnabled = true
    var caption: LocalizedStringKey?

    var body: some View {
        Button(action: action) {
            VStack(spacing: DSSpacing.xs) {
                Image(systemName: systemImage).font(.title2).accessibilityHidden(true)
                Text(title).font(DSTypography.body)
                if let caption { Text(caption).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText) }
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .padding(DSSpacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassBackground(radius: DSRadius.large, interactive: true)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
        .accessibilityHint(isEnabled ? "" : "Not available yet")
    }
}

#Preview("Home - empty") {
    HomeView(model: HomeModel(services: .preview()))
        .frame(width: 700, height: 480)
}

#Preview("Home - populated") {
    HomeView(model: HomeModel(services: .preview(transcripts: [Transcript(title: "Interview 12", source: .file)])))
        .frame(width: 700, height: 480)
}
