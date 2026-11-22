import AppCore
import AppKit
import DesignSystem
import SwiftUI
import UniformTypeIdentifiers

struct GeneralSettingsView: View {
    let model: GeneralSettingsModel
    var checkForUpdates: (@MainActor @Sendable () -> Void)?
    var automaticUpdateChecks: (@MainActor @Sendable () -> Bool)?
    var setAutomaticUpdateChecks: (@MainActor @Sendable (Bool) -> Void)?
    @State private var checksAutomatically = false

    var body: some View {
        Form {
            Section("Startup") {
                Toggle(
                    "Launch Earmark at login",
                    isOn: Binding(get: { model.launchAtLogin }, set: { value in Task { await model.setLaunchAtLogin(value) } }))
                if let error = model.launchError { Text(error).font(DSTypography.caption).foregroundStyle(DSColor.danger) }
            }
            Section("Appearance") {
                Toggle(
                    "Show Dock icon",
                    isOn: Binding(get: { model.showDockIcon }, set: { value in Task { await model.setShowDockIcon(value) } })
                )
                .accessibilityHint("When off, Earmark lives in the menu bar only")
                Toggle("Show menu bar icon", isOn: model.showMenuBarIcon.binding)
                Toggle(
                    "Keep running in the menu bar when the window closes",
                    isOn: Binding(get: { model.keepRunning }, set: { value in Task { await model.setKeepRunning(value) } }))
            }
            Section {
                Picker(
                    "Default language",
                    selection: Binding(get: { model.languageKind }, set: { kind in Task { await model.setLanguageKind(kind) } })
                ) {
                    Text("English (default)").tag(LanguageModeKind.single)
                    Text("Auto-detect").tag(LanguageModeKind.autoDetect)
                    Text("Multilingual set").tag(LanguageModeKind.multilingual)
                }
            } header: {
                Text("Language")
            } footer: {
                Text("Choose specific languages and models in Languages.")
            }
            Section("Welcome") {
                Button("Show Welcome Again") { Task { await model.showWelcomeAgain() } }
                    .accessibilityIdentifier("settings.general.showWelcome")
                    .accessibilityHint("Reopens the first-run introduction")
            }
            Section("Updates") {
                Button("Check for Updates…") { checkForUpdates?() }
                    .disabled(checkForUpdates == nil).accessibilityIdentifier("settings.general.checkForUpdates")
                if setAutomaticUpdateChecks != nil {
                    Toggle(
                        "Check for updates automatically",
                        isOn: Binding(
                            get: { checksAutomatically },
                            set: {
                                checksAutomatically = $0
                                setAutomaticUpdateChecks?($0)
                            }))
                } else {
                    Text("Updates are not available for this build.").font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                }
            }
            Section("Notifications") {
                Toggle("Allow notifications", isOn: model.notificationsEnabled.binding)
                Toggle("Notify when a file finishes transcribing", isOn: model.notifyJobCompleted.binding)
                    .disabled(!model.notificationsEnabled.value)
            }
        }
        .formStyle(.grouped)
        .task { await model.load() }
        .onAppear { checksAutomatically = automaticUpdateChecks?() ?? false }
    }
}

struct AudioSettingsView: View {
    let model: AudioSettingsModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section("Input device") {
                devicePicker("Microphone", pref: model.globalDevice, allowGlobal: false)
                    .disabled(model.isTestingMicrophone)
                HStack {
                    ProgressView(value: Double(model.inputLevel)).frame(maxWidth: 220)
                        .accessibilityLabel("Input level").accessibilityValue("\(Int(model.inputLevel * 100)) percent")
                    Button(model.isTestingMicrophone ? "Stop test" : "Test microphone") {
                        Task {
                            if model.isTestingMicrophone { await model.stopMicrophoneTest() } else { await model.startMicrophoneTest() }
                        }
                    }
                    .disabled(!model.canTestMicrophone)
                    .accessibilityIdentifier("settings.audio.testMicrophone")
                }
                Text("Test microphone listens locally until you stop or leave this pane. It asks for microphone access when needed.")
                    .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                if let message = model.meterError {
                    Text(message).font(DSTypography.caption).foregroundStyle(DSColor.danger)
                    if let url = model.microphoneSettingsURL { Button("Open Microphone Settings") { openURL(url) } }
                }
                Toggle("Voice processing (echo cancellation, noise suppression)", isOn: model.voiceProcessing.binding)
            }
            Section {
                devicePicker("Live captions", pref: model.liveDevice, allowGlobal: true)
                devicePicker("Meetings", pref: model.meetingsDevice, allowGlobal: true)
                devicePicker("Dictation", pref: model.dictationDevice, allowGlobal: true)
            } header: {
                Text("Per-feature overrides")
            }
        }
        .formStyle(.grouped)
        .task {
            await model.load()
            await model.observe()
        }
        .onDisappear { Task { await model.stopMicrophoneTest() } }
    }

    private func devicePicker(_ title: LocalizedStringKey, pref: Pref<String>, allowGlobal: Bool) -> some View {
        Picker(title, selection: pref.binding) {
            Text(allowGlobal ? "Use global setting" : "System default\(model.systemDefaultName.map { " (\($0))" } ?? "")").tag("")
            ForEach(model.inputs) { Text($0.name).tag($0.id) }
            if model.isMissing(pref.value) { Text("Disconnected device").tag(pref.value) }
        }
    }
}

