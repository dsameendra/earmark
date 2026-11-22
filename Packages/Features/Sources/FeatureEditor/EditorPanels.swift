import AppCore
import AppKit
import DesignSystem
import Export
import SwiftUI

/// Speaker list: rename, colour, merge, add (EDIT-AC-08).
struct SpeakersPanel: View {
    let model: TranscriptEditorModel
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            Text("Speakers").font(DSTypography.headline)
            if model.speakers.isEmpty {
                Text("No speakers yet.").foregroundStyle(DSColor.secondaryText)
            }
            if model.speakers.count > 4 {
                ScrollView { speakerRows.padding(.vertical, 2) }.frame(height: 320)  // long lists scroll instead of growing
            } else {
                speakerRows
            }
            if let message = model.voiceProfileError {
                Text(message).font(DSTypography.caption).foregroundStyle(DSColor.danger).accessibilityIdentifier(
                    "editor.speakers.voiceError")
            }
            Divider()
            HStack {
                TextField("New speaker", text: $newName).textFieldStyle(.roundedBorder).onSubmit(add)
                    .accessibilityIdentifier("editor.speakers.newName")
                Button("Add", action: add).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("editor.speakers.add")
            }
        }
        .padding(DSSpacing.lg)
        .frame(minWidth: 340, idealWidth: 360)
    }

    private var speakerRows: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            ForEach(model.speakers) { speaker in
                SpeakerRow(model: model, speaker: speaker)
            }
        }
    }

    private func add() {
        model.addSpeaker(named: newName)
        newName = ""
    }
}

struct SpeakerRow: View {
    let model: TranscriptEditorModel
    let speaker: Speaker
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            HStack {
                Circle().fill(EditorColors.color(model.color(for: speaker.id))).frame(width: 10, height: 10)
                TextField("Name", text: $name).textFieldStyle(.roundedBorder).onSubmit { model.renameSpeaker(speaker.id, to: name) }
                    .accessibilityIdentifier("editor.speaker.\(speaker.id).name")
                Text("\(model.segmentCount(for: speaker.id))").font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                Menu("Merge") {
                    ForEach(model.speakers.filter { $0.id != speaker.id }) { other in
                        Button("Into \(other.name)") { model.mergeSpeaker(speaker.id, into: other.id) }
                            .accessibilityIdentifier("editor.speaker.\(speaker.id).mergeInto.\(other.id)")
                    }
                }
                .menuStyle(.borderlessButton).fixedSize().disabled(model.speakers.count < 2)
                .accessibilityIdentifier("editor.speaker.\(speaker.id).merge")
                if model.voiceProfiles != nil { voiceProfileControl }
            }
            HStack(spacing: DSSpacing.xs) {
                ForEach(SpeakerColors.paletteHexes, id: \.self) { hex in
                    Button {
                        model.setSpeakerColor(speaker.id, hex: hex)
                    } label: {
                        Circle().fill(EditorColors.color(.hex(hex, fallbackSlot: 0))).frame(width: 14, height: 14)
                            .overlay { if speaker.colorHex.uppercased() == hex { Circle().stroke(Color.primary, lineWidth: 2) } }
                    }
                    .buttonStyle(.plain).accessibilityLabel("Colour \(hex)")
                    .accessibilityIdentifier("editor.speaker.\(speaker.id).color.\(hex)")
                }
            }
            .padding(.leading, 18)
        }
        .onAppear { name = speaker.name }
        .onChange(of: speaker.name) { name = speaker.name }
    }

    /// Save or delete the speaker's local voice profile (embedding and name only, DIA-AC-13).
    @ViewBuilder private var voiceProfileControl: some View {
        if speaker.voiceProfileID != nil {
            Button("Forget Voice") { Task { await model.removeVoiceProfile(for: speaker.id) } }
                .buttonStyle(.borderless).help("Delete this speaker's stored voice profile")
                .accessibilityIdentifier("editor.speaker.\(speaker.id).forgetVoice")
        } else {
            Button("Save Voice") { Task { await model.saveVoiceProfile(for: speaker.id) } }
                .buttonStyle(.borderless).disabled(!model.canSaveVoiceProfiles)
                .help("Remember this voice on this Mac to label the speaker automatically next time")
                .accessibilityIdentifier("editor.speaker.\(speaker.id).saveVoice")
        }
    }
}

