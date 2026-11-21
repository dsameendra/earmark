import AppCore
import CoreGraphics
import CoreText
import Foundation

/// A4 PDF typeset with CoreText (shaping-correct Sinhala) and paginated without clipping (EXP-AC-12).
///
/// Text is laid out by `CTFramesetter` page by page, so complex-script shaping (Sinhala vowel signs and conjuncts) is done by
/// CoreText and the font used (`Sinhala Sangam MN`) is embedded as a subset by Core Graphics' PDF context. This path is pure
/// Core Text/Core Graphics and runs off the main actor.
public struct PDFExporter: Exporter {
    public static let sinhalaFont = "Sinhala Sangam MN"
    public static let defaultLatinFont = "Helvetica Neue"

    public init() {}
    public var formats: Set<ExportFormat> { [.pdf] }

    private static let pageSize = CGSize(width: 595.28, height: 841.89)
    private static let margin: CGFloat = 56

    public func export(_ document: TranscriptDocument, options: ExportOptions) async throws -> ExportArtifact {
        try ExportPipeline.validate(options, supported: formats)
        let entries = ExportPipeline.entries(document, options: options)
        let paragraphs = ExportPipeline.paragraphs(entries, options: options)
        let text = attributedText(document, paragraphs, options)
        let data = try render(text, title: document.transcript.title)
        return makeArtifact(document, options: options, data: data)
    }

    // MARK: Attributed text

    private struct Style {
        var size: CGFloat = 11
        var bold = false
        var italic = false
        var gray: CGFloat = 0.1
        var indent: CGFloat = 0
        var spacingAfter: CGFloat = 8
    }

    private func attributedText(_ document: TranscriptDocument, _ paragraphs: [Paragraph], _ options: ExportOptions) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let latin = options.fontFamily ?? Self.defaultLatinFont

        func font(_ name: String, _ style: Style) -> CTFont {
            let base = CTFontCreateWithName(name as CFString, style.size, nil)
            var traits: CTFontSymbolicTraits = []
            if style.bold { traits.insert(.traitBold) }
            if style.italic { traits.insert(.traitItalic) }
            if traits.isEmpty { return base }
            return CTFontCreateCopyWithSymbolicTraits(base, style.size, nil, traits, traits) ?? base
        }

        func paragraphStyle(_ style: Style) -> CTParagraphStyle {
            var spacing = style.spacingAfter
            var indent = style.indent
            var lineMultiple: CGFloat = 1.25
            return withUnsafePointer(to: &spacing) { spacingPtr in
                withUnsafePointer(to: &indent) { indentPtr in
                    withUnsafePointer(to: &lineMultiple) { linePtr in
                        CTParagraphStyleCreate(
                            [
                                CTParagraphStyleSetting(
                                    spec: .paragraphSpacing, valueSize: MemoryLayout<CGFloat>.size, value: spacingPtr),
                                CTParagraphStyleSetting(spec: .headIndent, valueSize: MemoryLayout<CGFloat>.size, value: indentPtr),
                                CTParagraphStyleSetting(spec: .firstLineHeadIndent, valueSize: MemoryLayout<CGFloat>.size, value: indentPtr),
                                CTParagraphStyleSetting(spec: .lineHeightMultiple, valueSize: MemoryLayout<CGFloat>.size, value: linePtr),
                            ], 4)
                    }
                }
            }
        }

        func append(_ text: String, _ style: Style, paragraphStyle pStyle: CTParagraphStyle) {
            let color = CGColor(gray: style.gray, alpha: 1)
            for run in ScriptRuns.split(XML.stripIllegal(text)) {
                let attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): font(run.sinhala ? Self.sinhalaFont : latin, style),
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                    NSAttributedString.Key(kCTParagraphStyleAttributeName as String): pStyle,
                ]
                out.append(NSAttributedString(string: run.text, attributes: attributes))
            }
        }

        let titleStyle = Style(size: 20, bold: true, gray: 0, spacingAfter: 14)
        let titlePara = paragraphStyle(titleStyle)
        append(document.transcript.title + "\n", titleStyle, paragraphStyle: titlePara)

        let body = Style()
        let bodyPara = paragraphStyle(body)
        let meta = Style(size: 9, gray: 0.5)
        let bold = Style(bold: true, gray: 0)
        let translation = Style(italic: true, gray: 0.35, indent: 18)
        let translationPara = paragraphStyle(translation)
        for paragraph in paragraphs {
            if let stamp = paragraph.items[0].stamp { append("[\(Format.stamp(stamp))] ", meta, paragraphStyle: bodyPara) }
            if options.includeSpeakers, let name = paragraph.speaker?.name { append(name + ": ", bold, paragraphStyle: bodyPara) }
            for (index, item) in paragraph.items.enumerated() {
                if index > 0 {
                    append(" ", body, paragraphStyle: bodyPara)
                    if let stamp = item.stamp { append("[\(Format.stamp(stamp))] ", meta, paragraphStyle: bodyPara) }
                }
                append(item.entry.text, body, paragraphStyle: bodyPara)
            }
            append("\n", body, paragraphStyle: bodyPara)
            let translations = paragraph.items.compactMap(\.entry.translation)
            if !translations.isEmpty { append(translations.joined(separator: " ") + "\n", translation, paragraphStyle: translationPara) }
        }
        return out
    }

    // MARK: Rendering

    private func render(_ text: NSAttributedString, title: String) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw AppError.exportFailed(reason: "Could not create the PDF output.")
        }
        var mediaBox = CGRect(origin: .zero, size: Self.pageSize)
        let info: [CFString: Any] = [kCGPDFContextTitle: title, kCGPDFContextCreator: "Earmark"]
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary) else {
            throw AppError.exportFailed(reason: "Could not create the PDF context.")
        }
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let textRect = CGRect(
            x: Self.margin, y: Self.margin, width: Self.pageSize.width - 2 * Self.margin, height: Self.pageSize.height - 2 * Self.margin)
        let path = CGPath(rect: textRect, transform: nil)
        var location = 0
        var page = 1
        repeat {
            context.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
            CTFrameDraw(frame, context)
            drawFooter(page: page, in: context)
            context.endPDFPage()
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { break }
            location += visible.length
            page += 1
        } while location < text.length
        context.closePDF()
        return data as Data
    }

    private func drawFooter(page: Int, in context: CGContext) {
        let font = CTFontCreateWithName(Self.defaultLatinFont as CFString, 9, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.5, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(page), attributes: attributes))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.textPosition = CGPoint(x: (Self.pageSize.width - width) / 2, y: 28)
        CTLineDraw(line, context)
    }
}
