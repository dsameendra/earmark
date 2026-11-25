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
    static let empty = DSSymbol.liveCaptions
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
        GeometryReader { viewport in
            let sizing = LiveWorkspaceLayout(width: viewport.size.width)
            // Two separate solid panels: the captions, and the controls panel on the right. The panel has a fixed width and
            // its own scrolling, and its content is built to fit that width, so nothing is cut off at the window edge.
            Group {
                if sizing.stacksPanels {
                    VStack(spacing: DSSpacing.md) {
                        captionPane.livePanelSurface()
                        sidePanel.frame(height: 280).livePanelSurface()
                    }
                } else {
                    HStack(alignment: .top, spacing: DSSpacing.md) {
                        captionPane.livePanelSurface()
                        sidePanel.frame(width: sizing.sidePanelWidth).livePanelSurface()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .dsPanelInset()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DSColor.paper)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("live.surface")
        .toolbar { toolbarControls }
        .navigationTitle("Live")
        .task { await model.loadPreferences() }
        .task { await model.watchState() }
        .task { await model.watchLines() }
        .task { await model.watchLevels() }
        .task { await model.watchNotices() }
        .task { await model.watchDevices() }
        .task { await model.watchLanguageChoices() }
        .task { await model.permissionGate.load() }
    }

    private var captionPane: some View {
        VStack(spacing: 0) {
            if !model.isRunning {
                PermissionGateBanner(
                    model: model.permissionGate, feature: "Live captions", identifier: "live.permissions",
                    relevant: model.source.requiredPermissions
                )
                .padding([.horizontal, .top], DSSpacing.lg)
            }
            if let notice = model.notice, notice.kind != .resumed { noticeBanner(notice) }
            captions.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DSColor.contentBackground)
    }

    // MARK: Controls

    /// Functional groups: [Source] | [status] | [Pause, Stop or Start]. System glass supplies padding and height.
    @ToolbarContentBuilder private var toolbarControls: some ToolbarContent {
        ToolbarItem { sourcePicker }
        if model.isRunning {
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Group {
                    if model.isPaused {
                        StatusPill("Paused", systemImage: LiveSymbol.pause, tone: .warning)
                    } else {
                        RecordingIndicator(label: "Live").padding(.horizontal, DSSpacing.md)
                    }
                }
                .padding(.horizontal, DSSpacing.xs)
            }
        }
        ToolbarSpacer(.fixed)
        if model.isRunning {
            if model.hasExtras {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await model.togglePause() }
                    } label: {
                        DSToolbarLabel(model.isPaused ? "Resume" : "Pause", systemImage: model.isPaused ? LiveSymbol.resume : LiveSymbol.pause)
                    }
                    .labelStyle(.titleAndIcon)
                    .dsToolbarControl()
                    .help(model.isPaused ? "Resume live captions" : "Pause live captions")
                    .accessibilityIdentifier("live.pause")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await model.stop() } } label: { DSToolbarLabel("Stop", systemImage: LiveSymbol.stop) }
                    .labelStyle(.titleAndIcon)
                    .dsToolbarControl()
                    .keyboardShortcut(.return, modifiers: [.command])
                    .help("Stop live captions")
                    .accessibilityIdentifier("live.stop")
            }
        } else {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await model.start() } } label: { DSToolbarLabel("Start", systemImage: LiveSymbol.start) }
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.borderedProminent)
                    .dsToolbarControl()
                    .tint(DSColor.accent)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(model.startDisabledReason != nil)
                    .help(model.startDisabledReason ?? "Start live captions")
                    .accessibilityIdentifier("live.start")
            }
        }
    }

    /// Short labels let the toolbar size the segmented control itself, at any window width.
    private var sourcePicker: some View {
        DSSegmentedControl(
            selection: $model.source,
            options: [
                .init("Mic", value: LiveSourceChoice.mic), .init("System", value: LiveSourceChoice.system),
                .init("Both", value: LiveSourceChoice.micAndSystem),
            ],
            identifier: "live.source"
        )
        .padding(.horizontal, DSSpacing.xs)
        .help(model.isRunning ? "Stop captioning to change the source" : "Caption source: microphone, system audio or both")
        .disabled(model.isRunning)
        .accessibilityLabel("Source")
    }

    private func noticeBanner(_ notice: LiveNotice) -> some View {
        HStack(spacing: DSSpacing.sm) {
            Image(systemName: LiveSymbol.notice).accessibilityHidden(true)
            Text(notice.message).font(DSTypography.caption)
            Spacer()
        }
        .foregroundStyle(notice.kind == .problem ? DSColor.danger : DSColor.secondaryText)
        .padding(.horizontal, DSSpacing.lg)
        .padding(.vertical, DSSpacing.md)
        .accessibilityIdentifier("live.notice")
    }

    // MARK: Captions

    @ViewBuilder private var captions: some View {
        if case .failed(let message) = model.state {
            ErrorState(title: "Live captions stopped", message: message) { Task { await model.start() } }
        } else if model.lines.isEmpty {
            EmptyState(
                symbol: LiveSymbol.empty, title: model.isRunning ? "Listening" : "No live session",
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
                .padding(DSSpacing.xl)
                .frame(maxWidth: 1000, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            .accessibilityIdentifier("live.transcript")
            .dsAnimation(.settle, value: model.lines.map(\.id))
        }
    }

    // MARK: Side panel

    /// Solid inspector column: one InsetCard per concern (input, session, translation, speakers, overlay). The cards
    /// scroll as one column so nothing is clipped at small heights; controls always get the full card width.
    private var sidePanel: some View {
        let summary = LiveSessionSummary(lines: model.lines)
        return ScrollView {
            VStack(alignment: .leading, spacing: DSSpacing.lg) {
                panelSection("Input") { inputCard }
                panelSection("Session") { sessionCard(summary) }
                panelSection("Translation") { translationCard(summary) }
                panelSection("Speakers") { speakersCard(summary) }
                if model.hasExtras { panelSection("Caption overlay") { overlayCard } }
                Text("Captions stay on this Mac. Final lines settle in place as you speak.")
                    .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, DSSpacing.xs)
            }
            .padding(DSSpacing.md)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.automatic)
        .frame(maxHeight: .infinity)
        .accessibilityIdentifier("live.sidebar")
    }

    private func panelSection<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            SectionCaption(title).padding(.horizontal, DSSpacing.xs)
            InsetCard(padding: DSSpacing.md) {
                VStack(alignment: .leading, spacing: DSSpacing.md) { content() }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func labeled<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text(title).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
            content()
        }
    }

    private func factRow(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DSSpacing.sm) {
            Text(title).font(DSTypography.body).foregroundStyle(DSColor.secondaryText)
            Spacer(minLength: DSSpacing.sm)
            Text(value).font(DSTypography.body.monospacedDigit()).foregroundStyle(DSColor.primaryText)
        }
    }

    @ViewBuilder private var inputCard: some View {
        if model.source.usesMicrophone {
            labeled("Microphone") {
                DSMenuField(value: model.devices.first { $0.id == model.deviceUID }?.name ?? "System Default") {
                    Picker("Microphone", selection: $model.deviceUID) {
                        Text("System Default").tag(String?.none)
                        ForEach(model.devices) { Text($0.name).tag(String?.some($0.id)) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                .disabled(model.isRunning)
                .help(model.isRunning ? "Stop captioning to change the microphone" : "")
                .accessibilityIdentifier("live.device")
            }
        }
        labeled("Language") {
            DSMenuField(value: model.language.title) {
                Picker("Language", selection: $model.language) {
                    ForEach(model.languageChoices) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            .disabled(model.isRunning)
            .help(model.isRunning ? "Stop captioning to change the language" : "")
            .accessibilityIdentifier("live.language")
        }
        labeled("Level") {
            LevelMeter(level: model.level)
                .accessibilityLabel("Input level")
                .accessibilityValue("\(Int(model.level * 100)) percent")
                .accessibilityIdentifier("live.levelMeter")
        }
    }

    @ViewBuilder private func sessionCard(_ summary: LiveSessionSummary) -> some View {
        factRow("Status", model.isPaused ? "Paused" : (model.isRunning ? "Listening" : "Not started"))
        factRow("Segments", "\(summary.finalCount)")
        factRow("Words", "\(summary.wordCount)")
        Divider()
        Toggle("Save as transcript", isOn: $model.saveAsTranscript)
            .toggleStyle(.switch)
            .disabled(model.isRunning)
            .accessibilityIdentifier("live.saveAsTranscript")
        if model.savedTranscriptID != nil {
            Label("Saved to your library", systemImage: LiveSymbol.saved)
                .font(DSTypography.caption)
                .foregroundStyle(DSColor.secondaryText)
                .accessibilityIdentifier("live.saved")
        }
    }

    @ViewBuilder private func translationCard(_ summary: LiveSessionSummary) -> some View {
        Toggle("Translate captions", isOn: $model.translationEnabled)
            .disabled(model.isRunning)
            .accessibilityIdentifier("live.translation.enabled")
        if model.translationEnabled {
            Picker("Translate to", selection: $model.translationTarget) {
                Text("Choose a language").tag("")
                ForEach(model.translationLanguages, id: \.self) { language in
                    Text(LiveLanguageChoice.name(language)).tag(language.rawValue)
                }
            }
            .disabled(model.isRunning)
            .accessibilityIdentifier("live.translation.target")
            Picker("Engine", selection: $model.translationEngine) {
                ForEach(model.translationEngineChoices) { choice in Text(choice.title).tag(choice.id).disabled(choice.isUnavailable) }
            }
            .disabled(model.isRunning)
            .accessibilityIdentifier("live.translation.engine")
            if case .needsApplePack = model.translationPreparation {
                Button("Prepare translation…") { Task { await model.prepareTranslation() } }
                    .accessibilityIdentifier("live.translation.prepare")
            }
            if summary.translatedCount > 0 {
                factRow("Translated lines", "\(summary.translatedCount) of \(summary.finalCount)")
            } else {
                Text(model.isRunning ? "Waiting for translated speech. Translation problems appear above the captions." : "Translations will appear below each caption after you start.")
                    .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("Translation is off. Turn on Translate captions to choose a target language.")
                .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func speakersCard(_ summary: LiveSessionSummary) -> some View {
        if summary.speakers.isEmpty {
            Text("Speakers are labelled here once they are identified.")
                .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ForEach(summary.speakers) { speaker in
                HStack(spacing: DSSpacing.sm) {
                    SpeakerChip(name: speaker.label, slot: speaker.slot)
                    Spacer(minLength: DSSpacing.sm)
                    Text("\(speaker.lineCount)").font(DSTypography.body.monospacedDigit()).foregroundStyle(DSColor.secondaryText)
                }
            }
        }
    }

    @ViewBuilder private var overlayCard: some View {
        Toggle(
            "Show overlay",
            isOn: Binding(get: { model.overlayEnabled }, set: { value in Task { await model.setOverlayEnabled(value) } })
        )
        .toggleStyle(.switch)
        .accessibilityIdentifier("live.overlay")
        labeled("Preset") {
            DSMenuField(value: model.preset.name) {
                Picker(
                    "Preset",
                    selection: Binding(get: { model.preset.id }, set: { id in Task { await model.selectPreset(id) } })
                ) {
                    ForEach(model.presets) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            .accessibilityIdentifier("live.preset")
        }
        CaptionPresetControls(preset: Binding(get: { model.preset }, set: { model.updatePreset($0) }), layout: .embedded)
    }
}

/// Counts shown in the Live side panel, derived from the caption lines (pure, so it is unit tested).
public struct LiveSessionSummary: Equatable, Sendable {
    public struct Speaker: Equatable, Sendable, Identifiable {
        public var label: String
        public var slot: Int
        public var lineCount: Int
        public var id: String { label }
    }
    public var finalCount = 0
    public var wordCount = 0
    public var translatedCount = 0
    public var speakers: [Speaker] = []

    public init(lines: [CaptionLine]) {
        for line in lines where !line.isVolatile {
            finalCount += 1
            wordCount += line.text.split(whereSeparator: \.isWhitespace).count
            if let translation = line.translation, !translation.isEmpty { translatedCount += 1 }
            guard let label = line.speakerLabel else { continue }
            if let index = speakers.firstIndex(where: { $0.label == label }) {
                speakers[index].lineCount += 1
            } else {
                speakers.append(Speaker(label: label, slot: line.speakerSlot ?? speakers.count, lineCount: 1))
            }
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
                .font(DSTypography.transcript)
                .lineSpacing(DSTypography.transcriptLineSpacing)
                .italic(line.isVolatile)
                .foregroundStyle(line.isVolatile ? DSColor.secondaryText : DSColor.primaryText)
            if let translation = line.translation { Text(translation).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, DSSpacing.sm)
        .dsTransition(.settle)
        .accessibilityElement(children: .combine)
        .accessibilityValue(line.isVolatile ? "In progress" : "")
    }
}

#Preview("Live - idle") { LiveView(model: LiveModel(services: .preview())).frame(width: 920, height: 520) }

extension View {
    /// A rounded solid panel (the "sheet" tier) that clips its content to its own shape.
    fileprivate func livePanelSurface() -> some View {
        background(DSColor.contentBackground)
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.panel))
            .dsSolidSurface(.sheet, radius: DSRadius.panel)
    }
}

/// Compact windows stack controls below captions; ordinary windows reserve a predictable solid inspector width.
public struct LiveWorkspaceLayout: Equatable, Sendable {
    public var width: CGFloat
    public init(width: CGFloat) { self.width = max(0, width) }
    public var stacksPanels: Bool { width < 820 }
    public var sidePanelWidth: CGFloat { width >= 1500 ? 340 : 308 }
}
