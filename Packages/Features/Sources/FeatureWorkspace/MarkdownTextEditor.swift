import AppKit
import DesignSystem
import SwiftUI

/// What the notes toolbar can ask the text view to do. The view registers itself here when it is created.
@MainActor
public final class MarkdownEditorCommands {
    fileprivate weak var textView: NSTextView?
    public init() {}

    /// Wraps the selection in a marker pair (`**`, `*`) or inserts the pair and leaves the caret between.
    public func wrap(_ marker: String) {
        guard let view = textView else { return }
        let range = view.selectedRange()
        let selected = (view.string as NSString).substring(with: range)
        replace(range, with: marker + selected + marker, caretOffset: selected.isEmpty ? marker.count : nil, in: view)
    }

    /// Puts `prefix` at the start of every selected line (a heading, bullet, number or checkbox), or removes it when every line
    /// already has it.
    public func prefixLines(_ prefix: String) {
        guard let view = textView else { return }
        let text = view.string as NSString
        let lineRange = text.lineRange(for: view.selectedRange())
        let block = text.substring(with: lineRange)
        let hadTrailingNewline = block.hasSuffix("\n")
        var lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if hadTrailingNewline { lines.removeLast() }
        let all = lines.allSatisfy { $0.hasPrefix(prefix) }
        lines = lines.map { all ? String($0.dropFirst(prefix.count)) : prefix + Self.strippedBlockPrefix($0) }
        replace(lineRange, with: lines.joined(separator: "\n") + (hadTrailingNewline ? "\n" : ""), caretOffset: nil, in: view)
    }

    public func insert(_ text: String) {
        guard let view = textView else { return }
        replace(view.selectedRange(), with: text, caretOffset: nil, in: view)
    }

    private static func strippedBlockPrefix(_ line: String) -> String {
        for prefix in ["- [ ] ", "- [x] ", "- ", "* ", "### ", "## ", "# "] where line.hasPrefix(prefix) { return String(line.dropFirst(prefix.count)) }
        return line
    }

    private func replace(_ range: NSRange, with text: String, caretOffset: Int?, in view: NSTextView) {
        guard view.shouldChangeText(in: range, replacementString: text) else { return }
        view.textStorage?.replaceCharacters(in: range, with: text)
        view.didChangeText()
        let caret = caretOffset.map { range.location + $0 } ?? range.location + (text as NSString).length
        view.setSelectedRange(NSRange(location: caret, length: 0))
        view.window?.makeFirstResponder(view)
    }
}