/// Bookmarks and highlights with editable notes; click to jump (EDIT-AC-13).
struct BookmarksPanel: View {
    let model: TranscriptEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            HStack {
                Text("Bookmarks & Highlights").font(DSTypography.headline)
                Spacer()
                Button {
                    model.addBookmark()
                } label: {
                    Label("Bookmark Playhead", symbol: .earmark)
                }
            }
            if model.bookmarks.isEmpty && model.highlights.isEmpty {
                Text("Add bookmarks at the playhead, or right-click a word or segment to bookmark or highlight it.")
                    .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
            }
            List {
                ForEach(model.bookmarks) { bookmark in
                    NoteRow(
                        icon: "bookmark.fill", time: bookmark.time, note: bookmark.note,
                        onOpen: { model.go(to: bookmark) }, onNote: { model.updateBookmark(bookmark.id, note: $0) },
                        onDelete: { model.removeBookmark(bookmark.id) })
                }
                ForEach(model.highlights) { highlight in
                    NoteRow(
                        icon: "highlighter", time: highlight.time, note: highlight.note,
                        onOpen: {
                            model.playback.seek(to: highlight.time)
                            model.reveal(highlight.segmentID)
                        }, onNote: { model.updateHighlight(highlight.id, note: $0) }, onDelete: { model.removeHighlight(highlight.id) })
                }
            }
            .frame(minHeight: 160)
        }
        .padding(DSSpacing.lg)
        .frame(minWidth: 340, idealWidth: 380, minHeight: 280, idealHeight: 320, maxHeight: 480)
    }
}

struct NoteRow: View {
    let icon: String
    let time: TimeInterval
    let note: String
    var onOpen: () -> Void
    var onNote: (String) -> Void
    var onDelete: () -> Void
    @State private var text = ""

    var body: some View {
        HStack {
            Button(action: onOpen) {
                Label(TimeFormat.clock(time), systemImage: icon).font(DSTypography.timestamp)
            }
            .buttonStyle(.borderless)
            TextField("Note", text: $text).textFieldStyle(.plain).onSubmit { onNote(text) }
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")  // stock-chrome: destructive action
            }.buttonStyle(.borderless)
                .accessibilityLabel("Delete")
        }
        .onAppear { text = note }
    }
}

/// Font, size, spacing, density, toggles; global default or this transcript only (EDIT-AC-14).
struct ViewOptionsPanel: View {
    let model: TranscriptEditorModel
    static let families: [String?] = [nil, "New York", "Helvetica Neue", "Georgia", "Menlo"]

    private var availableFamilies: [String?] {
        guard let chosen = model.options.fontFamily, !Self.families.contains(chosen) else { return Self.families }
        return Self.families + [chosen]
    }

