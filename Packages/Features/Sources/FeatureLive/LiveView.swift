import AppCore
import DesignSystem
import FeatureSupport
import LiveCaptions
import SwiftUI

/// Symbols used by the Live screen, named through an enum (rule A3) so M8 can swap in `DSSymbol`.
enum LiveSymbol {
    static let start = "play.fill"
    static let stop = "stop.fill"
    static let pause = "pause.fill"
    static let resume = "play.fill"
    static let empty = "captions.bubble"
    static let overlay = "rectangle.bottomthird.inset.filled"
    static let notice = "exclamationmark.triangle"
    static let saved = "checkmark.circle"
}

/// Live: source and language selection and Start before a session; a caption list (volatile text styled distinctly,
/// speaker chips) with a level meter, overlay controls and "Save as transcript" alongside it.
public struct LiveView: View {
    @Bindable private var model: LiveModel

    public init(model: LiveModel) { self.model = model }

    public var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                controls
                if let notice = model.notice, notice.kind != .resumed { noticeBanner(notice) }
                Divider()
                captions
            }
            Divider()
            sidePanel
                .frame(width: 280)
        }
        .navigationTitle("Live")
        .task { await model.loadPreferences() }
        .task { await model.watchState() }
        .task { await model.watchLines() }
        .task { await model.watchLevels() }
        .task { await model.watchNotices() }
        .task { await model.watchDevices() }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: DSSpacing.md) {
            Picker("Source", selection: $model.source) {
                ForEach(LiveSourceChoice.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(model.isRunning)
            .frame(maxWidth: 380)
            .accessibilityIdentifier("live.source")
            Spacer()
            if model.isRunning {
                if model.isPaused {
                    StatusPill("Paused", systemImage: LiveSymbol.pause, tone: .warning)
                } else {
                    RecordingIndicator(label: "Live")
                }
                if model.hasExtras {
                    Button(model.isPaused ? "Resume" : "Pause", systemImage: model.isPaused ? LiveSymbol.resume : LiveSymbol.pause) {
                        Task { await model.togglePause() }
                    }
                    .accessibilityIdentifier("live.pause")
                }
                Button("Stop", systemImage: LiveSymbol.stop) { Task { await model.stop() } }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .accessibilityIdentifier("live.stop")
            } else {
                Button("Start", systemImage: LiveSymbol.start) { Task { await model.start() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(model.startDisabledReason != nil)
                    .help(model.startDisabledReason ?? "Start live captions")
                    .accessibilityIdentifier("live.start")
            }
        }
        .padding(DSSpacing.lg)
    }

    private func noticeBanner(_ notice: LiveNotice) -> some View {
        HStack(spacing: DSSpacing.sm) {
            Image(systemName: LiveSymbol.notice).accessibilityHidden(true)
            Text(notice.message).font(DSTypography.caption)
            Spacer()
        }
        .foregroundStyle(notice.kind == .problem ? DSColor.danger : DSColor.secondaryText)
        .padding(.horizontal, DSSpacing.lg)
        .padding(.bottom, DSSpacing.sm)
        .accessibilityIdentifier("live.notice")
    }

    // MARK: Captions

    @ViewBuilder private var captions: some View {
        if case .failed(let message) = model.state {
            ErrorState(title: "Live captions stopped", message: message) { Task { await model.start() } }
        } else if model.lines.isEmpty {
            EmptyState(
                systemImage: LiveSymbol.empty, title: model.isRunning ? "Listening" : "No live session",
                message: model.isRunning
                    ? "Captions appear here as people speak."
                    : "Choose a source and press Start. Captions appear here as people speak.")
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
            .accessibilityIdentifier("live.transcript")
        }
    }

    // MARK: Side panel

    private var sidePanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpacing.lg) {
                section("Input") {
                    if model.source.usesMicrophone {
                        Picker("Microphone", selection: $model.deviceUID) {
                            Text("System Default").tag(String?.none)
                            ForEach(model.devices) { Text($0.name).tag(String?.some($0.id)) }
                        }
                        .disabled(model.isRunning)
                        .accessibilityIdentifier("live.device")
                    }
                    Picker("Language", selection: $model.language) {
                        ForEach(LiveLanguageChoice.allCases) { Text($0.title).tag($0) }
                    }
                    .disabled(model.isRunning)
                    .accessibilityIdentifier("live.language")
                    LevelMeter(level: model.level)
                        .accessibilityLabel("Input level")
                        .accessibilityValue("\(Int(model.level * 100)) percent")
                        .accessibilityIdentifier("live.levelMeter")
                }
                section("Transcript") {
                    Toggle("Save as transcript", isOn: $model.saveAsTranscript)
                        .disabled(model.isRunning)
                        .accessibilityIdentifier("live.saveAsTranscript")
                    if model.savedTranscriptID != nil {
                        Label("Saved to your library", systemImage: LiveSymbol.saved)
                            .font(DSTypography.caption)
                            .foregroundStyle(DSColor.secondaryText)
                            .accessibilityIdentifier("live.saved")
                    }
                }
                if model.hasExtras { overlaySection }
            }
            .padding(DSSpacing.lg)
        }
    }

    private var overlaySection: some View {
        section("Caption overlay") {
            Toggle(
                "Show overlay",
                isOn: Binding(get: { model.overlayEnabled }, set: { value in Task { await model.setOverlayEnabled(value) } })
            )
            .accessibilityIdentifier("live.overlay")
            Picker(
                "Preset",
                selection: Binding(get: { model.preset.id }, set: { id in Task { await model.selectPreset(id) } })
            ) {
                ForEach(model.presets) { Text($0.name).tag($0.id) }
            }
            .accessibilityIdentifier("live.preset")
            CaptionPresetControls(preset: Binding(get: { model.preset }, set: { model.updatePreset($0) }))
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Text(title).font(DSTypography.headline)
            content()
        }
    }
}

/// Horizontal input level bar.
struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(DSColor.contentBackground)
                Capsule().fill(DSColor.accent).frame(width: proxy.size.width * CGFloat(min(1, max(0, level))))
            }
        }
        .frame(height: 6)
        .overlay(Capsule().strokeBorder(DSColor.hairline, lineWidth: 0.5))
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

#Preview("Live - idle") { LiveView(model: LiveModel(services: .preview())).frame(width: 920, height: 520) }
