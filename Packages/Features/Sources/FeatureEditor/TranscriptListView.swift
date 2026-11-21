import AppCore
import AppKit
import DesignSystem
import SwiftUI

/// Formats a media time as `m:ss` / `h:mm:ss`.
enum TimeFormat {
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// The scrolling transcript: segment or paragraph rows on a solid, readable background (EDIT-AC-01, 04, 10).
struct TranscriptListView: View {
    let model: TranscriptEditorModel
    let find: FindReplaceModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.options.layout == .paragraphs {
                        ForEach(model.paragraphs) { paragraph in
                            ParagraphRowView(model: model, find: find, paragraph: paragraph).id(paragraph.id)
                        }
                    } else {
                        ForEach(model.visibleSegments) { segment in
                            SegmentRowView(model: model, find: find, segment: segment).id(segment.id)
                        }
                    }
                }
                .padding(.vertical, DSSpacing.sm)
            }
            .background(DSColor.contentBackground)
            .onScrollPhaseChange { _, phase in
                if phase == .interacting || phase == .decelerating { model.playback.userDidScroll() }
            }
            .onChange(of: model.playback.scrollRequest) {
                guard model.playback.autoFollow, let target = model.playback.scrollTargetID else { return }
                scroll(proxy, to: target, animated: true)
            }
            .onChange(of: model.revealRequest) {
                if let request = model.revealRequest { scroll(proxy, to: request.segmentID, animated: true) }
            }
            .overlay(alignment: .bottom) {
                if model.playback.showsReturnToPlayhead {
                    Button {
                        model.playback.returnToPlayhead()
                    } label: {
                        Label("Return to playhead", systemImage: "scope")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .padding(DSSpacing.md)
                    .transition(.opacity)
                }
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to segmentID: SegmentID, animated: Bool) {
        let target = model.options.layout == .paragraphs ? (model.paragraphIDBySegment[segmentID] ?? segmentID) : segmentID
        if animated {
            withAnimation(.smooth(duration: 0.25)) { proxy.scrollTo(target, anchor: .center) }
        } else {
            proxy.scrollTo(target, anchor: .center)
        }
    }
}

// MARK: - Shared row pieces

/// Builds the word items for a segment, applying karaoke, find and user-highlight state.
@MainActor
func wordItems(for segment: Segment, model: TranscriptEditorModel, find: FindReplaceModel) -> [WordItem] {
    let display = segment.words.isEmpty ? SegmentOps.synthesizedWords(for: segment) : segment.words
    let active = model.playback.activeRef?.segmentID == segment.id ? model.playback.activeRef?.wordIndex : nil
    let found = find.matchedWords[segment.id] ?? []
    let marks = model.highlights(in: segment.id)
    let underline = model.options.underlineLowConfidence
    return display.enumerated().map { index, word in
        var item = WordItem(
            segmentID: segment.id, index: index, text: word.text.trimmingCharacters(in: .whitespacesAndNewlines),
            isActive: active == index, isFound: found.contains(index))
        item.highlight = marks.first { $0.wordRange?.contains(index) ?? true }?.colorName
        item.isLowConfidence = underline && (word.confidence ?? 1) < ViewOptions.lowConfidenceThreshold
        return item
    }
}

/// Speaker, timestamp and language badge shown beside the text.
struct SegmentGutter: View {
    let model: TranscriptEditorModel
    let speakerID: SpeakerID?
    let start: TimeInterval
    let language: LanguageCode?
    var isIgnored = false

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            if model.options.showSpeakers {
                if let speaker = model.speaker(speakerID) {
                    HStack(spacing: DSSpacing.xs) {
                        Circle().fill(EditorColors.color(model.color(for: speakerID))).frame(width: 8, height: 8)
                        Text(speaker.name).font(DSTypography.caption.weight(.semibold)).lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                } else {
                    Text("Unknown").font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                }
            }
            if model.options.showTimestamps {
                Text(TimeFormat.clock(start)).font(DSTypography.timestamp).foregroundStyle(DSColor.secondaryText)
            }
            HStack(spacing: DSSpacing.xs) {
                if model.options.showLanguageBadges, let language { LanguageBadge(language) }
                if isIgnored { StatusPill("Ignored", tone: .neutral) }
            }
        }
        .frame(width: 112, alignment: .leading)
    }
}

/// Selection with ⌘ (toggle) and ⇧ (range) modifiers.
@MainActor
func updateSelection(model: TranscriptEditorModel, id: SegmentID) {
    let flags = NSEvent.modifierFlags
    if flags.contains(.command) {
        if model.selection.contains(id) { model.selection.remove(id) } else { model.selection.insert(id) }
    } else if flags.contains(.shift), let last = model.selection.first,
        let a = model.visibleSegments.firstIndex(where: { $0.id == last }), let b = model.visibleSegments.firstIndex(where: { $0.id == id })
    {
        model.selection = Set(model.visibleSegments[min(a, b)...max(a, b)].map(\.id))
    } else {
        model.selection = [id]
    }
}

// MARK: - Segment row

struct SegmentRowView: View {
    let model: TranscriptEditorModel
    let find: FindReplaceModel
    let segment: Segment

    @State private var draft = ""
    @FocusState private var focused: Bool

    private var isEditing: Bool { model.editingSegmentID == segment.id }
    private var isSelected: Bool { model.selection.contains(segment.id) }
    private var isCurrentFindSegment: Bool { find.isVisible && find.currentMatch?.segmentID == segment.id }