/// A Markdown editor with a live preview. The text is the Markdown itself (what is saved is exactly what is typed), but on every
/// line the caret is not on, the markers disappear and the line reads as formatted text: titles for `#`, bold, italic, code,
/// links, bullets, numbered lists, clickable checkboxes, quotes, rules, and `[12:52]` timestamps that jump playback. Move the
/// caret onto a line and its markers come back so it can be edited.
struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    let commands: MarkdownEditorCommands
    let onSeek: (TimeInterval) -> Void
    var isEditable = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1 on purpose: hiding markers and drawing bullets and checkboxes needs its glyph generation hook.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let view = MarkdownTextView(frame: .zero, textContainer: container)
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        layout.delegate = context.coordinator
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.textContainerInset = NSSize(width: 14, height: 12)
        view.isEditable = isEditable
        view.setAccessibilityIdentifier("notes.editor")
        view.setAccessibilityLabel("Notes")
        view.setAccessibilityRole(.textArea)
        view.linkTextAttributes = [:]
        view.onWrap = { [weak commands] marker in commands?.wrap(marker) }
        view.string = text
        context.coordinator.textView = view
        commands.textView = view
        MarkdownStyler.apply(to: view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        view.isEditable = isEditable
        commands.textView = view
        if view.string != text, !context.coordinator.isEditing {
            let selection = view.selectedRange()
            view.string = text
            view.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
            MarkdownStyler.apply(to: view)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSLayoutManagerDelegate {
        var parent: MarkdownTextEditor
        weak var textView: NSTextView?
        var isEditing = false

        init(_ parent: MarkdownTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            isEditing = true
            parent.text = view.string
            MarkdownStyler.apply(to: view)
            isEditing = false
        }

        /// The caret moved: the line it is on shows its markers, the line it left hides them.
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView, !view.hasMarkedText() else { return }
            MarkdownStyler.apply(to: view)
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return false }
            switch url.scheme {
            case "earmark-time":
                if let seconds = TimeInterval(url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) { parent.onSeek(seconds) }
                return true
            case "earmark-check":
                toggleCheckbox(at: charIndex, in: textView)
                return true
            default:
                return false
            }
        }

        /// Return continues a list (bullets, numbers, checkboxes) and ends it on an empty item; Tab and Shift-Tab indent.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): return continueList(in: textView)
            case #selector(NSResponder.insertTab(_:)): return indent(in: textView, by: 1)
            case #selector(NSResponder.insertBacktab(_:)): return indent(in: textView, by: -1)
            default: return false
            }
        }

        private func continueList(in view: NSTextView) -> Bool {
            let text = view.string as NSString
            let selection = view.selectedRange()
            guard selection.length == 0 else { return false }
            let line = text.lineRange(for: selection)
            let content = text.substring(with: line).trimmingCharacters(in: .newlines)
            guard let marker = MarkdownStyler.listMarker(of: content) else { return false }
            // Return in the middle of a line splits it; only continue when the caret is at the end of the item.
            guard selection.location >= line.location + (content as NSString).length else { return false }
            if marker.isEmptyItem {
                // An empty item: the list ends, the marker is removed.
                let range = NSRange(location: line.location, length: (content as NSString).length)
                replace(range, with: "", in: view)
                return true
            }
            replace(NSRange(location: selection.location, length: 0), with: "\n" + marker.next, in: view)
            return true
        }

        private func indent(in view: NSTextView, by direction: Int) -> Bool {
            let text = view.string as NSString
            let line = text.lineRange(for: view.selectedRange())
            let content = text.substring(with: line)
            guard MarkdownStyler.listMarker(of: content.trimmingCharacters(in: .newlines)) != nil else { return false }
            if direction > 0 {
                replace(NSRange(location: line.location, length: 0), with: "  ", in: view, keepCaretAfter: true)
            } else if content.hasPrefix("  ") {
                replace(NSRange(location: line.location, length: 2), with: "", in: view)
            } else if content.hasPrefix(" ") {
                replace(NSRange(location: line.location, length: 1), with: "", in: view)
            }
            return true
        }

        private func replace(_ range: NSRange, with string: String, in view: NSTextView, keepCaretAfter: Bool = false) {
            guard view.shouldChangeText(in: range, replacementString: string) else { return }
            view.textStorage?.replaceCharacters(in: range, with: string)
            view.didChangeText()
            let caret = range.location + (string as NSString).length
            if !keepCaretAfter || range.length > 0 { view.setSelectedRange(NSRange(location: caret, length: 0)) }
        }

        private func toggleCheckbox(at index: Int, in view: NSTextView) {
            let text = view.string as NSString
            let line = text.lineRange(for: NSRange(location: min(index, max(0, text.length - 1)), length: 0))
            let content = text.substring(with: line)
            let replacement: String
            if let range = content.range(of: "[ ] ") {
                replacement = content.replacingCharacters(in: range, with: "[x] ")
            } else if let range = content.range(of: "[x] ") {
                replacement = content.replacingCharacters(in: range, with: "[ ] ")
            } else {
                return
            }
            guard view.shouldChangeText(in: line, replacementString: replacement) else { return }
            view.textStorage?.replaceCharacters(in: line, with: replacement)
            view.didChangeText()
        }

        // MARK: Glyph generation: hidden markers and drawn bullets, checkboxes and rules

        nonisolated func layoutManager(
            _ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
            properties props: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes charIndexes: UnsafePointer<Int>,
            font: NSFont, forGlyphRange glyphRange: NSRange
        ) -> Int {
            guard let storage = layoutManager.textStorage else { return 0 }
            let count = glyphRange.length
            var newGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: count))
            var newProps = Array(UnsafeBufferPointer(start: props, count: count))
            var changed = false
            for i in 0..<count {
                let index = charIndexes[i]
                guard index < storage.length else { continue }
                if storage.attribute(MarkdownStyler.concealKey, at: index, effectiveRange: nil) != nil {
                    newProps[i] = .null
                    changed = true
                } else if let character = storage.attribute(MarkdownStyler.glyphKey, at: index, effectiveRange: nil) as? String,
                    var unit = character.utf16.first {
                    var glyph = CGGlyph()
                    let used = (storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont) ?? font
                    if CTFontGetGlyphsForCharacters(used as CTFont, &unit, &glyph, 1) {
                        newGlyphs[i] = glyph
                        changed = true
                    }
                }
            }
            guard changed else { return 0 }
            newGlyphs.withUnsafeBufferPointer { g in
                newProps.withUnsafeBufferPointer { p in
                    layoutManager.setGlyphs(g.baseAddress!, properties: p.baseAddress!, characterIndexes: charIndexes, font: font, forGlyphRange: glyphRange)
                }
            }
            return count
        }
    }
}