struct MeetingsSettingsView: View {
    let model: MeetingsSettingsModel
    @State private var keyword: [MeetingApp: String] = [:]

    var body: some View {
        Form {
            ForEach(MeetingApp.allCases, id: \.self) { app in
                Section(app.title) {
                    Picker(
                        "When a meeting starts",
                        selection: Binding(
                            get: { model.policy(for: app).behavior }, set: { value in Task { await model.setBehavior(value, for: app) } })
                    ) {
                        ForEach(MeetingBehavior.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Stepper(
                        "Stop \(Int(model.policy(for: app).autoStopGraceSeconds)) seconds after the meeting ends",
                        value: Binding(
                            get: { model.policy(for: app).autoStopGraceSeconds },
                            set: { value in Task { await model.update(app) { $0.autoStopGraceSeconds = value } } }),
                        in: 0...300, step: 5)
                    Toggle(
                        "Record video",
                        isOn: Binding(
                            get: { model.policy(for: app).recordVideo },
                            set: { value in Task { await model.update(app) { $0.recordVideo = value } } }))
                    quietHours(app)
                    exclusions(app)
                }
            }
            Section {
                Toggle("Show a one-time recording consent notice", isOn: model.consentNotice.binding)
                LabeledContent("Recordings folder") {
                    Text(model.storageLocation.value.isEmpty ? "Library default" : model.storageLocation.value).foregroundStyle(
                        DSColor.secondaryText)
                }
            } header: {
                Text("Privacy & storage")
            } footer: {
                Text("Tell participants before recording. Recording laws vary by place.")
            }
        }
        .formStyle(.grouped)
        .task { await model.load() }
    }

    private func quietHours(_ app: MeetingApp) -> some View {
        let range = model.policy(for: app).quietHours
        return VStack(alignment: .leading) {
            Toggle(
                "Quiet hours (no automatic recording)",
                isOn: Binding(get: { range != nil }, set: { on in Task { await model.setQuietHours(on ? 22...24 : nil, for: app) } }))
            if let range {
                HStack {
                    Stepper(
                        "From \(range.lowerBound):00",
                        value: Binding(
                            get: { range.lowerBound },
                            set: { value in
                                Task { await model.setQuietHours(value...max(value, range.upperBound), for: app) }
                            }), in: 0...23)
                    Stepper(
                        "To \(range.upperBound):00",
                        value: Binding(
                            get: { range.upperBound },
                            set: { value in
                                Task { await model.setQuietHours(min(range.lowerBound, value)...value, for: app) }
                            }), in: 0...24)
                }
            }
        }
    }

    private func exclusions(_ app: MeetingApp) -> some View {
        VStack(alignment: .leading) {
            HStack {
                TextField("Exclude meetings whose title contains…", text: Binding(get: { keyword[app] ?? "" }, set: { keyword[app] = $0 }))
                    .onSubmit { add(app) }
                Button("Add") { add(app) }.disabled((keyword[app] ?? "").isEmpty)
            }
            ForEach(model.policy(for: app).excludedKeywords, id: \.self) { word in
                HStack {
                    Text(word)
                    Spacer()
                    Button("Remove", systemImage: "minus.circle") { Task { await model.removeExclusion(word, for: app) } }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            }
        }
    }

    private func add(_ app: MeetingApp) {
        let word = keyword[app] ?? ""
        keyword[app] = ""
        Task { await model.addExclusion(word, for: app) }
    }
}

/// Renders a caption preset over a sample backdrop (live preview while editing).
struct CaptionPreview: View {
    let preset: CaptionPreset

    var body: some View {
        let text = Color(hex: preset.textColorHex)
        VStack(alignment: preset.alignment == .leading ? .leading : (preset.alignment == .trailing ? .trailing : .center)) {
            Text("Hello, this is how your captions will look.")
            if preset.visibleLines > 1 { Text("A second line appears here as people keep speaking.") }
        }
        .font(.system(size: min(preset.fontSize, 40), weight: Font.Weight(preset.fontWeight)))
        .foregroundStyle(text)
        .shadow(color: preset.textOutline ? .black : .clear, radius: preset.textOutline ? 2 : 0)
        .multilineTextAlignment(preset.alignment == .leading ? .leading : (preset.alignment == .trailing ? .trailing : .center))
        .padding(DSSpacing.lg)
        .frame(maxWidth: .infinity)
        .background {
            switch preset.background {
            case .liquidGlass:
                RoundedRectangle(cornerRadius: preset.cornerRadius).fill(.ultraThinMaterial).opacity(preset.backgroundOpacity)
            case .solid: RoundedRectangle(cornerRadius: preset.cornerRadius).fill(Color.black.opacity(preset.backgroundOpacity))
            case .none: Color.clear
            }
        }
        .padding(DSSpacing.lg)
        .background(LinearGradient(colors: [.indigo.opacity(0.5), .teal.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.medium))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Caption preview, \(preset.name)")
    }
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

extension Font.Weight {
    /// Maps a 0...1 weight (AppKit-style, 0.4 ≈ medium) onto SwiftUI's weights.
    init(_ value: Double) {
        switch value {
        case ..<0.1: self = .light
        case ..<0.3: self = .regular
        case ..<0.5: self = .medium
        case ..<0.65: self = .semibold
        default: self = .bold
        }
    }
}

struct LiveCaptionsSettingsView: View {
    let model: CaptionPresetsModel
    let placement: OverlayPlacementSettingsModel

    var body: some View {
        @Bindable var model = model
        Form {
            OverlayPlacementSection(model: placement)
            Section("Presets") {
                Picker("Preset", selection: Binding(get: { model.draft.id }, set: { id in Task { await model.select(id) } })) {
                    ForEach(model.presets) { Text($0.isBuiltIn ? "\($0.name) (built in)" : $0.name).tag($0.id) }
                }
                HStack {
                    Button("New preset") { Task { await model.newPreset() } }
                    Button("Duplicate") { Task { await model.duplicateDraft() } }
                    Button("Delete", role: .destructive) { Task { await model.deleteDraft() } }.disabled(!model.isDraftEditable)
                }
                CaptionPreview(preset: model.draft)
            }
            Section {
                TextField("Name", text: $model.draft.name).disabled(!model.isDraftEditable)
                Slider(value: $model.draft.fontSize, in: 12...72) { Text("Font size \(Int(model.draft.fontSize)) pt") }
                Stepper("Visible lines: \(model.draft.visibleLines)", value: $model.draft.visibleLines, in: 1...6)
                Picker("Background", selection: $model.draft.background) {
                    Text("Liquid Glass").tag(CaptionPreset.Background.liquidGlass)
                    Text("Solid").tag(CaptionPreset.Background.solid)
                    Text("None").tag(CaptionPreset.Background.none)
                }
                Slider(value: $model.draft.backgroundOpacity, in: 0...1) { Text("Background opacity") }
                Picker("Alignment", selection: $model.draft.alignment) {
                    Text("Left").tag(CaptionPreset.Alignment.leading)
                    Text("Center").tag(CaptionPreset.Alignment.center)
                    Text("Right").tag(CaptionPreset.Alignment.trailing)
                }
                Toggle("Text outline", isOn: $model.draft.textOutline)
                Toggle("Speaker labels", isOn: $model.draft.showSpeakerLabels)
                Toggle("Language badge", isOn: $model.draft.showLanguageBadge)
                Toggle("Show translation", isOn: $model.draft.showTranslation)
            } header: {
                Text("Appearance")
            } footer: {
                if !model.isDraftEditable { Text("Built-in presets can't be changed. Duplicate one to customise it.") }
            }
            .disabled(!model.isDraftEditable)
            .onChange(of: model.draft) { _, _ in Task { await model.saveDraft() } }
        }
        .formStyle(.grouped)
        .task {
            await model.load()
            await placement.load()
        }
        .onDisappear { Task { await placement.hideTestCaption() } }
    }
}

struct DictationSettingsView: View {
    let model: DictationSettingsModel

    var body: some View {
        Form {
            Section {
                Picker("Hotkey behavior", selection: model.mode.binding) {
                    Text("Push to talk").tag(HotkeyMode.pushToTalk)
                    Text("Toggle").tag(HotkeyMode.toggle)
                }
                Picker("Insert text by", selection: model.insertion.binding) {
                    Text("Pasting").tag(TextInsertionMethod.pasteboardPaste)
                    Text("Accessibility typing").tag(TextInsertionMethod.accessibility)
                }
            } footer: {
                Text("Set the hotkey in Keyboard Shortcuts.")
            }
            Section("Cleanup") {
                Toggle("Remove filler words (um, uh)", isOn: model.removeFillers.binding)
                Toggle("Add punctuation and capitalisation", isOn: model.autoPunctuate.binding)
                Toggle("Translate before inserting", isOn: model.translateBeforeInsert.binding)
            }
            Section("History") {
                Stepper("Keep the last \(model.historySize.value) dictations", value: model.historySize.binding, in: 0...500, step: 10)
            }
        }
        .formStyle(.grouped)
        .task { await model.load() }
    }
}

struct AppearanceSettingsView: View {
    let model: AppearanceSettingsModel

    var body: some View {
        Form {
            Section("Text") {
                Slider(value: model.fontSize.binding, in: 11...28, step: 1) { Text("Font size \(Int(model.fontSize.value)) pt") }
                Slider(value: model.lineSpacing.binding, in: 0...16, step: 1) { Text("Line spacing \(Int(model.lineSpacing.value)) pt") }
                Text("Sample transcript text appears like this.")
                    .font(.system(size: model.fontSize.value)).lineSpacing(model.lineSpacing.value)
            }
            Section("Show") {
                Toggle("Timestamps", isOn: model.showTimestamps.binding)
                Toggle("Language badges", isOn: model.showLanguageBadges.binding)
                Toggle("Ignored segments (dimmed)", isOn: model.showIgnored.binding)
            }
        }
        .formStyle(.grouped)
        .task { await model.load() }
    }
}

struct TranslationSettingsView: View {
    let model: TranslationSettingsModel
    let models: ModelManagerModel

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Defaults") {
                    TextField("Target language code (blank to ask each time)", text: model.targetLanguage.binding)
                    Picker("Engine", selection: model.engine.binding) {
                        Text("Auto").tag("auto")
                        Text("Apple Translation").tag("apple")
                        Text("NLLB (non-commercial)").tag("nllb")
                    }
                    Toggle("Allow non-commercial models (CC-BY-NC)", isOn: model.allowNonCommercial.binding)
                    Toggle("Keep translation as a parallel track", isOn: model.parallelTrack.binding)
                }
            }
            .formStyle(.grouped).scrollDisabled(true).fixedSize(horizontal: false, vertical: true)
            ModelsSettingsView(model: models, kinds: [.translation])
        }
        .task { await model.load() }
    }
}

struct ExportDefaultsView: View {
    let model: ExportDefaultsModel
    @State private var presetName = ""

