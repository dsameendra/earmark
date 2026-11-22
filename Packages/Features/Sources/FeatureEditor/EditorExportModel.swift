import AppCore
import AppKit
import Export
import Foundation
import Observation

/// Drives the editor's export sheet: format picker, options, presets, copy as text/Markdown and share.
@MainActor @Observable
public final class EditorExportModel {
    public var options: ExportOptions
    public private(set) var presets: [ExportPreset] = []
    public private(set) var isWorking = false
    public private(set) var errorMessage: String?
    public private(set) var statusMessage: String?
    public private(set) var previewText = ""
    public private(set) var previewIsPlainText = false
    @ObservationIgnored private var previewGeneration = 0

    @ObservationIgnored private let editor: TranscriptEditorModel
    @ObservationIgnored private let exporter: any Exporter
    @ObservationIgnored private let copyToPasteboard: @MainActor (String) -> Void

    public init(
        editor: TranscriptEditorModel, exporter: any Exporter = ExportService(),
        copyToPasteboard: @escaping @MainActor (String) -> Void = EditorExportModel.systemCopy
    ) {
        self.editor = editor
        self.exporter = exporter
        self.copyToPasteboard = copyToPasteboard
        options = ExportOptions(format: .txt, includeIgnored: false)
    }

    /// Formats offered in the picker.
    public static let formats: [ExportFormat] = ExportFormat.allCases

    public var isSubtitleFormat: Bool { [.srt, .vtt, .ass, .sbv, .ttml, .lrc].contains(options.format) }

    /// Translation tracks available in the loaded document, without touching its original text.
    public var translationLanguages: [LanguageCode] {
        Array(Set(editor.segments.flatMap { $0.translations.map(\.language) })).sorted()
    }

    /// Bounded, real export preview. Binary formats use a labelled text preview of the same first six segments.
    public func refreshPreview() async {
        previewGeneration += 1
        let generation = previewGeneration
        guard var document else {
            previewText = "Load a transcript to preview its export."
            return
        }
        document.segments = Array(document.segments.prefix(6))
        var previewOptions = options
        let isBinary = [.docx, .pdf].contains(options.format)
        if isBinary { previewOptions.format = .txt }
        do {
            let artifact = try await exporter.export(document, options: previewOptions)
            guard !Task.isCancelled, generation == previewGeneration else { return }
            previewText = String(data: artifact.data, encoding: .utf8).map { String($0.prefix(6000)) } ?? "Preview unavailable."
            previewIsPlainText = isBinary
        } catch {
            guard !Task.isCancelled, generation == previewGeneration else { return }
            previewText = "Preview unavailable: \(error.localizedDescription)"
        }
    }

    public static func title(for format: ExportFormat) -> String {
        switch format {
        case .txt: "Plain text (.txt)"
        case .markdown: "Markdown (.md)"
        case .docx: "Word (.docx)"
        case .html: "HTML (.html)"
        case .pdf: "PDF (.pdf)"
        case .json: "JSON (.json)"
        case .csv: "CSV (.csv)"
        case .srt: "SubRip (.srt)"
        case .vtt: "WebVTT (.vtt)"
        case .ass: "Advanced SubStation (.ass)"
        case .sbv: "YouTube (.sbv)"
        case .ttml: "TTML (.ttml)"
        case .lrc: "Lyrics (.lrc)"
        }
    }

    public static func systemCopy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    public func loadPresets() async {
        guard let repo = editor.presets else { return }
        presets = ((try? await repo.exportPresets()) ?? []).filter { $0.deletedAt == nil }
    }

    public func apply(_ preset: ExportPreset) { options = preset.options }

    public func savePreset(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let repo = editor.presets else { return }
        let preset = ExportPreset(name: trimmed, options: options)
        do {
            try await repo.save(preset)
            presets.append(preset)
        } catch { errorMessage = error.localizedDescription }
    }

    public func deletePreset(_ preset: ExportPreset) async {
        guard let repo = editor.presets else { return }
        do {
            try await repo.softDeletePreset(preset.id)
            presets.removeAll { $0.id == preset.id }
        } catch { errorMessage = error.localizedDescription }
    }

    private var document: TranscriptDocument? {
        editor.transcript.map { TranscriptDocument(transcript: $0, segments: editor.segments) }
    }

    /// Generates the file for the current options.
    public func makeArtifact() async throws -> ExportArtifact {
        guard let document else { throw AppError.exportFailed(reason: "The transcript is not loaded.") }
        isWorking = true
        defer { isWorking = false }
        do {
            return try await exporter.export(document, options: options)
        } catch {
            errorMessage = (error as? AppError).map(Self.describe) ?? error.localizedDescription
            throw error
        }
    }

    private static func describe(_ error: AppError) -> String {
        if case .exportFailed(let reason) = error { return reason }
        return "\(error)"
    }

    /// Exports and writes to `url`.
    public func export(to url: URL) async {
        errorMessage = nil
        do {
            let artifact = try await makeArtifact()
            try artifact.data.write(to: url, options: .atomic)
            statusMessage = "Exported \(url.lastPathComponent)"
        } catch {
            if errorMessage == nil { errorMessage = error.localizedDescription }
        }
    }

    /// Copies the transcript as plain text or Markdown with the current include/speaker/timestamp options.
    public func copy(markdown: Bool) async {
        errorMessage = nil
        var copyOptions = options
        copyOptions.format = markdown ? .markdown : .txt
        guard let document else { return }
        do {
            let artifact = try await exporter.export(document, options: copyOptions)
            guard let text = String(data: artifact.data, encoding: .utf8) else { throw AppError.exportFailed(reason: "Not text.") }
            copyToPasteboard(text)
            statusMessage = markdown ? "Copied as Markdown" : "Copied as text"
        } catch {
            errorMessage = (error as? AppError).map(Self.describe) ?? error.localizedDescription
        }
    }

    /// Writes the export to a temporary file for the system share sheet.
    public func prepareShareFile() async -> URL? {
        errorMessage = nil
        guard let artifact = try? await makeArtifact() else { return nil }
        let name = "EarmarkShare-\(UUID().uuidString)"
        let folder = FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appending(path: artifact.suggestedFilename)
            try artifact.data.write(to: url)
            return url
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}
