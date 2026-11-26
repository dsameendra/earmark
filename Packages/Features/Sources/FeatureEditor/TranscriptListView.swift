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
    /// The row at the top of the viewport, kept across layout and translation-mode switches so the text does not jump.
    @State private var topID: SegmentID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityPolicyOverride) private var policyOverride

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
                .scrollTargetLayout()
                // Generous bottom slack: the lazily measured last row, the transport dock and the "Return to playhead"
                // button must never hide the final line when the list is scrolled to its end.
                .padding(.top, DSSpacing.sm)
                .padding(.bottom, DSSpacing.xxl)
                .dsAnimation(.glide, value: model.visibleSegments.count)
            }
            .contentMargins(.bottom, DSSpacing.lg, for: .scrollContent)
            .scrollPosition(id: $topID, anchor: .top)
            .onChange(of: model.translationChoice) { keepPosition(proxy) }
            .onChange(of: model.options.layout) { keepPosition(proxy) }
            .onChange(of: model.options.showTimestamps) { keepPosition(proxy) }
            .onChange(of: model.options.showSpeakers) { keepPosition(proxy) }
            .onChange(of: model.options.density) { keepPosition(proxy) }
            .onChange(of: model.options.fontSize) { keepPosition(proxy) }
            .background(DSColor.contentBackground)
            .onScrollPhaseChange { _, phase in
                if phase == .interacting || phase == .decelerating {
                    model.playback.userDidScroll()
                    model.userScrolledAwayFromLatest()
                }
            }
            .onChange(of: model.liveTailToken) {
                // Live transcribing: keep the newest segment in view, unless the user scrolled up or is following playback.
                guard model.isTranscribing, model.followsLatest, !(model.playback.isPlaying && model.playback.autoFollow),
                    let last = model.visibleSegments.last
                else { return }
                let lastID = last.id
                Task { @MainActor in
                    await Task.yield()  // let the new row lay out first
                    scroll(proxy, to: lastID, animated: true, anchor: .bottom)
                }
            }
            .onChange(of: model.playback.scrollRequest) {
                guard model.playback.autoFollow, let target = model.playback.scrollTargetID else { return }
                scroll(proxy, to: target, animated: true)
            }
            .onChange(of: model.revealRequest) {
                if let request = model.revealRequest { scroll(proxy, to: request.segmentID, animated: true) }
            }
            .overlay(alignment: .bottom) {
                HStack(spacing: DSSpacing.sm) {
                    if model.playback.showsReturnToPlayhead {
                        Button {
                            model.playback.returnToPlayhead()
                        } label: {
                            Label("Return to playhead", systemImage: "scope")
                        }
                        .dsProminentButton()
                        .controlSize(.regular)
                        .dsTransition(.glide)
                    }
                    if model.isTranscribing && !model.followsLatest {
                        Button {
                            model.followLatest()
                        } label: {
                            Label("Follow latest", systemImage: "arrow.down.to.line")
                        }
                        .dsProminentButton()
                        .controlSize(.regular)
                        .dsTransition(.glide)
                        .help("Jump to the newest transcribed text and keep following it")
                        .accessibilityIdentifier("editor.followLatest")
                    }
                }
                .padding(DSSpacing.md)
            }
            .dsAnimation(.glide, value: model.playback.showsReturnToPlayhead)
            .dsAnimation(.glide, value: model.followsLatest)
        }
    }

    /// Re-anchors the viewport on the row that was at the top before row heights changed.
    private func keepPosition(_ proxy: ScrollViewProxy) {
        guard let saved = topID else { return }
        let target = model.options.layout == .paragraphs ? (model.paragraphIDBySegment[saved] ?? saved) : saved
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(target, anchor: .top)
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to segmentID: SegmentID, animated: Bool, anchor: UnitPoint = .center) {
        let target = model.options.layout == .paragraphs ? (model.paragraphIDBySegment[segmentID] ?? segmentID) : segmentID
        if animated && !(policyOverride?.suppressesMotion ?? reduceMotion) {
            withAnimation(DSMotion.glide.animation()) { proxy.scrollTo(target, anchor: anchor) }
        } else {
            proxy.scrollTo(target, anchor: anchor)
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
    var isRelabeled = false
    var isLanguageUncertain = false
    var isRetranscribing = false

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            if model.options.showSpeakers {
                if let speaker = model.speaker(speakerID) {
                    HStack(spacing: DSSpacing.xs) {
                        Circle().fill(EditorColors.color(model.color(for: speakerID))).frame(width: 8, height: 8)
                        Text(speaker.name).font(DSTypography.caption.weight(.semibold)).lineLimit(1)
                        if isRelabeled {
                            Image(systemName: EditorSymbol.relabeled).font(DSTypography.caption).foregroundStyle(DSColor.accent)
                                .help("Relabelled when the meeting was finalized").accessibilityLabel("Relabelled")
                        }
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
                if isLanguageUncertain {
                    Image(systemName: "questionmark.circle").font(DSTypography.caption).foregroundStyle(DSColor.warning)
                        .help("Uncertain language: the previous language was assumed. Right-click to change or re-transcribe.")
                        .accessibilityLabel("Language uncertain")
                }
                if isRetranscribing { ProgressView().controlSize(.mini) }
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
    let anchorIndex = model.selection.first.flatMap { anchor in model.visibleSegments.firstIndex { $0.id == anchor } }
    let targetIndex = model.visibleSegments.firstIndex { $0.id == id }
    if flags.contains(.command) {
        if model.selection.contains(id) { model.selection.remove(id) } else { model.selection.insert(id) }
    } else if flags.contains(.shift), let a = anchorIndex, let b = targetIndex {
        model.selection = Set(model.visibleSegments[min(a, b)...max(a, b)].map(\.id))
    } else {
        model.selection = [id]
    }
}

/// Selects a whole paragraph (⌘ toggles it).
@MainActor
func updateSelection(model: TranscriptEditorModel, ids: Set<SegmentID>) {
    if NSEvent.modifierFlags.contains(.command) {
        if ids.isSubset(of: model.selection) { model.selection.subtract(ids) } else { model.selection.formUnion(ids) }
    } else {
        model.selection = ids
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
                model: model, speakerID: segment.speakerID, start: segment.start, language: model.gutterLanguage(for: [segment]),
                isIgnored: segment.isIgnored, isRelabeled: model.relabeledSegmentIDs.contains(segment.id),
                isLanguageUncertain: model.isLanguageUncertain(segment), isRetranscribing: model.retranscribing.contains(segment.id)
            )
            .contentShape(Rectangle())
            .onTapGesture { updateSelection(model: model, id: segment.id) }
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                let presentation = model.presentation(for: segment)
                let seek = {
                    model.requestListFocus()
                    _ = model.playback.seekToWord(in: segment, wordIndex: 0)
                }
                let isActive = model.playback.activeRef?.segmentID == segment.id
                let ranges = find.translationRanges[segment.id] ?? []
                let currentRange: NSRange? = find.currentTranslationRange(in: segment.id)
                if isEditing {
                    if case .translated = presentation {
                        Text("Editing the original text").font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                    }
                    editor(typography)
                    if case .translated(let translation) = presentation {
                        TranslationLine(translation: translation, typography: typography, style: .secondary)
                    } else if case .bilingual(let translation) = presentation {
                        TranslationLine(translation: translation, typography: typography, style: .secondary)
                    }
                } else {
                    switch presentation {
                    case .translated(let translation):
                        TranslationLine(
                            translation: translation, typography: typography, isActive: isActive, matches: ranges,
                            current: currentRange, onTap: seek)
                    case .bilingual(let translation):
                        originalWords(typography)
                        TranslationLine(
                            translation: translation, typography: typography, style: .secondary, isActive: isActive,
                            matches: ranges, current: currentRange, onTap: seek)
                    case .untranslated(let isPending):
                        originalWords(typography)
                        UntranslatedNote(isPending: isPending)
                    case .original:
                        originalWords(typography)
                    }
                }
                if segment.isIgnored {
                    Button("Stop ignoring") { model.setIgnored(false, for: [segment.id]) }
                        .buttonStyle(.dsLink).font(DSTypography.caption).disabled(model.isLockedByJob)
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
            TapGesture(count: 2).onEnded { if !isEditing { model.playback.playFrom(segment) } }
        )
        .contextMenu { SegmentContextMenu(model: model, segment: segment) }
        .accessibilityElement(children: .contain)
    }

    private func originalWords(_ typography: EditorTypography) -> some View {
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
        let locked = model.isLockedByJob
        Button("Play From Here") { model.playback.playFrom(segment) }.disabled(!model.playback.canPlay)
        if let reason = model.lockedHelp {
            // Editing is unavailable until the queue finishes writing; say why instead of just greying items out.
            Button(reason) {}.disabled(true)
        }
        Button("Edit Text") {
            if model.options.layout == .paragraphs { model.updateOptions { $0.layout = .segments } }
            model.beginEditing(segment.id)
        }
        .disabled(locked)
        Divider()
        Button("Merge With Previous") { model.merge(segment.id, withNext: false) }.disabled(locked)
        Button("Merge With Next") { model.merge(segment.id, withNext: true) }.disabled(locked)
        Divider()
        Menu("Change Speaker") {
            ForEach(model.speakers) { speaker in
                Button(speaker.name) { model.setSpeaker(speaker.id, for: targets) }
            }
            Divider()
            Button("No Speaker") { model.setSpeaker(nil, for: targets) }
        }
        .disabled(locked)
        Menu("Change Speaker From Playhead") {
            ForEach(model.speakers) { speaker in
                Button(speaker.name) { model.reassignWordsFromPlayhead(in: segment.id, to: speaker.id) }
            }
        }
        .disabled(locked || !model.playheadIsInside(segment.id))
        Menu("Change Language") {
            ForEach(model.languageChoices, id: \.self) { code in
                Button(Locale.current.localizedString(forLanguageCode: code.rawValue).map { "\($0) (\(code.rawValue))" } ?? code.rawValue) {
                    model.setLanguage(code, for: targets)
                }
            }
        }
        .disabled(locked)
        if model.canRetranscribe {
            Menu("Re-transcribe As") {
                ForEach(model.languageChoices, id: \.self) { code in
                    Button(TranscriptEditorModel.name(of: code) + " (\(code.rawValue))") {
                        Task { await model.retranscribe(segment.id, as: code) }
                    }
                }
            }
            .disabled(model.retranscribing.contains(segment.id))
        }
        Divider()
        Button("Add Bookmark") { model.addBookmark(at: segment.start) }
        Button("Highlight Segment") { model.addHighlight(segmentID: segment.id) }
        Button(segment.isIgnored ? "Stop Ignoring" : "Ignore Segment") { model.setIgnored(!segment.isIgnored, for: targets) }
            .disabled(locked)
        Divider()
        Button("Copy Text") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(model.displayedText(for: targets), forType: .string)
        }
    }
}

// MARK: - Paragraph row

struct ParagraphRowView: View {
    let model: TranscriptEditorModel
    let find: FindReplaceModel
    let paragraph: TranscriptParagraph

    private var ids: Set<SegmentID> { Set(paragraph.segments.map(\.id)) }
    private var isSelected: Bool { !ids.isDisjoint(with: model.selection) }

    var body: some View {
        let typography = EditorTypography(model.options)
        let mode = model.translationChoice.mode
        let hasTranslation = mode != .original && model.translationChoice.target != nil
        let showsOriginal = !hasTranslation || mode == .bilingual
        let language = model.gutterLanguage(for: paragraph.segments)
        let allIgnored = paragraph.segments.allSatisfy(\.isIgnored)
        HStack(alignment: .top, spacing: DSSpacing.md) {
            SegmentGutter(
                model: model, speakerID: paragraph.speakerID, start: paragraph.start, language: language, isIgnored: allIgnored,
                isRelabeled: paragraph.segments.contains { model.relabeledSegmentIDs.contains($0.id) }
            )
            .contentShape(Rectangle())
            .onTapGesture { updateSelection(model: model, ids: ids) }
            .contextMenu { SegmentContextMenu(model: model, segment: paragraph.segments[0]) }
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                if mode == .translated, hasTranslation {
                    ParagraphTranslationText(
                        model: model, find: find, paragraph: paragraph, typography: typography, style: .primary,
                        language: model.translationChoice.target)
                } else {
                    originalFlow(typography)
                    if mode == .bilingual {
                        ParagraphTranslationText(
                            model: model, find: find, paragraph: paragraph, typography: typography, style: .secondary,
                            language: model.translationChoice.target)
                    }
                }
                if allIgnored {
                    Button("Stop ignoring") { model.setIgnored(false, for: ids) }.disabled(model.isLockedByJob)
                        .buttonStyle(.dsLink).font(DSTypography.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DSSpacing.lg)
        .padding(.vertical, model.options.density.rowPadding)
        .opacity(allIgnored ? 0.5 : 1)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .accessibilityElement(children: .contain)
        .accessibilityHint(showsOriginal ? "" : "Translated")
    }

    private func originalFlow(_ typography: EditorTypography) -> some View {
        let items = paragraph.segments.flatMap { wordItems(for: $0, model: model, find: find) }
        let byID = Dictionary(paragraph.segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return WordFlowView(
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
}