    var body: some View {
        let typography = EditorTypography(model.options)
        HStack(alignment: .top, spacing: DSSpacing.md) {
            SegmentGutter(
                model: model, speakerID: segment.speakerID, start: segment.start, language: segment.languageCode,
                isIgnored: segment.isIgnored
            )
            .contentShape(Rectangle())
            .onTapGesture { updateSelection(model: model, id: segment.id) }
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                if isEditing {
                    editor(typography)
                } else {
                    WordFlowView(
                        items: wordItems(for: segment, model: model, find: find), typography: typography,
                        onTap: {
                            model.requestListFocus()
                            model.playback.seekToWord(in: segment, wordIndex: $0.index)
                        },
                        onSplit: { model.split(segment.id, beforeWord: $0.index) },
                        onBookmark: { model.addBookmark(at: SeekTarget.time(for: segment, wordIndex: $0.index)) },
                        onHighlight: { model.addHighlight(segmentID: segment.id, wordRange: $0.index...$0.index) })
                }
                if segment.isIgnored {
                    Button("Stop ignoring") { model.setIgnored(false, for: [segment.id]) }
                        .buttonStyle(.link).font(DSTypography.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DSSpacing.lg)
        .padding(.vertical, model.options.density.rowPadding)
        .opacity(segment.isIgnored ? 0.5 : 1)
        .background(rowBackground)
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { if !isEditing { model.playback.playFrom(segment) } })
        .contextMenu { SegmentContextMenu(model: model, segment: segment) }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isSelected {
            Color.accentColor.opacity(0.12)
        } else if isCurrentFindSegment {
            Color.orange.opacity(0.10)
        } else {
            Color.clear
        }
    }

    private func editor(_ typography: EditorTypography) -> some View {
        TextField("", text: $draft, axis: .vertical)
            .textFieldStyle(.plain)
            .font(typography.font)
            .lineSpacing(typography.lineSpacing)
            .focused($focused)
            .padding(DSSpacing.xs)
            .background(RoundedRectangle(cornerRadius: DSRadius.small).stroke(Color.accentColor, lineWidth: 1))
            .onSubmit { model.commitEditing(text: draft) }
            .onExitCommand { model.cancelEditing() }
            .onAppear {
                draft = segment.text
                focused = true
            }
            .onChange(of: focused) {
                if !focused, model.editingSegmentID == segment.id { model.commitEditing(text: draft) }
            }
    }
}

/// Right-click actions for a segment (edit, play, merge, speaker, language, ignore, bookmark, highlight).
struct SegmentContextMenu: View {
    let model: TranscriptEditorModel
    let segment: Segment

    var body: some View {
        let targets: Set<SegmentID> = model.selection.contains(segment.id) ? model.selection : [segment.id]
        Button("Play From Here") { model.playback.playFrom(segment) }.disabled(!model.playback.canPlay)
        Button("Edit Text") {
            if model.options.layout == .paragraphs { model.updateOptions { $0.layout = .segments } }
            model.beginEditing(segment.id)
        }
        Divider()
        Button("Merge With Previous") { model.merge(segment.id, withNext: false) }
        Button("Merge With Next") { model.merge(segment.id, withNext: true) }
        Divider()
        Menu("Change Speaker") {
            ForEach(model.speakers) { speaker in
                Button(speaker.name) { model.setSpeaker(speaker.id, for: targets) }
            }
            Divider()
            Button("No Speaker") { model.setSpeaker(nil, for: targets) }
        }
        Menu("Change Language") {
            ForEach(model.languageChoices, id: \.self) { code in
                Button(Locale.current.localizedString(forLanguageCode: code.rawValue).map { "\($0) (\(code.rawValue))" } ?? code.rawValue) {
                    model.setLanguage(code, for: targets)
                }
            }
        }
        Divider()
        Button("Add Bookmark") { model.addBookmark(at: segment.start) }
        Button("Highlight Segment") { model.addHighlight(segmentID: segment.id) }
        Button(segment.isIgnored ? "Stop Ignoring" : "Ignore Segment") { model.setIgnored(!segment.isIgnored, for: targets) }
        Divider()
        Button("Copy Text") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(segment.text, forType: .string)
        }
    }
}

// MARK: - Paragraph row

struct ParagraphRowView: View {
    let model: TranscriptEditorModel
    let find: FindReplaceModel
    let paragraph: TranscriptParagraph

    var body: some View {
        let typography = EditorTypography(model.options)
        let items = paragraph.segments.flatMap { wordItems(for: $0, model: model, find: find) }
        let byID = Dictionary(paragraph.segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        HStack(alignment: .top, spacing: DSSpacing.md) {
            SegmentGutter(model: model, speakerID: paragraph.speakerID, start: paragraph.start, language: paragraph.languageCode)
            WordFlowView(
                items: items, typography: typography,
                onTap: { item in
                    model.requestListFocus()
                    if let s = byID[item.segmentID] { model.playback.seekToWord(in: s, wordIndex: item.index) }
                },
                onSplit: { item in model.split(item.segmentID, beforeWord: item.index) },
                onBookmark: { item in
                    if let s = byID[item.segmentID] { model.addBookmark(at: SeekTarget.time(for: s, wordIndex: item.index)) }
                },
                onHighlight: { item in model.addHighlight(segmentID: item.segmentID, wordRange: item.index...item.index) }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DSSpacing.lg)
        .padding(.vertical, model.options.density.rowPadding)
        .opacity(paragraph.segments.allSatisfy(\.isIgnored) ? 0.5 : 1)
    }
}
