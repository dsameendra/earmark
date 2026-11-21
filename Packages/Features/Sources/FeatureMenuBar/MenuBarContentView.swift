import AppCore
import DesignSystem
import FeatureLive
import FeatureSupport
import SwiftUI

/// Window-opening and navigation callbacks supplied by the app (the menu bar target cannot reach the shell directly).
public struct MenuBarActions {
    public var transcribeFile: () -> Void
    public var openQueue: () -> Void
    public var openLibrary: () -> Void
    public var openMainWindow: () -> Void
    public var openSettings: () -> Void
    public var quit: () -> Void
    public init(
        transcribeFile: @escaping () -> Void = {}, openQueue: @escaping () -> Void = {}, openLibrary: @escaping () -> Void = {},
        openMainWindow: @escaping () -> Void = {}, openSettings: @escaping () -> Void = {}, quit: @escaping () -> Void = {}
    ) {
        self.transcribeFile = transcribeFile
        self.openQueue = openQueue
        self.openLibrary = openLibrary
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

/// Popover content for the `MenuBarExtra(.window)` item.
public struct MenuBarContentView: View {
    private let model: MenuBarModel
    private let actions: MenuBarActions
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(model: MenuBarModel, actions: MenuBarActions = MenuBarActions()) {
        self.model = model
        self.actions = actions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            statusHeader
            if model.isLiveRunning { liveSection } else { startSection }
            if let message = model.errorMessage {
                Text(message).font(DSTypography.caption).foregroundStyle(DSColor.danger)
            }
            Divider()
            captureRow
            Divider()
            pickers
            Divider()
            navigation
        }
        .padding(DSSpacing.md)
        .frame(width: 320)
        .background(reduceTransparency ? DSColor.solidChrome : Color.clear)
        .accessibilityElement(children: .contain)
    }

    private var statusHeader: some View {
        HStack(spacing: DSSpacing.sm) {
            if model.status.isRecording {
                RecordingIndicator(label: nil)
            } else {
                Image(systemName: model.status.systemImage).accessibilityHidden(true)
            }
            Text(model.status.text).font(DSTypography.headline)
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status")
        .accessibilityValue(model.status.text)
    }

    private var startSection: some View {
        Menu {
            ForEach(LiveSourceChoice.allCases) { choice in
                Button(choice.title) { Task { await model.startLive(choice) } }
            }
        } label: {
            Label("Start Live Captions", systemImage: "captions.bubble")
        }
        .disabled(model.startDisabledReason != nil)
        .help(model.startDisabledReason ?? "Choose a source to start live captions")
        .accessibilityHint(model.startDisabledReason ?? "Choose a source to start")
    }

    private var liveSection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Button("Stop Live Captions", systemImage: "stop.fill") { Task { await model.stopLive() } }
            VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                ForEach(model.captionPreview) { line in
                    Text(line.text)
                        .font(DSTypography.caption)
                        .italic(line.isVolatile)
                        .lineLimit(2)
                        .foregroundStyle(line.isVolatile ? DSColor.secondaryText : DSColor.primaryText)
                }
            }
            .accessibilityLabel("Latest captions")
        }
    }

    private var captureRow: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Button("Start Meeting Capture", systemImage: "person.2.wave.2") {}
                .disabled(true)
                .help("Meeting capture is not available yet")
            Toggle(
                "Auto-record meetings",
                isOn: Binding(get: { model.autoRecord }, set: { value in Task { await model.setAutoRecord(value) } })
            )
            Button("Transcribe File…", systemImage: "doc.badge.waveform", action: actions.transcribeFile)
        }
    }

    private var pickers: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Picker(
                "Microphone",
                selection: Binding(
                    get: { model.inputDeviceUID ?? "" }, set: { value in Task { await model.setInputDevice(value.isEmpty ? nil : value) } })
            ) {
                Text("System Default").tag("")
                ForEach(model.devices) { Text($0.name).tag($0.id) }
            }
            Picker("Language", selection: Binding(get: { model.language }, set: { value in Task { await model.setLanguage(value) } })) {
                ForEach(MenuLanguageChoice.allCases) { Text($0.title).tag($0) }
            }
        }
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Button("Open Earmark", systemImage: "macwindow", action: actions.openMainWindow)
            Button("Open Queue", systemImage: "tray.full", action: actions.openQueue)
            Button("Open Library", systemImage: "books.vertical", action: actions.openLibrary)
            Button("Settings…", systemImage: "gearshape", action: actions.openSettings)
                .keyboardShortcut(",", modifiers: [.command])
            Button("Quit Earmark", systemImage: "power", action: actions.quit)
                .keyboardShortcut("q", modifiers: [.command])
        }
    }
}

#Preview("Menu bar - idle") {
    MenuBarContentView(model: MenuBarModel(services: .preview()))
}
