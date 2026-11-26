import AppCore
import DesignSystem
import FeatureSupport
import SwiftUI

/// Callbacks supplied by the shell; navigation does not start recording or download models.
public struct HomeActions {
    public var transcribeFile: () -> Void
    public var startLive: () -> Void
    public var openQueue: () -> Void
    public var openTranscript: (TranscriptID) -> Void
    public var openLibrary: () -> Void
    public var captureMeeting: () -> Void
    public var toggleDictation: (() -> Void)?

    public init(
        transcribeFile: @escaping () -> Void = {}, startLive: @escaping () -> Void = {}, openQueue: @escaping () -> Void = {},
        openTranscript: @escaping (TranscriptID) -> Void = { _ in }, openLibrary: @escaping () -> Void = {},
        captureMeeting: @escaping () -> Void = {}, toggleDictation: (() -> Void)? = nil
    ) {
        self.transcribeFile = transcribeFile
        self.startLive = startLive
        self.openQueue = openQueue
        self.openTranscript = openTranscript
        self.openLibrary = openLibrary
        self.captureMeeting = captureMeeting
        self.toggleDictation = toggleDictation
    }
}

/// Workbench: quick actions, a solid Recent sheet, and a queue summary alongside it (T35).
public struct HomeView: View {
    @State private var dropIsTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityPolicyOverride) private var policyOverride
    private let model: HomeModel
    private let actions: HomeActions

    public init(model: HomeModel, actions: HomeActions = HomeActions()) {
        self.model = model
        self.actions = actions
    }

    public var body: some View {
        GeometryReader { viewport in
            let layout = WorkbenchLayout(width: viewport.size.width, height: viewport.size.height)
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.md) {
                    if let message = model.errorMessage {
                        HStack(spacing: DSSpacing.md) {
                            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(DSColor.danger)
                            Spacer(minLength: DSSpacing.sm)
                            Button("Dismiss") { model.dismissError() }.buttonStyle(.plain)
                        }
                        .padding(DSSpacing.md).background(DSColor.danger.opacity(0.08), in: .rect(cornerRadius: DSRadius.card))
                    }
                    quickActions(columns: layout.actionColumns)
                    if let download = model.download {
                        ProgressRow(
                            title: "Downloading \(download.modelName)", detail: download.isVerifying ? "Verifying" : nil,
                            fraction: download.fraction
                        )
                        .padding(DSSpacing.md).dsSolidSurface(.inset)
                    }
                    if layout.showsSidePanel {
                        HStack(alignment: .top, spacing: DSSpacing.md) {
                            recentSheet(columns: layout.recentColumns, minimumHeight: layout.bodyMinimumHeight)
                                .frame(maxWidth: .infinity)
                            VStack(spacing: DSSpacing.md) {
                                workingSheet(minimumHeight: max(240, layout.bodyMinimumHeight - 90 - DSSpacing.md))
                                dropZone
                            }
                            .frame(width: layout.sidePanelWidth)
                        }
                    } else {
                        recentSheet(columns: layout.recentColumns, minimumHeight: 300)
                        workingSheet(minimumHeight: 220)
                        dropZone
                    }
                }
                .dsPanelInset()  // Same outer margins as Queue, Meetings, Live and Library.
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(DSColor.paper)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DSColor.paper)
        .navigationTitle("Home")
        .accessibilityIdentifier("home.workbench")
        .task { await model.run() }
        .dsAnimation(.settle, value: model.recent.map(\.id))
        .dsAnimation(.glide, value: model.summary)
    }

    private func quickActions(columns: Int) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: DSSpacing.md), count: columns), spacing: DSSpacing.md
        ) {
            action(
                "Transcribe a file", detail: "Audio or video, batch ready", symbol: .export, id: "home.transcribe",
                run: actions.transcribeFile)
            action("Live captions", detail: "Mic, system audio, or both", symbol: .liveCaptions, id: "home.live", run: actions.startLive)
            action(
                "Capture a meeting", detail: "Zoom and Teams, ask first", symbol: .record, id: "home.meeting", run: actions.captureMeeting)
            action(
                "Dictation", detail: "Speak into the focused app", symbol: .dictation, id: "home.dictation",
                run: actions.toggleDictation ?? {}
            )
            .disabled(actions.toggleDictation == nil)
            .help(actions.toggleDictation == nil ? "Configure dictation in Settings" : "Start or finish dictation")
        }
    }

    private func action(_ title: String, detail: String, symbol: DSSymbol, id: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(alignment: .leading, spacing: DSSpacing.lg) {
                DSIcon(symbol).font(.title2)
                    .frame(width: 42, height: 42).background(DSColor.accentTint, in: RoundedRectangle(cornerRadius: DSRadius.large))
                VStack(alignment: .leading, spacing: DSSpacing.xs) {
                    Text(title).font(DSTypography.headline)
                    Text(detail).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
            .padding(DSSpacing.lg)
            .dsSolidSurface(.sheet, radius: DSRadius.card)
            .contentShape(RoundedRectangle(cornerRadius: DSRadius.card))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func recentSheet(columns: Int, minimumHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            HStack {
                Text("Recent").font(DSTypography.title2).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Library", action: actions.openLibrary).buttonStyle(.plain).foregroundStyle(DSColor.accentText)
                    .accessibilityIdentifier("home.library")
            }
            if model.isLoadingRecent {
                ForEach(0..<3, id: \.self) { _ in Skeleton(height: 120) }
            } else if model.recent.isEmpty {
                EmptyState(
                    symbol: .library, title: "Nothing earmarked yet",
                    message: "Transcribe a file or start live captions. Your transcripts will appear here."
                )
                .frame(minHeight: 280)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DSSpacing.md), count: columns), spacing: DSSpacing.md) {
                    ForEach(model.recent.prefix(6)) { transcript in
                        Button {
                            actions.openTranscript(transcript.id)
                        } label: {
                            RecentTranscriptCard(transcript: transcript)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("home.recent.\(transcript.id)")
                        .dsTransition(.settle)
                    }
                }
            }
        }
        .padding(DSSpacing.xl)
        .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .topLeading)
        .dsSolidSurface(.sheet, radius: DSRadius.panel)
    }

    private func workingSheet(minimumHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            HStack {
                Text("Working on").font(DSTypography.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                if model.summary.isActive {
                    Button("Queue", action: actions.openQueue).buttonStyle(.plain).foregroundStyle(DSColor.accentText)
                }
            }
            if model.activeJobs.isEmpty {
                Text("All caught up.").font(DSTypography.title).foregroundStyle(DSColor.secondaryText)
                Text("Add a file when you are ready. Everything stays on this Mac.").foregroundStyle(DSColor.secondaryText)
            } else {
                ForEach(model.activeJobs.prefix(5)) { job in
                    ProgressRow(
                        title: job.input?.lastPathComponent ?? "Transcription", detail: job.state == .pending ? "Waiting" : "Transcribing",
                        fraction: job.progress)
                }
                Text("\(model.summary.running) running · \(model.summary.pending) waiting")
                    .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
            }
            Spacer(minLength: DSSpacing.xl)
            Divider()
            if let status = model.modelStatus {
                Text(status.isInstalled ? "\(status.name) is ready." : "\(status.name) is available to download.")
                    .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
            }
            Text("\(model.hardwareDescription) · On-device processing")
                .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
        }
        .padding(DSSpacing.xl)
        .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .topLeading)
        .dsSolidSurface(.sheet, radius: DSRadius.panel)
        .accessibilityIdentifier("home.working")
    }

    private var dropZone: some View {
        HStack(spacing: DSSpacing.md) {
            DSIcon(.export).font(.title2)
            VStack(alignment: .leading) {
                Text("Drop files anywhere").font(DSTypography.headline)
                Text("to start transcribing").font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(DSSpacing.lg)
        .frame(maxWidth: .infinity, minHeight: 90)
        .background(dropIsTargeted ? DSColor.accentTint : DSColor.insetBackground, in: RoundedRectangle(cornerRadius: DSRadius.card))
        .overlay(
            RoundedRectangle(cornerRadius: DSRadius.card).strokeBorder(
                DSColor.accentText.opacity(dropIsTargeted ? 1 : 0.5), style: StrokeStyle(lineWidth: dropIsTargeted ? 2 : 1, dash: [3, 3]))
        )
        .dropDestination(for: URL.self) { urls, _ in
            Task { if await model.enqueue(urls) { actions.openQueue() } }
            return !urls.isEmpty
        } isTargeted: {
            dropIsTargeted = $0
        }
        .scaleEffect(dropIsTargeted && !(policyOverride?.suppressesMotion ?? reduceMotion) ? 1.015 : 1)
        .dsAnimation(.glide, value: dropIsTargeted)
        .accessibilityLabel("Drop audio, video or folders to transcribe")
        .accessibilityIdentifier("home.dropZone")
    }
}

/// Real transcript metadata in the same Inset card geometry used by the Library grid.
struct RecentTranscriptCard: View {
    let transcript: Transcript

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            HStack {
                Text(Duration.seconds(transcript.duration), format: .time(pattern: .minuteSecond)).font(DSTypography.timestamp)
                Text(transcript.createdAt, style: .date).font(DSTypography.caption)
                Spacer(minLength: 0)
            }
            .foregroundStyle(DSColor.secondaryText)
            Text(transcript.title).font(DSTypography.headline).lineLimit(2)
            Text(transcript.speakers.isEmpty ? "Saved on this Mac" : transcript.speakers.map(\.name).joined(separator: ", "))
                .font(DSTypography.transcript).foregroundStyle(DSColor.secondaryText).lineLimit(2)
            HStack {
                ForEach(transcript.languages.sorted().prefix(3), id: \.self) { LanguageBadge($0) }
                Spacer(minLength: 0)
                DSIcon(.earmark).foregroundStyle(DSColor.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .padding(DSSpacing.lg)
        .dsSolidSurface(.inset, radius: DSRadius.card)
        .contentShape(RoundedRectangle(cornerRadius: DSRadius.card))
    }
}

/// Workbench proportions derive from the detail column, rather than a fixed screen-width assumption.
public struct WorkbenchLayout: Equatable, Sendable {
    public var width: CGFloat
    public var height: CGFloat

    public init(width: CGFloat, height: CGFloat) {
        self.width = max(0, width)
        self.height = max(0, height)
    }

    /// Outer margin, identical to `dsPanelInset()` on every other page (the top edge is thinner because the toolbar already insets).
    public var inset: CGFloat { DSSpacing.md }
    public var actionColumns: Int { width >= 1000 ? 4 : (width >= 560 ? 2 : 1) }
    public var showsSidePanel: Bool { width >= 1000 }
    public var sidePanelWidth: CGFloat { min(400, max(280, width * 0.28)) }
    public var recentColumns: Int {
        let available = width - 2 * inset - (showsSidePanel ? sidePanelWidth + DSSpacing.md : 0) - 2 * DSSpacing.xl
        return max(1, min(4, Int(available / (280 + DSSpacing.md))))
    }
    public var bodyMinimumHeight: CGFloat { max(360, height - (DSSpacing.xs + inset) - 112 - 2 * DSSpacing.lg - DSSpacing.md) }
}
