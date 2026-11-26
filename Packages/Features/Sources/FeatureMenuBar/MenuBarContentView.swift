import AppCore
import AppKit
import DesignSystem
import FeatureLive
import FeatureSupport
import SwiftUI

/// Window-opening and navigation callbacks supplied by the app (the menu bar target cannot reach the shell directly).
public struct MenuBarActions {
    public var transcribeFile: () -> Void
    public var openQueue: () -> Void
    public var openLibrary: () -> Void
    public var openMeetings: () -> Void
    /// Opens Meetings and looks for calls that can be transcribed right now.
    public var detectMeetings: () -> Void
    public var openMainWindow: () -> Void
    public var openSettings: () -> Void
    public var quit: () -> Void
    public init(
        transcribeFile: @escaping () -> Void = {}, openQueue: @escaping () -> Void = {}, openLibrary: @escaping () -> Void = {},
        openMeetings: @escaping () -> Void = {}, detectMeetings: @escaping () -> Void = {}, openMainWindow: @escaping () -> Void = {}, openSettings: @escaping () -> Void = {},
        quit: @escaping () -> Void = {}
    ) {
        self.transcribeFile = transcribeFile
        self.openQueue = openQueue
        self.openLibrary = openLibrary
        self.openMeetings = openMeetings
        self.detectMeetings = detectMeetings
        self.openMainWindow = openMainWindow
        self.openSettings = openSettings
        self.quit = quit
    }
}

/// Menu bar icon; the recording state pulses unless Reduce Motion is on (MENU-AC-07).
public struct MenuBarIconView: View {
    private let model: MenuBarModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: MenuBarModel) { self.model = model }

    public var body: some View {
        Image(systemName: model.status.systemImage)
            .symbolEffect(.pulse, isActive: model.status.isRecording && !reduceMotion)
            .accessibilityLabel("Earmark")
            .accessibilityValue(model.status.text)
    }
}

/// A compact capture workspace: live status, one primary action, input choices and predictable navigation.
public struct MenuBarContentView: View {
    private let model: MenuBarModel
    private let actions: MenuBarActions
    @State private var showsInputOptions = false
    @State private var measuredContentHeight: CGFloat = 370

