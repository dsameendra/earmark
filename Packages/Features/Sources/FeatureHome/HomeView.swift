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
    private let model: HomeModel
    private let actions: HomeActions
    @Environment(\.shellLayout) private var layout

    public init(model: HomeModel, actions: HomeActions = HomeActions()) {
        self.model = model
        self.actions = actions
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpacing.md) {
                if let message = model.errorMessage {
                    ErrorState(message: message) { model.dismissError() }.frame(maxHeight: 120)
                }
                quickActions
                if let download = model.download {
                    ProgressRow(
                        title: "Downloading \(download.modelName)", detail: download.isVerifying ? "Verifying" : nil,
                        fraction: download.fraction
                    )
                    .padding(DSSpacing.md).dsSolidSurface(.inset)
                }
                if layout.widthClass == .regular {
                    HStack(alignment: .top, spacing: DSSpacing.md) {
                        recentSheet.frame(maxWidth: .infinity)
                        VStack(spacing: DSSpacing.md) {
                            workingSheet
                            dropZone
                        }.frame(width: 320)
                    }
                } else {
                    recentSheet
                    workingSheet
                    dropZone
                }
            }
            .padding(DSSpacing.md)
        }
        .background(DSColor.paper)
        .navigationTitle("Home")
        .accessibilityIdentifier("home.workbench")
        .task { await model.run() }
    }

    private var quickActions: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: DSSpacing.md), count: layout.homeActionColumns), spacing: DSSpacing.md
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

    private var recentSheet: some View {
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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: DSSpacing.md)], spacing: DSSpacing.md) {
                    ForEach(model.recent.prefix(6)) { transcript in
                        Button {
                            actions.openTranscript(transcript.id)
                        } label: {
                            RecentTranscriptCard(transcript: transcript)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("home.recent.\(transcript.id)")
                    }
                }
            }
        }
        .padding(DSSpacing.xl)
        .frame(maxWidth: .infinity, minHeight: 440, alignment: .topLeading)
        .dsSolidSurface(.sheet, radius: DSRadius.panel)
    }

    private var workingSheet: some View {
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
        .frame(maxWidth: .infinity, minHeight: 330, alignment: .topLeading)
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
        .frame(maxWidth: .infinity)
        .background(DSColor.insetBackground, in: RoundedRectangle(cornerRadius: DSRadius.card))
        .overlay(
            RoundedRectangle(cornerRadius: DSRadius.card).strokeBorder(
                DSColor.accentText.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        )
        .dropDestination(for: URL.self) { urls, _ in
            Task { if await model.enqueue(urls) { actions.openQueue() } }
            return !urls.isEmpty
        }
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
