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

    public init(model: QueueModel, onOpenTranscript: @escaping (TranscriptID) -> Void = { _ in }) {
        self.model = model
        self.onOpenTranscript = onOpenTranscript
    }

    public var body: some View {
        content
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
                        Section(group.title) {
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
                        }
                    }
                }
                .accessibilityLabel("Transcription queue")
            }
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button("Add Files…", systemImage: "plus") { isImporterPresented = true }
                .help("Add audio or video files or folders")
            Menu("Queue Actions", systemImage: "ellipsis.circle") {
                Button("Pause All", systemImage: "pause.fill") { Task { await model.pauseAll() } }
                Button("Resume All", systemImage: "play.fill") { Task { await model.resumeAll() } }
                Button("Retry Failed", symbol: .retry) { Task { await model.retryAllFailed() } }
            }
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
        HStack(spacing: DSSpacing.md) {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                ProgressRow(
                    title: job.input?.lastPathComponent ?? "Job", detail: QueueFormatting.detail(for: job),
                    fraction: job.state == .running || job.state == .paused ? job.progress : nil)
                if let reason = job.failureReason { Text(reason).font(DSTypography.caption).foregroundStyle(DSColor.danger) }
            }
            StatusPill(state: job.state)
            actionButtons
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(job.input?.lastPathComponent ?? "Job")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        var parts = [job.state.rawValue]
        if job.state == .running || job.state == .paused { parts.append("\(Int(job.progress * 100)) percent") }
        if let reason = job.failureReason { parts.append(reason) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder private var actionButtons: some View {
        switch job.state {
        case .pending, .running:
            Button("Pause", systemImage: "pause.fill") { Task { await model.pause(job.id) } }.labelStyle(.iconOnly)
            Button("Cancel", systemImage: "xmark") { Task { await model.cancel(job.id) } }.labelStyle(.iconOnly)
        case .paused:
            Button("Resume", systemImage: "play.fill") { Task { await model.resume(job.id) } }.labelStyle(.iconOnly)
            Button("Cancel", systemImage: "xmark") { Task { await model.cancel(job.id) } }.labelStyle(.iconOnly)
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