    var body: some View {
        let options = model.options
        Form {
            Picker("Layout", selection: binding(\.layout)) {
                ForEach(TranscriptLayoutMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Font", selection: binding(\.fontFamily)) {
                ForEach(availableFamilies, id: \.self) { Text($0 ?? "System").tag($0) }
            }
            LabeledContent("Size \(Int(options.fontSize)) pt") {
                Slider(value: binding(\.fontSize), in: ViewOptions.fontSizeRange, step: 1)
            }
            LabeledContent("Line spacing \(Int(options.lineSpacing)) pt") {
                Slider(value: binding(\.lineSpacing), in: ViewOptions.lineSpacingRange, step: 1)
            }
            Picker("Density", selection: binding(\.density)) {
                ForEach(TranscriptDensity.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Timestamps", isOn: binding(\.showTimestamps))
            Toggle("Speakers", isOn: binding(\.showSpeakers))
            Toggle("Language badges", isOn: binding(\.showLanguageBadges))
            Toggle("Underline low-confidence words", isOn: binding(\.underlineLowConfidence))
            Divider()
            Toggle(
                "Customize for this transcript only",
                isOn: Binding(get: { model.customizesThisTranscript }, set: { model.setCustomizesThisTranscript($0) }))
            Text(model.customizesThisTranscript ? "Changes apply to this transcript." : "Changes apply to all transcripts.")
                .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(minWidth: 340, idealWidth: 360)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func binding<V>(_ keyPath: WritableKeyPath<ViewOptions, V>) -> Binding<V> {
        Binding(get: { model.options[keyPath: keyPath] }, set: { value in model.updateOptions { $0[keyPath: keyPath] = value } })
    }
}

/// Export sheet: format, options, presets, copy and share.
struct ExportSheet: View {
    @Bindable var export: EditorExportModel
    var onClose: () -> Void
    @State private var presetName = ""
    @State private var shareURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            Text("Export").font(DSTypography.title1).accessibilityAddTraits(.isHeader)
            HStack(alignment: .top, spacing: DSSpacing.xl) {
                ScrollView {
                    VStack(alignment: .leading, spacing: DSSpacing.lg) {
                        formatGroup(
                            "Documents", formats: EditorExportModel.formats.filter { ![.srt, .vtt, .ass, .sbv, .ttml, .lrc].contains($0) })
                        formatGroup("Subtitles", formats: [.srt, .vtt, .ass, .sbv, .ttml, .lrc])
                        exportOptions
                        presetsGroup
                    }
                    .padding(.horizontal, DSSpacing.sm)  // room for focus rings and borders inside the scroll bounds
                    .padding(.vertical, DSSpacing.xs)
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: DSSpacing.md) {
                    SectionCaption(export.previewIsPlainText ? "Text preview" : "Preview")
                    ScrollView {
                        Text(export.previewText).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("First six segments").font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                }
                .padding(DSSpacing.lg)
                .frame(width: 240)
                .frame(minHeight: 360, maxHeight: .infinity)
                .dsSolidSurface(.inset, radius: DSRadius.card)
                .accessibilityIdentifier("export.preview")
            }
            .frame(minHeight: 360, idealHeight: 420, maxHeight: 520)
            if let message = export.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(DSColor.danger).font(DSTypography.caption)
            } else if let status = export.statusMessage {
                Text(status).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
            }
            HStack(spacing: DSSpacing.sm) {
                Menu {  // stock-chrome: native system share action
                    Button("Copy as Text") { Task { await export.copy(markdown: false) } }
                    Button("Copy as Markdown") { Task { await export.copy(markdown: true) } }
                    if let shareURL {
                        ShareLink(item: shareURL) { Text("Share export") }
                    } else {
                        Button("Prepare to share") { Task { shareURL = await export.prepareShareFile() } }
                    }
                } label: {
                    Label("Copy and share", systemImage: "square.and.arrow.up")  // stock-chrome: native system share glyph
                }
                .menuStyle(.borderedButton)
                .menuIndicator(.visible)
                .controlSize(.large)
                .fixedSize()
                Spacer()
                if export.isWorking { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel, action: onClose)
                    .buttonStyle(.bordered).controlSize(.large).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("export.cancel")
                Button("Export \(export.options.format.rawValue.uppercased())…") { save() }
                    .buttonStyle(.borderedProminent).tint(DSColor.accent).controlSize(.large)
                    .keyboardShortcut(.defaultAction).disabled(export.isWorking)
                    .accessibilityIdentifier("export.save")
            }
        }
        .padding(DSSpacing.xl)
        .frame(minWidth: 720, idealWidth: 760)
        .background(DSColor.contentBackground)
        .task { await export.loadPresets() }
        .task(id: export.options) { await export.refreshPreview() }
        .onChange(of: export.options) { shareURL = nil }
    }

    private var canSavePreset: Bool { !presetName.trimmingCharacters(in: .whitespaces).isEmpty }

    private func savePreset() {
        guard canSavePreset else { return }
        Task {
            await export.savePreset(named: presetName)
            presetName = ""
        }
    }

    /// Existing presets menu plus a labelled "save as preset" row (field submits on Return).
    private var presetsGroup: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            SectionCaption("Presets")
            if !export.presets.isEmpty {
                Menu("Apply preset") {
                    ForEach(export.presets) { preset in Button(preset.name) { export.apply(preset) } }
                    Divider()
                    ForEach(export.presets) { preset in
                        Button("Delete “\(preset.name)”", role: .destructive) { Task { await export.deletePreset(preset) } }
                    }
                }
                .menuStyle(.borderedButton).fixedSize()
            }
            HStack(spacing: DSSpacing.sm) {
                TextField("Preset name", text: $presetName, prompt: Text("Save current options as…"))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.regular)
                    .frame(minHeight: 28)
                    .onSubmit(savePreset)
                    .accessibilityLabel("Save as preset")
                    .accessibilityIdentifier("export.presetName")
                Button("Save", action: savePreset)
                    .buttonStyle(.bordered).controlSize(.regular)
                    .disabled(!canSavePreset)
                    .accessibilityIdentifier("export.presetSave")
            }
        }
    }

