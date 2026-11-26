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

/// A Markdown text editor with live styling: headings, bold and italic, lists, checkboxes you can click, and `[12:52]`
/// timestamps that jump playback. The text is the Markdown itself, so what is saved is exactly what is typed.
struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    let commands: MarkdownEditorCommands
    let onSeek: (TimeInterval) -> Void
    var isEditable = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.textContainerInset = NSSize(width: 14, height: 12)
        view.isEditable = isEditable
        view.setAccessibilityIdentifier("notes.editor")
        view.setAccessibilityLabel("Notes")
        view.setAccessibilityRole(.textArea)
        view.linkTextAttributes = [:]
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
    final class Coordinator: NSObject, NSTextViewDelegate {
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

        private func toggleCheckbox(at index: Int, in view: NSTextView) {
            let text = view.string as NSString
            let line = text.lineRange(for: NSRange(location: min(index, max(0, text.length - 1)), length: 0))
            let content = text.substring(with: line)
            let replacement: String
            if let range = content.range(of: "- [ ] ") {
                replacement = content.replacingCharacters(in: range, with: "- [x] ")
            } else if let range = content.range(of: "- [x] ") {
                replacement = content.replacingCharacters(in: range, with: "- [ ] ")
            } else {
                return
            }
            guard view.shouldChangeText(in: line, replacementString: replacement) else { return }
            view.textStorage?.replaceCharacters(in: line, with: replacement)
            view.didChangeText()
        }
    }
}

/// Live Markdown styling. Attributes only: the characters are never changed, so undo and the saved text stay exact.
@MainActor
enum MarkdownStyler {
    static func apply(to view: NSTextView) {
        guard let storage = view.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        let text = storage.string as NSString
        let body = NSFont.systemFont(ofSize: 14)
        let primary = NSColor(DSColor.primaryText)
        let secondary = NSColor(DSColor.secondaryText)
        let accent = NSColor(DSColor.accentText)
        let base: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: primary, .paragraphStyle: paragraph(indent: 0)]
        storage.beginEditing()
        storage.setAttributes(base, range: full)
        text.enumerateSubstrings(in: full, options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            style(line: lineRange, text: text, storage: storage, body: body, primary: primary, secondary: secondary, accent: accent)
        }
        inline(storage: storage, text: text, full: full, body: body, secondary: secondary, accent: accent)
        storage.endEditing()
        view.typingAttributes = base
    }

    private static func paragraph(indent: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.paragraphSpacing = 2
        style.firstLineHeadIndent = 0
        style.headIndent = indent
        return style
    }

    private static func style(
        line: NSRange, text: NSString, storage: NSTextStorage, body: NSFont, primary: NSColor, secondary: NSColor, accent: NSColor
    ) {
        let content = text.substring(with: line)
        func heading(_ marks: Int, size: CGFloat) {
            storage.addAttributes([.font: NSFont.systemFont(ofSize: size, weight: .semibold), .paragraphStyle: paragraph(indent: 0)], range: line)
            storage.addAttribute(.foregroundColor, value: secondary, range: NSRange(location: line.location, length: min(marks + 1, line.length)))
        }
        if content.hasPrefix("### ") { heading(3, size: 15) } else if content.hasPrefix("## ") { heading(2, size: 17) } else if content.hasPrefix("# ") {
            heading(1, size: 20)
        } else if content.hasPrefix("- [ ] ") || content.hasPrefix("- [x] ") {
            let checked = content.hasPrefix("- [x] ")
            storage.addAttribute(.paragraphStyle, value: paragraph(indent: 22), range: line)
            let box = NSRange(location: line.location + 2, length: 3)
            storage.addAttributes([.link: URL(string: "earmark-check://\(line.location)") as Any, .foregroundColor: checked ? accent : secondary,
                                   .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .cursor: NSCursor.pointingHand], range: box)
            if checked, line.length > 6 {
                let rest = NSRange(location: line.location + 6, length: line.length - 6)
                storage.addAttributes([.foregroundColor: secondary, .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: rest)
            }
        } else if content.hasPrefix("- ") || content.hasPrefix("* ") {
            storage.addAttribute(.paragraphStyle, value: paragraph(indent: 16), range: line)
            storage.addAttribute(.foregroundColor, value: secondary, range: NSRange(location: line.location, length: 1))
        } else if let match = content.range(of: #"^\d+\. "#, options: .regularExpression) {
            storage.addAttribute(.paragraphStyle, value: paragraph(indent: 20), range: line)
            storage.addAttribute(.foregroundColor, value: secondary, range: NSRange(location: line.location, length: content.distance(from: content.startIndex, to: match.upperBound)))
        }
    }

    private static func inline(storage: NSTextStorage, text: NSString, full: NSRange, body: NSFont, secondary: NSColor, accent: NSColor) {
        func each(_ pattern: String, _ body: (NSTextCheckingResult) -> Void) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            regex.enumerateMatches(in: text as String, range: full) { match, _, _ in if let match { body(match) } }
        }
        each(#"\*\*(?=\S)(.+?)(?<=\S)\*\*"#) { match in
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: currentSize(storage, match.range), weight: .bold), range: match.range)
            for edge in [NSRange(location: match.range.location, length: 2), NSRange(location: match.range.location + match.range.length - 2, length: 2)] {
                storage.addAttribute(.foregroundColor, value: secondary, range: edge)
            }
        }
        each(#"(?<![\*\w])\*(?=[^\s\*])([^\*\n]+?)(?<=[^\s\*])\*(?![\*\w])"#) { match in
            let size = currentSize(storage, match.range)
            let italic = NSFontManager.shared.convert(NSFont.systemFont(ofSize: size), toHaveTrait: .italicFontMask)
            storage.addAttribute(.font, value: italic, range: match.range)
            for edge in [NSRange(location: match.range.location, length: 1), NSRange(location: match.range.location + match.range.length - 1, length: 1)] {
                storage.addAttribute(.foregroundColor, value: secondary, range: edge)
            }
        }
        each(#"\[(?:(\d{1,2}):)?(\d{1,2}):(\d{2})\]"#) { match in
            let parts = (0..<match.numberOfRanges).map { i -> Int? in
                let r = match.range(at: i)
                return r.location == NSNotFound ? nil : Int(text.substring(with: r))
            }
            let seconds = (parts[1] ?? 0) * 3600 + (parts[2] ?? 0) * 60 + (parts[3] ?? 0)
            storage.addAttributes([
                .foregroundColor: accent, .link: URL(string: "earmark-time://\(seconds)") as Any, .cursor: NSCursor.pointingHand,
            ], range: match.range)
        }
    }

    private static func currentSize(_ storage: NSTextStorage, _ range: NSRange) -> CGFloat {
        (storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)?.pointSize ?? 14
    }
}
