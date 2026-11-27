import AppCore
import FeatureSupport
import Foundation
import Observation

/// Slides and files attached to one transcript.
@MainActor @Observable
public final class FilesModel {
    public private(set) var attachments: [Attachment] = []
    public private(set) var isImporting = false
    public private(set) var summarizing: Set<AttachmentID> = []
    public private(set) var errorMessage: String?

    public let transcriptID: TranscriptID
    @ObservationIgnored private let services: AppServices

    public init(transcriptID: TranscriptID, services: AppServices) {
        self.transcriptID = transcriptID
        self.services = services
    }

    public var canAdd: Bool { services.workspace.files != nil }
    public var slideDecks: [Attachment] { attachments.filter { $0.role == .slides } }

    public func load() async {
        attachments = (try? await services.workspace.attachments.attachments(for: transcriptID)) ?? []
    }

    /// Copies the chosen PDFs and images in and reads their text. Presentation files get a plain explanation.
    public func add(_ urls: [URL], role: Attachment.Role) async {
        guard let files = services.workspace.files, !urls.isEmpty else { return }
        isImporting = true
        errorMessage = nil
        do {
            _ = try await files.attach(urls, role: role, to: transcriptID)
        } catch let error as AppError {
            errorMessage = Self.describe(error)
        } catch {
            errorMessage = String(describing: error)
        }
        isImporting = false
        await load()
        services.workspace.events.send(.attachmentsChanged(transcriptID))
    }

    public func remove(_ attachment: Attachment) async {
        try? await services.workspace.files?.remove(attachment)
        await load()
        services.workspace.events.send(.attachmentsChanged(transcriptID))
    }

    public func setUsedInContext(_ attachment: Attachment, _ value: Bool) async {
        var changed = attachment
        changed.usedInContext = value
        try? await services.workspace.attachments.save(changed)
        await load()
    }

    public func setRole(_ attachment: Attachment, _ role: Attachment.Role) async {
        var changed = attachment
        changed.role = role
        try? await services.workspace.attachments.save(changed)
        await load()
        services.workspace.events.send(.attachmentsChanged(transcriptID))
    }

    public func summarize(_ attachment: Attachment) async {
        guard let intelligence = services.workspace.intelligence, !summarizing.contains(attachment.id) else { return }
        summarizing.insert(attachment.id)
        errorMessage = nil
        defer { summarizing.remove(attachment.id) }
        do {
            for try await event in intelligence.summarize(attachment: attachment) {
                if case .finished(let markdown) = event {
                    var changed = attachment
                    changed.summary = markdown
                    changed.summarizedAt = Date()
                    try await services.workspace.attachments.save(changed)
                }
            }
        } catch {
            errorMessage = NotesModel.describe(error)
        }
        await load()
    }

    public func location(of attachment: Attachment) async -> URL? { await services.workspace.files?.location(of: attachment) }
    public func dismissError() { errorMessage = nil }

    static func describe(_ error: AppError) -> String {
        if case .other(let message) = error { return message }
        return String(describing: error)
    }
}
