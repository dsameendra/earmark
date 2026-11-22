import AppCore
import DesignSystem
import FeatureSupport
import SwiftUI
import UniformTypeIdentifiers

/// Queue: sections of job rows with progress, ETA, engine, language and per-state actions; batch add with settings sheet.
public struct QueueView: View {
    @Bindable private var model: QueueModel
    private let onOpenTranscript: (TranscriptID) -> Void
    @State private var isImporterPresented = false
    @State private var confirmsClearQueue = false

    public init(model: QueueModel, onOpenTranscript: @escaping (TranscriptID) -> Void = { _ in }) {
        self.model = model
        self.onOpenTranscript = onOpenTranscript
    }

    public var body: some View {
        content
            .padding(DSSpacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .dsSolidSurface(.sheet, radius: DSRadius.panel)
            .padding(DSSpacing.md)
            .background(DSColor.paper)
            .navigationTitle("Queue")
            .toolbar { toolbarContent }
            .dropDestination(for: URL.self) { urls, _ in
                model.presentBatch(urls: urls)
                return !urls.isEmpty
            }
            .fileImporter(
                isPresented: $isImporterPresented, allowedContentTypes: [.audiovisualContent, .folder], allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result { model.presentBatch(urls: urls) }
            }
            .sheet(item: $model.batch) { batch in
                BatchSettingsSheet(model: batch, onCancel: { model.batch = nil }, onAdd: { Task { await model.submitBatch() } })
            }
            .task { await model.run() }
            .dsAnimation(.settle, value: model.jobs.map { "\($0.id):\($0.state.rawValue)" })
            .confirmationDialog("Clear the queue?", isPresented: $confirmsClearQueue) {
                Button("Cancel active work and clear queue", role: .destructive) { Task { await model.clearQueue() } }
            } message: {
                Text("Active jobs will stop. Saved transcripts, partial transcripts and source recordings stay in your Library.")
            }
    }

    @ViewBuilder private var content: some View {
        if model.isLoading {
            VStack(alignment: .leading, spacing: DSSpacing.md) {
                ForEach(0..<3, id: \.self) { _ in Skeleton(height: 44) }
                Spacer()
            }
            .padding(DSSpacing.xl)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading queue")
        } else if model.jobs.isEmpty {
            EmptyState(
                systemImage: DSSymbol.queue.systemImageName, title: "Queue is empty",
                message: "Files you add are processed one after another. Drop files or folders here, or add them.",
                actionTitle: "Add Files…"
            ) { isImporterPresented = true }
        } else {
            VStack(spacing: 0) {
                if let message = model.errorMessage {
                    HStack {
                        Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(DSColor.danger)
                        Spacer()
                        Button("Dismiss") { model.dismissError() }
                    }
                    .padding(DSSpacing.md)
                }
                List {
                    ForEach(model.visibleGroups) { group in
                        Section {
                            if group == .pending {
                                ForEach(model.jobs(in: group)) { job in
                                    QueueRow(job: job, model: model, onOpenTranscript: onOpenTranscript)
                                }
                                .onMove { source, destination in Task { await model.movePending(from: source, to: destination) } }
                            } else {
                                ForEach(model.jobs(in: group)) { job in
                                    QueueRow(job: job, model: model, onOpenTranscript: onOpenTranscript)
                                }
                            }
                        } header: {
                            Text(group.title).font(DSTypography.title2).foregroundStyle(DSColor.primaryText)
                                .padding(.top, DSSpacing.sm).padding(.bottom, DSSpacing.xs)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .listRowSeparator(.hidden)
                .accessibilityLabel("Transcription queue")
            }
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button("Add Files…", systemImage: "plus") { isImporterPresented = true }
                .help("Add audio or video files or folders")
                .accessibilityIdentifier("queue.add")
            Button("Clear Finished", systemImage: "checkmark.circle") { Task { await model.clearFinished() } }
                .labelStyle(.titleAndIcon)
                .disabled(!model.hasFinished || model.isClearing)
                .help("Remove completed and cancelled jobs from the queue. Transcripts stay in the Library.")
                .accessibilityIdentifier("queue.clearFinished")
            Menu("Queue Actions", systemImage: "ellipsis.circle") {
                Button("Pause All", systemImage: "pause.fill") { Task { await model.pauseAll() } }
                    .disabled(!model.hasActive || model.isClearing)
                Button("Resume All", systemImage: "play.fill") { Task { await model.resumeAll() } }
                    .disabled(model.jobs(in: .paused).isEmpty || model.isClearing)
                Button("Retry Failed", symbol: .retry) { Task { await model.retryAllFailed() } }
                    .disabled(model.jobs(in: .failed).isEmpty || model.isClearing)
                Divider()
                Button("Clear Queue…", systemImage: "xmark.circle", role: .destructive) { confirmsClearQueue = true }
                    .disabled(model.jobs.isEmpty || model.isClearing)
                    .accessibilityIdentifier("queue.clearAll")
            }
            .accessibilityIdentifier("queue.actions")
            Stepper(
                "Parallel jobs: \(model.maxConcurrency)",
                value: Binding(get: { model.maxConcurrency }, set: { value in Task { await model.setConcurrency(value) } }), in: 1...4
            )
            .accessibilityHint("Number of jobs processed at the same time")
        }
    }
}

extension BatchSettingsModel: Identifiable {
    public nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}

private struct QueueRow: View {
    let job: Job
    let model: QueueModel
    let onOpenTranscript: (TranscriptID) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DSSpacing.md) {
                fileIcon
                titleColumn.frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
                progressColumn.frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
                rowActions
            }
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                HStack(spacing: DSSpacing.sm) {
                    fileIcon
                    titleColumn
                    Spacer(minLength: 0)
                    StatusPill(state: job.state)
                }
                progressColumn
                HStack {
                    Spacer()
                    actionButtons
                    removeButton
                }
            }
        }
        .disabled(model.removingIDs.contains(job.id) || model.isClearing)
        .padding(DSSpacing.md)
        .background(
            job.state == .failed ? DSColor.danger.opacity(0.08) : DSColor.insetBackground,
            in: RoundedRectangle(cornerRadius: DSRadius.medium)
        )
        .listRowSeparator(.hidden)
        .listRowBackground(DSColor.contentBackground)
        .accessibilityIdentifier("queue.job.\(job.id)")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(job.input?.lastPathComponent ?? "Job")
        .accessibilityValue(accessibilityValue)
    }