    public init(model: MenuBarModel, actions: MenuBarActions = MenuBarActions()) {
        self.model = model
        self.actions = actions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            header
            ScrollView {
                controls
                    .frame(maxWidth: .infinity)
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height
                    } action: {
                        measuredContentHeight = $0
                    }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(measuredContentHeight, maximumContentHeight))
            Divider()
            footer
        }
        .padding(DSSpacing.lg)
        .frame(width: 360)
        .background(DSColor.paper)
        .dsIconContext(.menu)
        .dsAnimation(.glide, value: model.status)
        .dsAnimation(.glide, value: showsInputOptions)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Earmark quick controls")
        .accessibilityIdentifier("menuBar.panel")
    }

    /// The pointer locates the display whose menu bar opened this popup; keyboard activation falls back to the key screen.
    private var maximumContentHeight: CGFloat {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        return max(180, (screen?.visibleFrame.height ?? 760) - 160)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            statusCard.dsEntrance()
            captureActions
            inputOptions
            if let message = model.errorMessage {
                HStack(alignment: .top, spacing: DSSpacing.sm) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(DSTypography.caption).foregroundStyle(DSColor.danger)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Dismiss message", systemImage: "xmark", action: model.dismissError)
                        .labelStyle(.iconOnly).buttonStyle(.dsHoverIcon).help("Dismiss")
                        .accessibilityIdentifier("menuBar.error.dismiss")
                }
                .padding(DSSpacing.md)
                .background(DSColor.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: DSRadius.medium))
                .dsTransition(.settle)
                .accessibilityIdentifier("menuBar.error")
                if model.permissionBlocked {
                    PermissionGateBanner(model: model.permissionGate, feature: "Live captions", identifier: "menuBar.permissions")
                }
            }
            Divider()
            navigation
        }
    }

    private var header: some View {
        HStack(spacing: DSSpacing.sm) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().frame(width: 30, height: 30).accessibilityHidden(true)
            Text("earmark").font(DSTypography.title2)
            Spacer()
            if model.status.isRecording {
                RecordingIndicator(label: nil)
            } else {
                StatusPill("On this Mac", tone: .neutral)
            }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            HStack(spacing: DSSpacing.sm) {
                Text(model.status.text).font(DSTypography.headline)
                Spacer(minLength: DSSpacing.xs)
                if model.inputs.runningJobs > 0 {
                    Text("\(model.inputs.runningJobs) active").font(DSTypography.timestamp).foregroundStyle(DSColor.secondaryText)
                }
            }
            if model.isLiveRunning {
                if model.captionPreview.isEmpty {
                    Text("Captions will appear here as people speak.")
                        .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                } else {
                    ForEach(model.captionPreview.suffix(2)) { line in
                        Text(line.text).font(DSTypography.body).italic(line.isVolatile).lineLimit(2)
                            .foregroundStyle(line.isVolatile ? DSColor.secondaryText : DSColor.primaryText)
                    }
                }
            } else {
                Text(model.modelSummary).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                    .lineLimit(2).accessibilityIdentifier("menuBar.model")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DSSpacing.md)
        .background(DSColor.contentBackground, in: RoundedRectangle(cornerRadius: DSRadius.large))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("menuBar.status")
    }

    private var captureActions: some View {
        VStack(spacing: DSSpacing.sm) {
            Button(action: actions.transcribeFile) {
                Label("Transcribe a file…", symbol: .waveform).frame(maxWidth: .infinity)
            }
            .buttonStyle(EmberButtonStyle()).accessibilityIdentifier("menuBar.transcribe")
            HStack(spacing: DSSpacing.sm) {
                if model.isLiveRunning {
                    Button("Stop captions", systemImage: "stop.fill") { Task { await model.stopLive() } }
                        .tint(DSColor.recordingText).accessibilityIdentifier("menuBar.live.stop")
                } else {
                    Menu {
                        ForEach(LiveSourceChoice.allCases) { choice in
                            Button(choice.title) { Task { await model.startLive(choice) } }
                                .disabled(model.startDisabledReason(for: choice) != nil)
                                .help(model.startDisabledReason(for: choice) ?? "Start captions from \(choice.title)")
                        }
                    } label: {
                        Label("Live captions", symbol: .liveCaptions)
                    }
                    .accessibilityIdentifier("menuBar.live.start")
                }
                if model.isDictationAvailable {
                    Button(model.isDictating ? "Finish dictation" : "Dictation", symbol: .dictation) {
                        Task { await model.toggleDictation() }
                    }
                    .tint(model.isDictating ? DSColor.recordingText : DSColor.secondaryText)
                    .accessibilityIdentifier("menuBar.dictation")
                }
            }
            .buttonStyle(.bordered).labelStyle(.titleAndIcon).controlSize(.regular)
        }
    }

    private var inputOptions: some View {
        DisclosureGroup(isExpanded: $showsInputOptions) {
            VStack(alignment: .leading, spacing: DSSpacing.md) {
                LabeledContent("Microphone") {
                    Picker(
                        "Microphone",
                        selection: Binding(
                            get: { model.inputDeviceUID ?? "" },
                            set: { value in Task { await model.setInputDevice(value.isEmpty ? nil : value) } }
                        )
                    ) {
                        Text("System default").tag("")
                        ForEach(model.devices) { Text($0.name).tag($0.id) }
                        if model.inputDeviceIsMissing, let uid = model.inputDeviceUID {
                            Text("Disconnected device (using system default)").tag(uid)
                        }
                    }
                    .labelsHidden().frame(maxWidth: 190).disabled(model.status.isRecording)
                    .help(model.status.isRecording ? "Stop captions to change the microphone" : "")
                    .accessibilityIdentifier("menuBar.microphone")
                }
                LabeledContent("Language") {
                    Picker(
                        "Language", selection: Binding(get: { model.language }, set: { value in Task { await model.setLanguage(value) } })
                    ) {
                        ForEach(model.languageChoices) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().frame(maxWidth: 190).disabled(model.status.isRecording)
                    .help(model.status.isRecording ? "Stop captions to change the language" : "")
                    .accessibilityIdentifier("menuBar.language")
                }
                Divider()
                Toggle(
                    "Auto-record meetings",
                    isOn: Binding(get: { model.autoRecord }, set: { value in Task { await model.setAutoRecord(value) } })
                )
                .toggleStyle(.switch).accessibilityIdentifier("menuBar.autoRecord")
                Text("When off, each meeting follows its policy in Settings. Opening Meetings lets you review capture before starting.")
                    .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
            }
            .padding(.top, DSSpacing.md)
        } label: {
            HStack {
                Text("Input & language").font(DSTypography.body.weight(.medium))
                Spacer()
                Text(model.language.title).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText).lineLimit(1)
            }
        }
        .padding(DSSpacing.md)
        .background(DSColor.insetBackground, in: RoundedRectangle(cornerRadius: DSRadius.large))
        .accessibilityIdentifier("menuBar.inputOptions")
    }

    private var navigation: some View {
        VStack(spacing: DSSpacing.xxs) {
            navigationRow("Open Earmark", symbol: .home, identifier: "menuBar.open", action: actions.openMainWindow)
            navigationRow("Library", symbol: .library, identifier: "menuBar.library", action: actions.openLibrary)
            navigationRow("Queue", symbol: .queue, identifier: "menuBar.queue", action: actions.openQueue, count: model.inputs.runningJobs)
            navigationRow("Meetings", symbol: .meetings, identifier: "menuBar.meetings", action: actions.openMeetings)
            navigationRow("Detect meetings", symbol: .retry, identifier: "menuBar.detectMeetings", action: actions.detectMeetings)
        }
    }

    private func navigationRow(
        _ title: String, symbol: DSSymbol, identifier: String, action: @escaping () -> Void, count: Int = 0
    ) -> some View {
        Button(action: action) {
            HStack(spacing: DSSpacing.sm) {
                DSIcon(symbol).frame(width: 20)
                Text(title)
                Spacer()
                if count > 0 { Text("\(count)").font(DSTypography.timestamp).foregroundStyle(DSColor.secondaryText) }
                Image(systemName: "chevron.right").font(DSTypography.caption).foregroundStyle(DSColor.tertiaryText)
            }
            .frame(minHeight: DSLayout.minControlHeight)
        }
        .buttonStyle(.dsHover(shape: .rounded(DSRadius.small))).accessibilityIdentifier(identifier)
    }

    private var footer: some View {
        HStack {
            Button("Settings…", symbol: .settings, action: actions.openSettings)
                .keyboardShortcut(",", modifiers: [.command]).accessibilityIdentifier("menuBar.settings")
            Spacer()
            Button("Quit", systemImage: "power", action: actions.quit)
                .keyboardShortcut("q", modifiers: [.command]).accessibilityIdentifier("menuBar.quit")
        }
        .font(DSTypography.caption).buttonStyle(.dsHover(shape: .rounded(DSRadius.small))).foregroundStyle(DSColor.secondaryText)
        .frame(minHeight: DSLayout.minControlHeight)
    }
}

#Preview("Menu bar - idle") {
    MenuBarContentView(model: MenuBarModel(services: .preview()))
}
