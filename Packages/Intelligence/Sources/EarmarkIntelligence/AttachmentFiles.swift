import AppCore
import Foundation

/// Copies attached PDFs and images into the library (`Attachments/<transcript>/<attachment>/`) and stores each page's text.
public struct AttachmentFiles: AttachmentFileManaging {
    private let root: @Sendable () async -> URL
    private let repository: any AttachmentRepository

    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff"]

    /// - Parameter root: the library's `Attachments` folder (created when needed).
    public init(root: @escaping @Sendable () async -> URL, repository: any AttachmentRepository) {
        self.root = root
        self.repository = repository
    }

    public func attach(_ urls: [URL], role: Attachment.Role, to transcript: TranscriptID) async throws -> [Attachment] {
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        let images = urls.filter { Self.imageExtensions.contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let others = urls.filter { !pdfs.contains($0) && !images.contains($0) }
        if let first = others.first {
            let name = first.pathExtension.lowercased()
            if ["ppt", "pptx", "key", "odp"].contains(name) {
                throw AppError.other("\(first.lastPathComponent) is a presentation file. Export it as a PDF first (Keynote or PowerPoint: File, Export to PDF), then add the PDF.")
            }
            throw AppError.other("\(first.lastPathComponent) cannot be added. Use a PDF or images (PNG, JPEG, HEIC).")
        }
        let base = await root()
        var made: [Attachment] = []
        for pdf in pdfs {
            made.append(try await addPDF(pdf, role: role, transcript: transcript, base: base))
        }
        if !images.isEmpty {
            made.append(try await addImages(images, role: role, transcript: transcript, base: base))
        }
        return made
    }

    public func location(of attachment: Attachment) async -> URL {
        await root().appendingPathComponent(attachment.relativePath)
    }

    public func remove(_ attachment: Attachment) async throws {
        try await repository.softDelete(attachment.id)
    }

    // MARK: Adding

    private func addPDF(_ url: URL, role: Attachment.Role, transcript: TranscriptID, base: URL) async throws -> Attachment {
        let id = AttachmentID()
        let relative = "\(transcript.rawValue.uuidString)/\(id.rawValue.uuidString)/\(url.lastPathComponent)"
        let destination = base.appendingPathComponent(relative)
        try copy(url, to: destination)
        let pages: [ExtractedPage]
        do { pages = try await DocumentTextExtractor.pdfPages(at: destination) } catch {
            try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
            throw error
        }
        let attachment = Attachment(
            id: id, transcriptID: transcript, role: role, kind: .pdf, title: url.deletingPathExtension().lastPathComponent,
            relativePath: relative, pageCount: pages.count, recognizedPageCount: pages.filter(\.recognized).count)
        try await repository.save(attachment)
        try await repository.replacePages(pages.enumerated().map { AttachmentPage(attachmentID: id, index: $0.offset, text: $0.element.text) }, for: id)
        return attachment
    }

    private func addImages(_ urls: [URL], role: Attachment.Role, transcript: TranscriptID, base: URL) async throws -> Attachment {
        let id = AttachmentID()
        let relative = "\(transcript.rawValue.uuidString)/\(id.rawValue.uuidString)"
        let folder = base.appendingPathComponent(relative, isDirectory: true)
        var pages: [ExtractedPage] = []
        for (index, url) in urls.enumerated() {
            let name = String(format: "%04d.%@", index + 1, url.pathExtension.lowercased())
            let destination = folder.appendingPathComponent(name)
            try copy(url, to: destination)
            pages.append(await DocumentTextExtractor.imagePage(at: destination))
        }
        let title = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Images (\(urls.count))"
        let attachment = Attachment(
            id: id, transcriptID: transcript, role: role, kind: .images, title: title, relativePath: relative, pageCount: pages.count,
            recognizedPageCount: pages.filter { !$0.text.isEmpty }.count)
        try await repository.save(attachment)
        try await repository.replacePages(pages.enumerated().map { AttachmentPage(attachmentID: id, index: $0.offset, text: $0.element.text) }, for: id)
        return attachment
    }

    private func copy(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.copyItem(at: source, to: destination)
    }
}
