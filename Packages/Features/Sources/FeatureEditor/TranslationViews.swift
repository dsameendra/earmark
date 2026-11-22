import AppCore
import AppKit
import DesignSystem
import Processing
import SwiftUI

/// Reading direction of a language (Arabic, Hebrew, Persian, Urdu run right to left).
enum TextDirection {
    static func isRightToLeft(_ language: LanguageCode?) -> Bool {
        guard let language else { return false }
        return Locale.Language(identifier: language.rawValue).characterDirection == .rightToLeft
    }

    static func layoutDirection(_ language: LanguageCode?) -> LayoutDirection {
        isRightToLeft(language) ? .rightToLeft : .leftToRight
    }
}

/// Whether a translation is the main text of its row (Translated mode) or the secondary line under the original (Bilingual).
enum TranslationStyle { case primary, secondary }

extension EditorTypography {
    /// The same family at a fraction of the size (secondary translation lines).
    func scaled(_ factor: Double) -> EditorTypography {
        var copy = self
        copy.size = size * factor
        return copy
    }
}

/// Builds attributed text for translation lines: NFC text with find highlights and an optional active-run background.
enum TranslationText {
    static func attributed(
        _ text: String, matches: [NSRange] = [], current: NSRange? = nil, isActive: Bool = false
    ) -> AttributedString {
        var out = AttributedString(TextNormalizer.nfc(text))
        if isActive { out.backgroundColor = EditorColors.active }
        for range in matches {
            guard let r = Range(range, in: out) else { continue }
            out[r].backgroundColor = range == current ? Color.orange.opacity(0.6) : EditorColors.found
        }
        return out
    }
}

/// The translation drawn under the original (bilingual) or instead of it (translated), with the low-confidence and
/// out-of-date labels (TRN-AC-07, TRN-AC-10). Right-to-left targets are laid out right to left.
struct TranslationLine: View {
    let translation: SegmentTranslationDisplay
    let typography: EditorTypography
    var style: TranslationStyle = .primary
    var isActive = false
    var matches: [NSRange] = []
    var current: NSRange?
    var onTap: (() -> Void)?

    var body: some View {
        let rtl = TextDirection.layoutDirection(translation.language)
        let face = style == .secondary ? typography.scaled(0.92) : typography
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text(TranslationText.attributed(translation.text, matches: matches, current: current, isActive: isActive))
                .font(face.font).lineSpacing(face.lineSpacing)
                .foregroundStyle(style == .secondary || translation.isStale ? DSColor.secondaryText : DSColor.primaryText)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { onTap?() }
                .accessibilityLabel("Translation: \(translation.text)")
            if translation.isLowConfidence || translation.isStale {
                HStack(spacing: DSSpacing.xs) {
                    if translation.isLowConfidence {
                        StatusPill("Low confidence", systemImage: "exclamationmark.triangle", tone: .warning)
                    }
                    if translation.isStale {
                        StatusPill("Out of date", systemImage: "clock.arrow.circlepath", tone: .neutral)
                    }
                }
            }
        }
        .environment(\.layoutDirection, rtl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The quiet state for a segment that has no translation yet: the original stays readable and this says why.
struct UntranslatedNote: View {
    var isPending: Bool
    var body: some View {
        HStack(spacing: DSSpacing.xs) {
            if isPending {
                ProgressView().controlSize(.mini)
                Text("Translating…")
            } else {
                Image(systemName: "text.badge.minus").imageScale(.small)
                Text("Not translated")
            }
        }
        .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
        .accessibilityElement(children: .combine)
    }
}

/// A paragraph's translations as flowing text. Untranslated segments keep their original wording (dimmed, italic) so the
/// paragraph never has holes. Each segment is a link so a click seeks to it.
struct ParagraphTranslationText: View {
    let model: TranscriptEditorModel
    let find: FindReplaceModel
    let paragraph: TranscriptParagraph
    let typography: EditorTypography
    var style: TranslationStyle
    var language: LanguageCode?

    var body: some View {
        let rtl = TextDirection.layoutDirection(language)
        let face = style == .secondary ? typography.scaled(0.92) : typography
        let active = model.playback.activeRef?.segmentID
        let segments = paragraph.segments
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            let text = Self.attributed(segments, model: model, find: find, style: style, activeID: active)
            if !text.characters.isEmpty {
                Text(text)
                .font(face.font).lineSpacing(face.lineSpacing)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .tint(style == .secondary ? DSColor.secondaryText : DSColor.primaryText)
                .environment(
                    \.openURL,
                    OpenURLAction { url in
                        guard let host = url.host, let index = Int(host), segments.indices.contains(index) else { return .discarded }
                        model.requestListFocus()
                        model.playback.seekToWord(in: segments[index], wordIndex: 0)
                        return .handled
                    })
            }
            let displays = segments.compactMap { model.translationDisplay(for: $0) }
            if displays.contains(where: \.isLowConfidence) {
                StatusPill("Low confidence", systemImage: "exclamationmark.triangle", tone: .warning)
            }
            if displays.contains(where: \.isStale) {
                StatusPill("Out of date", systemImage: "clock.arrow.circlepath", tone: .neutral)
            }
            if segments.contains(where: { model.isMissingTranslation($0) }) {
                UntranslatedNote(isPending: model.isTranslating(to: model.translationChoice.target))
            }
        }
        .environment(\.layoutDirection, rtl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @MainActor
    static func attributed(
        _ segments: [Segment], model: TranscriptEditorModel, find: FindReplaceModel, style: TranslationStyle, activeID: SegmentID?
    ) -> AttributedString {
        var out = AttributedString()
        let base: Color = style == .secondary ? DSColor.secondaryText : DSColor.primaryText
        for (index, segment) in segments.enumerated() {
            var piece: AttributedString
            if let display = model.translationDisplay(for: segment) {
                let ranges = find.translationRanges[segment.id] ?? []
                let current: NSRange? = find.currentTranslationRange(in: segment.id)
                piece = TranslationText.attributed(display.text, matches: ranges, current: current)
                piece.foregroundColor = display.isStale ? DSColor.secondaryText : base
            } else if style == .primary {
                // Translated mode, no translation: the original, quietly marked.
                piece = AttributedString(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
                piece.foregroundColor = DSColor.secondaryText
                piece.inlinePresentationIntent = .emphasized
            } else {
                continue
            }
            if segment.id == activeID { piece.backgroundColor = EditorColors.active }
            piece.link = URL(string: "earmark-seek://\(index)")
            if !out.characters.isEmpty { out.append(AttributedString(" ")) }
            out.append(piece)
        }
        return out
    }
}
