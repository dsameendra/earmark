import AppCore
import AppKit
import Foundation
import PDFKit
import Vision

/// Text from attached files: PDF text through PDFKit, and on-device text recognition (Vision) for pages and images that
/// carry no text of their own (scans, picture-only slides).
public struct ExtractedPage: Sendable, Equatable {
    public var text: String
    /// True when the text came from text recognition.
    public var recognized: Bool
    public init(text: String, recognized: Bool) {
        self.text = text
        self.recognized = recognized
    }
}

public enum DocumentTextExtractor {
    /// A page with fewer visible characters than this is treated as having no text of its own.
    static let minimumTextLength = 12

    public static func pdfPageCount(at url: URL) -> Int { PDFDocument(url: url)?.pageCount ?? 0 }

    public static func pdfPages(at url: URL) async throws -> [ExtractedPage] {
        guard let document = PDFDocument(url: url) else { throw AppError.other("This PDF could not be opened.") }
        var pages: [ExtractedPage] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else {
                pages.append(ExtractedPage(text: "", recognized: false))
                continue
            }
            let own = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if own.count >= minimumTextLength {
                pages.append(ExtractedPage(text: own, recognized: false))
            } else if let image = render(page), let text = try? await recognize(image), !text.isEmpty {
                pages.append(ExtractedPage(text: text, recognized: true))
            } else {
                pages.append(ExtractedPage(text: own, recognized: false))
            }
        }
        return pages
    }

    public static func imagePage(at url: URL) async -> ExtractedPage {
        guard let image = NSImage(contentsOf: url), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let text = try? await recognize(cg)
        else { return ExtractedPage(text: "", recognized: true) }
        return ExtractedPage(text: text, recognized: true)
    }

    static func render(_ page: PDFPage) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = min(2.0, 2200 / max(box.width, box.height))
        let size = CGSize(width: box.width * scale, height: box.height * scale)
        return page.thumbnail(of: size, for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    static func recognize(_ image: CGImage) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        let observations = try await request.perform(on: image)
        return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