/// Adds the keyboard shortcuts for bold and italic.
final class MarkdownTextView: NSTextView {
    var onWrap: ((String) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, window?.firstResponder === self {
            switch event.charactersIgnoringModifiers {
            case "b": onWrap?("**"); return true
            case "i": onWrap?("*"); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Live Markdown styling. Attributes only: the characters are never changed, so undo and the saved text stay exact. Markers get
/// `concealKey` (no glyph) on lines the caret is not on; bullets, checkboxes and rules get `glyphKey` (a drawn character).
@MainActor
enum MarkdownStyler {
    nonisolated static let concealKey = NSAttributedString.Key("earmark.conceal")
    nonisolated static let glyphKey = NSAttributedString.Key("earmark.glyph")

    struct ListMarker {
        var next: String
        var isEmptyItem: Bool
    }

    /// The list marker a line starts with, for continuing the list on Return.
    static func listMarker(of line: String) -> ListMarker? {
        guard let match = line.range(of: #"^(\s*)(?:(\d+)([.)])|[-*+])(?: \[[ xX]\])? ?"#, options: .regularExpression) else { return nil }
        let prefix = String(line[match])
        let rest = String(line[match.upperBound...])
        if prefix.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        var next = prefix
        if let number = prefix.range(of: #"\d+"#, options: .regularExpression), let value = Int(prefix[number]) {
            next = prefix.replacingCharacters(in: number, with: String(value + 1))
        }
        next = next.replacingOccurrences(of: "[x]", with: "[ ]").replacingOccurrences(of: "[X]", with: "[ ]")
        if !next.hasSuffix(" ") { next += " " }
        return ListMarker(next: next, isEmptyItem: rest.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    static func apply(to view: NSTextView) {
        guard let storage = view.textStorage, let layout = view.layoutManager else { return }
        let full = NSRange(location: 0, length: storage.length)
        let text = storage.string as NSString
        let palette = Palette()
        let active = activeLines(in: view, text: text)
        storage.beginEditing()
        storage.setAttributes(palette.base, range: full)
        storage.removeAttribute(concealKey, range: full)
        storage.removeAttribute(glyphKey, range: full)
        var inFence = false
        text.enumerateSubstrings(in: full, options: [.byLines, .substringNotRequired]) { _, line, _, _ in
            let content = text.substring(with: line)
            let revealed = active.contains { NSIntersectionRange($0, NSRange(location: line.location, length: max(line.length, 1))).length > 0
                || ($0.location == line.location + line.length && line.length > 0) }
            if content.hasPrefix("```") {
                inFence.toggle()
                code(line: line, storage: storage, palette: palette)
                if !revealed { conceal(line, storage) }
                return
            }
            if inFence {
                code(line: line, storage: storage, palette: palette)
                return
            }
            block(line: line, content: content, revealed: revealed, storage: storage, palette: palette)
            inline(line: line, content: content, revealed: revealed, storage: storage, text: text, palette: palette)
        }
        storage.endEditing()
        // Attribute changes alone do not regenerate glyphs: do it for the whole page (notes are small).
        layout.invalidateGlyphs(forCharacterRange: full, changeInLength: 0, actualCharacterRange: nil)
        layout.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
        view.typingAttributes = palette.base
    }

    /// The lines the selection touches: they keep their markers visible.
    private static func activeLines(in view: NSTextView, text: NSString) -> [NSRange] {
        guard view.window?.firstResponder === view else { return view.selectedRanges.isEmpty ? [] : [] }
        return view.selectedRanges.map { text.lineRange(for: $0.rangeValue) }.map { range in
            // A caret at the very end of a line belongs to that line, not the next.
            NSRange(location: range.location, length: max(0, range.length - (text.substring(with: range).hasSuffix("\n") ? 1 : 0)))
        }
    }

    @MainActor private struct Palette {
        let body = NSFont.systemFont(ofSize: 14)
        let primary = NSColor(DSColor.primaryText)
        let secondary = NSColor(DSColor.secondaryText)
        let tertiary = NSColor(DSColor.tertiaryText)
        let accent = NSColor(DSColor.accentText)
        let rule = NSColor(DSColor.hairlineStrong)
        let codeBackground = NSColor(DSColor.hairline)
        var base: [NSAttributedString.Key: Any] { [.font: body, .foregroundColor: primary, .paragraphStyle: paragraph()] }
    }

    private static func paragraph(indent: CGFloat = 0, first: CGFloat? = nil, before: CGFloat = 0, after: CGFloat = 3) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        style.firstLineHeadIndent = first ?? indent
        style.headIndent = indent
        return style
    }

    private static func conceal(_ range: NSRange, _ storage: NSTextStorage) {
        guard range.length > 0 else { return }
        storage.addAttribute(concealKey, value: true, range: range)
    }

    /// Draws `character` in place of the text at `range`. The run gets a font that really has the glyph (the system font lacks
    /// the checkbox and box-drawing characters), so the glyph hook can look it up.
    private static func glyph(_ character: String, at range: NSRange, color: NSColor, size: CGFloat = 14, storage: NSTextStorage) {
        let base = NSFont.systemFont(ofSize: size)
        let font = CTFontCreateForString(base as CTFont, character as CFString, CFRange(location: 0, length: character.utf16.count)) as NSFont
        storage.addAttributes([glyphKey: character, .foregroundColor: color, .font: font], range: range)
    }

    private static func code(line: NSRange, storage: NSTextStorage, palette: Palette) {
        storage.addAttributes(
            [.font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular), .backgroundColor: palette.codeBackground,
             .paragraphStyle: paragraph(indent: 8, after: 0)], range: line)
    }

    // MARK: Blocks

    private static func block(line: NSRange, content: String, revealed: Bool, storage: NSTextStorage, palette: Palette) {
        func marker(_ length: Int) -> NSRange { NSRange(location: line.location, length: min(length, line.length)) }
        if let match = content.range(of: #"^#{1,6} "#, options: .regularExpression) {
            let marks = content.distance(from: content.startIndex, to: match.upperBound)
            let level = marks - 1
            let sizes: [CGFloat] = [26, 21, 17, 15, 14, 13]
            storage.addAttributes(
                [.font: NSFont.systemFont(ofSize: sizes[level - 1], weight: level <= 3 ? .bold : .semibold),
                 .paragraphStyle: paragraph(before: level <= 2 ? 10 : 6, after: 4)], range: line)
            if revealed { storage.addAttribute(.foregroundColor, value: palette.tertiary, range: marker(marks)) } else { conceal(marker(marks), storage) }
        } else if content.range(of: #"^\s*[-*_]{3,}\s*$"#, options: .regularExpression) != nil, !content.contains("**") || content.hasPrefix("---") {
            if revealed {
                storage.addAttribute(.foregroundColor, value: palette.tertiary, range: line)
            } else {
                // The dashes are drawn invisible and struck through: one continuous rule.
                storage.addAttributes([.foregroundColor: NSColor.clear, .strikethroughStyle: NSUnderlineStyle.thick.rawValue, .strikethroughColor: palette.rule], range: line)
                storage.addAttribute(.paragraphStyle, value: paragraph(before: 4, after: 4), range: line)
            }
        } else if content.hasPrefix(">") {
            let marks = content.hasPrefix("> ") ? 2 : 1
            storage.addAttributes([.foregroundColor: palette.secondary, .paragraphStyle: paragraph(indent: 14)], range: line)
            if revealed { storage.addAttribute(.foregroundColor, value: palette.tertiary, range: marker(marks)) } else {
                conceal(marker(marks), storage)
                storage.addAttribute(.font, value: NSFontManager.shared.convert(palette.body, toHaveTrait: .italicFontMask), range: line)
            }
        } else if let match = content.range(of: #"^(\s*)- \[([ xX])\] "#, options: .regularExpression) {
            let marks = content.distance(from: content.startIndex, to: match.upperBound)
            let lead = content.prefix { $0 == " " }.count
            let checked = content[content.index(content.startIndex, offsetBy: lead + 3)] != " "
            storage.addAttribute(.paragraphStyle, value: paragraph(indent: 0, first: 0), range: line)
            let box = NSRange(location: line.location + lead + 2, length: 3)
            storage.addAttributes([.link: URL(string: "earmark-check://\(line.location)") as Any, .cursor: NSCursor.pointingHand], range: box)
            if revealed {
                storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: checked ? palette.accent : palette.secondary], range: box)
            } else {
                conceal(NSRange(location: line.location, length: lead + 2), storage)      // "- "
                glyph(checked ? "\u{25CF}" : "\u{25CB}", at: NSRange(location: box.location, length: 1), color: checked ? palette.accent : palette.secondary, size: 16, storage: storage)
                conceal(NSRange(location: box.location + 1, length: 2), storage)           // " ]" / "x]"
            }
            if checked, line.length > marks {
                storage.addAttributes([.foregroundColor: palette.secondary, .strikethroughStyle: NSUnderlineStyle.single.rawValue],
                                      range: NSRange(location: line.location + marks, length: line.length - marks))
            }
        } else if let match = content.range(of: #"^(\s*)[-*+] "#, options: .regularExpression) {
            let marks = content.distance(from: content.startIndex, to: match.upperBound)
            let lead = marks - 2
            storage.addAttribute(.paragraphStyle, value: paragraph(indent: CGFloat(lead / 2) * 18 + 18, first: CGFloat(lead / 2) * 18 + 4), range: line)
            let dash = NSRange(location: line.location + lead, length: 1)
            if revealed { storage.addAttribute(.foregroundColor, value: palette.tertiary, range: dash) } else {
                glyph("\u{2022}", at: dash, color: palette.secondary, storage: storage)
            }
        } else if let match = content.range(of: #"^(\s*)\d+[.)] "#, options: .regularExpression) {
            let marks = content.distance(from: content.startIndex, to: match.upperBound)
            let lead = content.prefix { $0 == " " }.count
            storage.addAttribute(.paragraphStyle, value: paragraph(indent: CGFloat(lead / 2) * 18 + 22, first: CGFloat(lead / 2) * 18 + 2), range: line)
            storage.addAttributes([.foregroundColor: palette.secondary, .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .regular)],
                                  range: NSRange(location: line.location + lead, length: marks - lead))
        }
    }

    // MARK: Inline

    private static func inline(line: NSRange, content: String, revealed: Bool, storage: NSTextStorage, text: NSString, palette: Palette) {
        func each(_ pattern: String, _ body: (NSTextCheckingResult) -> Void) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            regex.enumerateMatches(in: text as String, range: line) { match, _, _ in if let match { body(match) } }
        }
        func edge(_ match: NSTextCheckingResult, _ open: Int, _ close: Int) {
            let leading = NSRange(location: match.range.location, length: open)
            let trailing = NSRange(location: match.range.location + match.range.length - close, length: close)
            for range in [leading, trailing] {
                if revealed { storage.addAttribute(.foregroundColor, value: palette.tertiary, range: range) } else { conceal(range, storage) }
            }
        }
        func restyle(_ range: NSRange, _ trait: NSFontTraitMask) {
            storage.enumerateAttribute(.font, in: range) { value, sub, _ in
                let font = (value as? NSFont) ?? palette.body
                storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: sub)
            }
        }
        each(#"\*\*\*(?=\S)(.+?)(?<=\S)\*\*\*"#) { match in
            restyle(match.range, .boldFontMask)
            restyle(match.range, .italicFontMask)
            edge(match, 3, 3)
        }
        each(#"(?<!\*)\*\*(?=[^\s\*])(.+?)(?<=[^\s\*])\*\*(?!\*)"#) { match in
            restyle(match.range, .boldFontMask)
            edge(match, 2, 2)
        }
        each(#"(?<![\*\w])\*(?=[^\s\*])([^\*\n]+?)(?<=[^\s\*])\*(?![\*\w])"#) { match in
            restyle(match.range, .italicFontMask)
            edge(match, 1, 1)
        }
        each(#"(?<![_\w])_(?=[^\s_])([^_\n]+?)(?<=[^\s_])_(?![_\w])"#) { match in
            restyle(match.range, .italicFontMask)
            edge(match, 1, 1)
        }
        each(#"~~(?=\S)(.+?)(?<=\S)~~"#) { match in
            storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: palette.secondary], range: match.range)
            edge(match, 2, 2)
        }
        each(#"`([^`\n]+)`"#) { match in
            let size = ((storage.attribute(.font, at: match.range.location, effectiveRange: nil) as? NSFont)?.pointSize ?? 14) - 1
            storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular), .backgroundColor: palette.codeBackground], range: match.range)
            edge(match, 1, 1)
        }
        each(#"\[([^\]\n]+)\]\((https?://[^\s)]+)\)"#) { match in
            let label = match.range(at: 1)
            let url = text.substring(with: match.range(at: 2))
            storage.addAttributes(
                [.foregroundColor: palette.accent, .underlineStyle: NSUnderlineStyle.single.rawValue, .link: URL(string: url) as Any, .cursor: NSCursor.pointingHand],
                range: label)
            let open = NSRange(location: match.range.location, length: 1)
            let tail = NSRange(location: label.location + label.length, length: match.range.location + match.range.length - (label.location + label.length))
            for range in [open, tail] {
                if revealed { storage.addAttribute(.foregroundColor, value: palette.tertiary, range: range) } else { conceal(range, storage) }
            }
        }
        each(#"\[(?:(\d{1,2}):)?(\d{1,2}):(\d{2})\]"#) { match in
            let parts = (0..<match.numberOfRanges).map { i -> Int? in
                let r = match.range(at: i)
                return r.location == NSNotFound ? nil : Int(text.substring(with: r))
            }
            let seconds = (parts[1] ?? 0) * 3600 + (parts[2] ?? 0) * 60 + (parts[3] ?? 0)
            storage.addAttributes([
                .foregroundColor: palette.accent, .link: URL(string: "earmark-time://\(seconds)") as Any, .cursor: NSCursor.pointingHand,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium),
            ], range: match.range)
        }
    }
}
