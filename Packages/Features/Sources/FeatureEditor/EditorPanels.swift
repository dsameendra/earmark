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
            ForEach(model.speakers) { speaker in
                SpeakerRow(model: model, speaker: speaker)
            }
            Divider()
            HStack {
                TextField("New speaker", text: $newName).textFieldStyle(.roundedBorder).onSubmit(add)
                Button("Add", action: add).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(DSSpacing.lg)
        .frame(width: 360)
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
                Text("\(model.segmentCount(for: speaker.id))").font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                Menu("Merge") {
                    ForEach(model.speakers.filter { $0.id != speaker.id }) { other in
                        Button("Into \(other.name)") { model.mergeSpeaker(speaker.id, into: other.id) }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize().disabled(model.speakers.count < 2)
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
                }
            }
            .padding(.leading, 18)
        }
        .onAppear { name = speaker.name }
        .onChange(of: speaker.name) { name = speaker.name }
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
                    Label("Bookmark Playhead", systemImage: "bookmark")
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
        .frame(width: 380, height: 320)
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
            Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }.buttonStyle(.borderless)
                .accessibilityLabel("Delete")
        }
        .onAppear { text = note }
    }
}

/// Font, size, spacing, density, toggles; global default or this transcript only (EDIT-AC-14).
struct ViewOptionsPanel: View {
    let model: TranscriptEditorModel
    static let families: [String?] = [nil, "New York", "Helvetica Neue", "Georgia", "Menlo", "Sinhala Sangam MN"]

    var body: some View {
        let options = model.options
        Form {
            Picker("Layout", selection: binding(\.layout)) {
                ForEach(TranscriptLayoutMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Font", selection: binding(\.fontFamily)) {
                ForEach(Self.families, id: \.self) { Text($0 ?? "System").tag($0) }
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
        .frame(width: 360)
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
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            Text("Export").font(DSTypography.title)
            Form {
                Picker("Format", selection: $export.options.format) {
                    ForEach(EditorExportModel.formats, id: \.self) { Text(EditorExportModel.title(for: $0)).tag($0) }
                }
                Picker("Timestamps", selection: timestampBinding) {
                    Text("None").tag(0)
                    Text("Per segment").tag(1)
                    Text("Per paragraph").tag(2)
                    Text("Every 30 seconds").tag(3)
                }
                Toggle("Include speaker names", isOn: $export.options.includeSpeakers)
                Toggle("Merge consecutive same-speaker segments", isOn: $export.options.mergeSameSpeaker)
                Toggle("Group into paragraphs", isOn: $export.options.paragraphGrouping)
                Toggle("Include ignored segments", isOn: $export.options.includeIgnored)
            }
            .formStyle(.grouped)
            if !export.presets.isEmpty {
                Menu("Presets") {
                    ForEach(export.presets) { preset in
                        Button(preset.name) { export.apply(preset) }
                    }
                    Divider()
                    ForEach(export.presets) { preset in
                        Button("Delete “\(preset.name)”", role: .destructive) { Task { await export.deletePreset(preset) } }
                    }
                }
            }
            HStack {
                TextField("Save as preset", text: $presetName).textFieldStyle(.roundedBorder)
                Button("Save") {
                    Task {
                        await export.savePreset(named: presetName)
                        presetName = ""
                    }
                }
                .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let message = export.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(DSColor.danger).font(DSTypography.caption)
            } else if let status = export.statusMessage {
                Text(status).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
            }
            HStack {
                Button("Copy as Text") { Task { await export.copy(markdown: false) } }
                Button("Copy as Markdown") { Task { await export.copy(markdown: true) } }
                if let shareURL {
                    ShareLink(item: shareURL) { Label("Share", systemImage: "square.and.arrow.up") }
                } else {
                    Button {
                        Task { shareURL = await export.prepareShareFile() }
                    } label: {
                        Label("Prepare to Share", systemImage: "square.and.arrow.up")
                    }
                }
                Spacer()
                Button("Close", role: .cancel, action: onClose).keyboardShortcut(.cancelAction)
                Button("Export…") { save() }.keyboardShortcut(.defaultAction).disabled(export.isWorking)
            }
        }
        .padding(DSSpacing.lg)
        .frame(width: 520)
        .task { await export.loadPresets() }
        .onChange(of: export.options) { shareURL = nil }
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