    private var fileIcon: some View {
        DSIcon(.waveform).font(DSTypography.title2)
            .frame(width: 38, height: 38)
            .background(DSColor.paper, in: RoundedRectangle(cornerRadius: DSRadius.medium))
            .accessibilityHidden(true)
    }

    private var titleColumn: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text(job.input?.lastPathComponent ?? "Job").font(DSTypography.body.weight(.medium)).lineLimit(1)
            Text(QueueFormatting.detail(for: job)).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText).lineLimit(2)
        }
    }

    private var progressColumn: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            if QueueFormatting.showsProgress(for: job.state) {
                ProgressView(value: QueueFormatting.fraction(job.progress))
                    .tint(job.state == .paused ? DSColor.secondaryText : DSColor.accent)
                    .accessibilityLabel(job.state == .paused ? "Paused progress" : "Progress")
                    .accessibilityIdentifier("queue.progress.\(job.id)")
                Text(QueueFormatting.fraction(job.progress), format: .percent.precision(.fractionLength(0)))
                    .font(DSTypography.timestamp).foregroundStyle(DSColor.secondaryText)
            }
            if let reason = job.failureReason {
                Text(reason).font(DSTypography.caption).foregroundStyle(DSColor.danger).lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rowActions: some View {
        HStack(spacing: DSSpacing.sm) {
            StatusPill(state: job.state)
            actionButtons
            removeButton
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var removeButton: some View {
        Button {
            Task { await model.remove(job.id) }
        } label: {
            Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .frame(minWidth: DSLayout.minControlHeight, minHeight: DSLayout.minControlHeight)
        .help(job.state == .running || job.state == .pending ? "Cancel and remove from queue" : "Remove from queue")
        .accessibilityLabel(job.state == .running || job.state == .pending ? "Cancel and remove from queue" : "Remove from queue")
        .accessibilityIdentifier("queue.remove.\(job.id)")
    }

    private var accessibilityValue: String {
        var parts = [job.state.rawValue]
        if job.state == .running || job.state == .paused { parts.append("\(Int(QueueFormatting.fraction(job.progress) * 100)) percent") }
        if let reason = job.failureReason { parts.append(reason) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder private var actionButtons: some View {
        switch job.state {
        case .pending, .running:
            Button("Pause", systemImage: "pause.fill") { Task { await model.pause(job.id) } }.labelStyle(.iconOnly)
            Button("Cancel", systemImage: "stop.fill") { Task { await model.cancel(job.id) } }.labelStyle(.iconOnly)
        case .paused:
            Button("Resume", systemImage: "play.fill") { Task { await model.resume(job.id) } }.labelStyle(.iconOnly)
            Button("Cancel", systemImage: "stop.fill") { Task { await model.cancel(job.id) } }.labelStyle(.iconOnly)
        case .failed, .cancelled:
            Button("Retry", symbol: .retry) { Task { await model.retry(job.id) } }.labelStyle(.iconOnly)
        case .completed:
            if let id = job.transcriptID { Button("Open Transcript") { onOpenTranscript(id) } }
        }
    }
}

#Preview("Queue - empty") { QueueView(model: QueueModel(services: .preview())).frame(width: 640, height: 400) }

#Preview("Queue - jobs") {
    QueueView(
        model: QueueModel(
            services: .preview(jobs: [
                Job(
                    kind: .transcribeFile, state: .running, input: URL(fileURLWithPath: "/tmp/interview.m4a"), progress: 0.4,
                    etaSeconds: 130, engine: "whisperkit"),
                Job(kind: .transcribeFile, state: .pending, input: URL(fileURLWithPath: "/tmp/a.m4a")),
                Job(
                    kind: .transcribeFile, state: .failed, input: URL(fileURLWithPath: "/tmp/talk.mp4"),
                    failureReason: "Model failed to load"),
            ]))
    )
    .frame(width: 640, height: 400)
}
