import AppCore
import DesignSystem
import FeatureSupport
import SwiftUI

/// Queue: job rows with progress, ETA, engine and per-state actions; empty state when idle.
public struct QueueView: View {
    @Bindable private var model: QueueModel

    public init(model: QueueModel) { self.model = model }

    public var body: some View {
        Group {
            if model.isLoading {
                VStack(alignment: .leading, spacing: DSSpacing.md) {
                    ForEach(0..<3, id: \.self) { _ in Skeleton(height: 28) }
                    Spacer()
                }
                .padding(DSSpacing.xl)
            } else if model.jobs.isEmpty {
                EmptyState(
                    systemImage: "tray.full", title: "Queue is empty",
                    message: "Files you add are processed one after another. Drop files on the window to start.")
            } else {
                List {
                    ForEach(model.jobs) { job in
                        QueueRow(job: job, model: model)
                    }
                    .onMove(perform: model.move)
                }
                .accessibilityLabel("Transcription queue")
            }
        }
        .navigationTitle("Queue")
        .toolbar {
            ToolbarItem {
                Stepper("Parallel jobs: \(model.maxConcurrency)", value: $model.maxConcurrency, in: 1...4)
                    .onChange(of: model.maxConcurrency) { model.applyConcurrency() }
                    .accessibilityHint("Number of jobs processed at the same time")
            }
        }
        .task { await model.run() }
    }
}

private struct QueueRow: View {
    let job: Job
    let model: QueueModel

    var body: some View {
        HStack(spacing: DSSpacing.md) {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                ProgressRow(
                    title: job.input?.lastPathComponent ?? "Job", detail: detail,
                    fraction: job.state == .running || job.state == .paused ? job.progress : nil)
                if let reason = job.failureReason { Text(reason).font(DSTypography.caption).foregroundStyle(DSColor.danger) }
            }
            StatusPill(state: job.state)
            actionButtons
        }
        .accessibilityElement(children: .contain)
    }

    private var detail: String {
        var parts: [String] = []
        if let engine = job.engine { parts.append(engine.rawValue) }
        if case .single(let language) = job.settings.languageMode { parts.append(language.rawValue.uppercased()) }
        if let eta = job.etaSeconds, job.state == .running { parts.append("about \(Int(eta / 60) + 1) min left") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var actionButtons: some View {
        switch job.state {
        case .pending, .running:
            Button("Pause", systemImage: "pause.fill") { model.pause(job.id) }.labelStyle(.iconOnly)
            Button("Cancel", systemImage: "xmark") { model.cancel(job.id) }.labelStyle(.iconOnly)
        case .paused:
            Button("Resume", systemImage: "play.fill") { model.resume(job.id) }.labelStyle(.iconOnly)
            Button("Cancel", systemImage: "xmark") { model.cancel(job.id) }.labelStyle(.iconOnly)
        case .failed, .cancelled:
            Button("Retry", systemImage: "arrow.clockwise") { model.retry(job.id) }.labelStyle(.iconOnly)
        case .completed:
            EmptyView()
        }
    }
}

#Preview("Queue - empty") { QueueView(model: QueueModel(services: .preview())).frame(width: 640, height: 400) }

#Preview("Queue - jobs") {
    QueueView(
        model: QueueModel(
            services: .preview(jobs: [
                Job(kind: .transcribeFile, state: .running, input: URL(fileURLWithPath: "/tmp/interview.m4a"), progress: 0.4),
                Job(
                    kind: .transcribeFile, state: .failed, input: URL(fileURLWithPath: "/tmp/talk.mp4"),
                    failureReason: "Model failed to load"),
            ]))
    )
    .frame(width: 640, height: 400)
}