    var body: some View {
        let options = model.defaultOptions.value
        Form {
            Section("Defaults") {
                Picker("Format", selection: Binding(get: { options.format }, set: { value in model.mutateOptions { $0.format = value } })) {
                    ForEach(ExportFormat.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                }
                Toggle(
                    "Include speakers",
                    isOn: Binding(get: { options.includeSpeakers }, set: { value in model.mutateOptions { $0.includeSpeakers = value } }))
                Toggle(
                    "Merge same speaker",
                    isOn: Binding(get: { options.mergeSameSpeaker }, set: { value in model.mutateOptions { $0.mergeSameSpeaker = value } }))
                Toggle(
                    "Include ignored segments",
                    isOn: Binding(get: { options.includeIgnored }, set: { value in model.mutateOptions { $0.includeIgnored = value } }))
            }
            Section("Presets") {
                ForEach(model.presets) { preset in
                    HStack {
                        Text(preset.name)
                        Text(preset.options.format.rawValue.uppercased()).font(DSTypography.badge).foregroundStyle(DSColor.secondaryText)
                        Spacer()
                        Button("Use") { Task { await model.apply(preset) } }
                        Button("Delete", systemImage: "minus.circle") { Task { await model.delete(preset.id) } }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Save current defaults as…", text: $presetName)
                    Button("Save") {
                        let name = presetName
                        presetName = ""
                        Task { await model.saveCurrentAsPreset(named: name) }
                    }
                    .disabled(presetName.isEmpty)
                }
                if let message = model.errorMessage { Text(message).foregroundStyle(DSColor.danger) }
            }
        }
        .formStyle(.grouped)
        .task { await model.load() }
    }
}

struct StorageSettingsView: View {
    let model: StorageSettingsModel
    @State private var choosingFolder = false

    var body: some View {
        Form {
            Section("Storage used") {
                if let usage = model.breakdown {
                    LabeledContent("Library", value: ModelFormat.bytes(usage.library))
                        .accessibilityIdentifier("settings.storage.library")
                    LabeledContent("Models", value: ModelFormat.bytes(usage.models))
                        .accessibilityIdentifier("settings.storage.models")
                    LabeledContent("Recordings", value: ModelFormat.bytes(usage.recordings))
                        .accessibilityIdentifier("settings.storage.recordings")
                    LabeledContent("Caches", value: ModelFormat.bytes(usage.caches))
                        .accessibilityIdentifier("settings.storage.caches")
                    LabeledContent("Total") { Text(ModelFormat.bytes(usage.total)).fontWeight(.semibold) }
                        .accessibilityIdentifier("settings.storage.total")
                } else {
                    LabeledContent("Measuring") { ProgressView().controlSize(.small) }
                }
            }
            Section("Library") {
                LabeledContent("Location") {
                    Text(model.isDefaultLocation ? "Default (Application Support)" : model.libraryLocation.value)
                        .foregroundStyle(DSColor.secondaryText).lineLimit(1).truncationMode(.middle)
                        .accessibilityIdentifier("settings.storage.location")
                }
                HStack {
                    Button("Change…") { choosingFolder = true }
                        .disabled(model.isMoving)
                        .accessibilityIdentifier("settings.storage.change")
                    if !model.isDefaultLocation {
                        Button("Use Default Location") { Task { await model.proposeDefaultLocation() } }
                            .disabled(model.isMoving)
                            .accessibilityIdentifier("settings.storage.useDefault")
                    }
                    if model.isMoving { ProgressView().controlSize(.small) }
                }
                Text("Copied media and meeting recordings move with the library. The transcript database stays in Application Support.")
                    .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                if let message = model.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle").font(DSTypography.caption).foregroundStyle(DSColor.danger)
                        .accessibilityIdentifier("settings.storage.error")
                }
                if let notice = model.movedNotice {
                    Text(notice).font(DSTypography.caption).accessibilityIdentifier("settings.storage.movedNotice")
                }
            }
            Section("Recently Deleted") {
                Picker("Keep deleted items for", selection: model.retentionDays.binding) {
                    ForEach(StorageSettingsModel.retentionChoices, id: \.self) { Text("\($0) days").tag($0) }
                }
                Button("Remove expired items now") { Task { await model.purgeExpiredNow() } }
                if let purged = model.lastPurged { Text("Removed \(purged) items.").font(DSTypography.caption) }
            }
            Section("Caches") {
                Button("Clear caches") { Task { await model.clearCaches() } }
                if let freed = model.lastFreedBytes { Text("Freed \(ModelFormat.bytes(freed)).").font(DSTypography.caption) }
            }
        }
        .formStyle(.grouped)
        .task { await model.load() }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            Task { await model.proposeLocation(url) }
        }
        .confirmationDialog(
            "Move the library?",
            isPresented: Binding(get: { model.pendingMove != nil }, set: { if !$0 { model.cancelMove() } }),
            presenting: model.pendingMove
        ) { pending in
            Button("Move Library") { Task { await model.confirmMove(pending) } }
                .accessibilityIdentifier("settings.storage.confirmMove")
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(
                "Earmark will move \(ModelFormat.bytes(pending.plan.bytes)) to \(pending.plan.destination.path). Don't quit Earmark or record a meeting until it finishes."
            )
        }
    }
}

struct PrivacySettingsView: View {
    let model: PermissionsSettingsModel
    var voiceProfiles: VoiceProfilesModel?
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            if let voiceProfiles, voiceProfiles.isAvailable { VoiceProfilesSection(model: voiceProfiles) }
            Section {
                ForEach(PermissionKind.allCases, id: \.self) { kind in
                    PermissionRow(
                        state: model.rowState(kind),
                        onRequest: { Task { await model.request(kind) } },
                        onOpenSettings: { openURL(model.settingsURL(for: kind)) })
                }
            } header: {
                Text("Earmark asks for access only when a feature needs it.")
            } footer: {
                Text(
                    "Denied permissions never block the rest of the app. "
                        + "Network access is limited to model downloads and updates you choose."
                )
            }
        }
        .formStyle(.grouped)
        .task {
            await model.load()
            await model.observe()
        }
        // The user may have changed a switch in System Settings while Earmark was in the background.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.load() }
        }
    }
}