    private func formatGroup(_ title: LocalizedStringKey, formats: [ExportFormat]) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            SectionCaption(title)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64, maximum: 84), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(formats, id: \.self) { format in
                    Button {
                        export.options.format = format
                    } label: {
                        Text(format == .markdown ? "MD" : format.rawValue.uppercased())
                            .font(DSTypography.badge).frame(maxWidth: .infinity, minHeight: 24)
                            .foregroundStyle(export.options.format == format ? DSColor.accentText : DSColor.secondaryText)
                            .background(export.options.format == format ? DSColor.accentTint : DSColor.insetBackground, in: Capsule())
                    }
                    .buttonStyle(.plain).help(EditorExportModel.title(for: format))
                    .accessibilityLabel(EditorExportModel.title(for: format))
                    .accessibilityAddTraits(export.options.format == format ? .isSelected : [])
                    .accessibilityIdentifier("export.format.\(format.rawValue)")
                }
            }
        }
    }

    private var exportOptions: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            Toggle("Speaker labels", isOn: $export.options.includeSpeakers)
            Divider()
            Picker("Timestamps", selection: timestampBinding) {
                Text("None").tag(0)
                Text("Per segment").tag(1)
                Text("Per paragraph").tag(2)
                Text("Every 30 seconds").tag(3)
            }
            Divider()
            Toggle("Include ignored segments", isOn: $export.options.includeIgnored)
            Toggle("Merge consecutive same-speaker segments", isOn: $export.options.mergeSameSpeaker)
            Toggle("Group into paragraphs", isOn: $export.options.paragraphGrouping)
            if !export.translationLanguages.isEmpty {
                Divider()
                Picker("Version", selection: $export.options.translation) {
                    Text("Original").tag(TranslationExportMode.none)
                    Text("Translated").tag(TranslationExportMode.replace)
                    Text("Bilingual").tag(TranslationExportMode.bilingual)
                }
                if export.options.translation != .none {
                    Picker("Translation language", selection: $export.options.translationLanguage) {
                        Text("Choose a language").tag(LanguageCode?.none)
                        ForEach(export.translationLanguages, id: \.self) { Text($0.rawValue.uppercased()).tag(LanguageCode?.some($0)) }
                    }
                }
            }
        }
        .padding(DSSpacing.lg).dsSolidSurface(.inset, radius: DSRadius.card)
    }

    private var timestampBinding: Binding<Int> {
        Binding(
            get: {
                switch export.options.timestamps {
                case .none: 0
                case .perSegment: 1
                case .perParagraph: 2
                case .everyNSeconds: 3
                }
            },
            set: {
                export.options.timestamps =
                    switch $0 {
                    case 0: .none
                    case 1: .perSegment
                    case 2: .perParagraph
                    default: .everyNSeconds(30)
                    }
            })
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Transcript.\(Self.fileExtension(export.options.format))"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await export.export(to: url)
            if export.errorMessage == nil { onClose() }
        }
    }

    static func fileExtension(_ format: ExportFormat) -> String {
        format == .markdown ? "md" : format.rawValue
    }
}
