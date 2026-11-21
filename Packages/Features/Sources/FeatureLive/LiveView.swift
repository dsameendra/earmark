import AppCore
import DesignSystem
import FeatureSupport
import SwiftUI

/// Live: source selection and Start before a session; a caption list (volatile text styled distinctly) while running.
public struct LiveView: View {
    @Bindable private var model: LiveModel

    public init(model: LiveModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            captions
        }
        .navigationTitle("Live")
        .task { await model.watchState() }
        .task { await model.watchLines() }
    }

    private var controls: some View {
        HStack(spacing: DSSpacing.md) {
            Picker("Source", selection: $model.source) {
                ForEach(LiveSourceChoice.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(model.isRunning)
            .frame(maxWidth: 380)
            Spacer()
            if model.isRunning {
                RecordingIndicator(label: "Live")
                Button("Stop", systemImage: "stop.fill") { Task { await model.stop() } }
                    .keyboardShortcut(.return, modifiers: [.command])
            } else {
                Button("Start", systemImage: "play.fill") { Task { await model.start() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(DSSpacing.lg)
    }

    @ViewBuilder private var captions: some View {
        if case .failed(let message) = model.state {
            ErrorState(title: "Live captions stopped", message: message) { Task { await model.start() } }
        } else if model.lines.isEmpty {
            EmptyState(
                systemImage: "captions.bubble", title: "No live session",
                message: "Choose a source and press Start. Captions appear here as people speak.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DSSpacing.sm) {
                    ForEach(model.lines) { line in
                        CaptionLineView(line: line)
                    }
                }
                .padding(DSSpacing.lg)
            }
            .defaultScrollAnchor(.bottom)
        }
    }
}

/// A single caption line; volatile (not yet final) text is italic and secondary.
struct CaptionLineView: View {
    let line: CaptionLine

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xxs) {
            if let label = line.speakerLabel { SpeakerChip(name: label, slot: line.speakerSlot ?? 0) }
            Text(line.text)
                .font(DSTypography.body)
                .italic(line.isVolatile)
                .foregroundStyle(line.isVolatile ? DSColor.secondaryText : DSColor.primaryText)
            if let translation = line.translation { Text(translation).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(line.isVolatile ? "In progress" : "")
    }
}

#Preview("Live - idle") { LiveView(model: LiveModel(services: .preview())).frame(width: 640, height: 400) }
