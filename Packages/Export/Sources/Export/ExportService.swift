import AppCore
import Foundation
import ZIPFoundation

/// The app-facing exporter: dispatches to the per-format exporters and adds per-speaker export.
public struct ExportService: Exporter {
    public init() {}

    public var formats: Set<ExportFormat> { Set(ExportFormat.allCases) }

    private func exporter(for format: ExportFormat) -> any Exporter {
        switch format {
        case .txt, .markdown: TextExporter()
        case .html: HTMLExporter()
        case .docx: DOCXExporter()
        case .pdf: PDFExporter()
        case .json: JSONExporter()
        case .csv: CSVExporter()
        case .srt, .vtt, .ass, .sbv, .ttml, .lrc: SubtitleExporter()
        }
    }

    /// Exports `document` in `options.format`.
    /// - Throws: `AppError.exportFailed` with a user-readable reason for invalid options.
    public func export(_ document: TranscriptDocument, options: ExportOptions) async throws -> ExportArtifact {
        try await exporter(for: options.format).export(document, options: options)
    }

    /// One artifact per speaker containing only that speaker's segments (EXP-AC-14). Segments without a speaker are
    /// exported as "Unknown speaker". Speakers with nothing to export are skipped.
    public func exportPerSpeaker(_ document: TranscriptDocument, options: ExportOptions) async throws -> [ExportArtifact] {
        try ExportPipeline.validate(options, supported: formats)
        let remaining = ExportPipeline.segments(document, options: options)
        var groups: [(name: String, id: SpeakerID?)] = document.transcript.speakers.map { ($0.name, $0.id) }
        let known = Set(document.transcript.speakers.map(\.id))
        if remaining.contains(where: { $0.speakerID == nil || !known.contains($0.speakerID!) }) { groups.append(("Unknown speaker", nil)) }
        var artifacts: [ExportArtifact] = []
        var taken = Set<String>()
        for group in groups {
            let mine = document.segments.filter { seg in
                group.id == nil ? (seg.speakerID == nil || !known.contains(seg.speakerID!)) : seg.speakerID == group.id
            }
            var sub = TranscriptDocument(transcript: document.transcript, segments: mine)
            sub.transcript.title = "\(document.transcript.title) - \(group.name)"
            if ExportPipeline.segments(sub, options: options).isEmpty { continue }
            var artifact = try await export(sub, options: options)
            artifact.suggestedFilename = BatchExporter.uniqueName(artifact.suggestedFilename, taken: &taken)
            artifacts.append(artifact)
        }
        return artifacts
    }
}

// MARK: - Batch

/// Where a batch export is written.
public enum BatchDestination: Sendable {
    /// One file per transcript inside this folder (created if needed).
    case folder(URL)
    /// A single `.zip` at this URL.
    case zip(URL)
}

/// Exports many transcripts with collision-free names (` (2)` suffix) to a folder or `.zip` (EXP-AC-15).
public struct BatchExporter: Sendable {
    private let exporter: any Exporter

    public init(exporter: any Exporter = ExportService()) { self.exporter = exporter }

    /// - Returns: The file names written, in input order.
    @discardableResult
    public func export(_ documents: [TranscriptDocument], options: ExportOptions, to destination: BatchDestination) async throws -> [String] {
        var artifacts: [ExportArtifact] = []
        for document in documents { artifacts.append(try await exporter.export(document, options: options)) }
        switch destination {
        case .folder(let folder):
            return try Self.write(artifacts, toFolder: folder)
        case .zip(let url):
            return try Self.write(artifacts, toZip: url)
        }
    }

    /// `name` made unique against `taken` (case-insensitive) by inserting ` (2)`, ` (3)`... before the extension.
    static func uniqueName(_ name: String, taken: inout Set<String>, existsOnDisk: (String) -> Bool = { _ in false }) -> String {
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var candidate = name
        var counter = 2
        while taken.contains(candidate.lowercased()) || existsOnDisk(candidate) {
            candidate = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            counter += 1
        }
        taken.insert(candidate.lowercased())
        return candidate
    }

    private static func write(_ artifacts: [ExportArtifact], toFolder folder: URL) throws -> [String] {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var taken = Set<String>()
            var names: [String] = []
            for artifact in artifacts {
                let name = uniqueName(artifact.suggestedFilename, taken: &taken) { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
                try artifact.data.write(to: folder.appendingPathComponent(name), options: .atomic)
                names.append(name)
            }
            return names
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.exportFailed(reason: "Could not write to the folder: \(error.localizedDescription)")
        }
    }

    private static func write(_ artifacts: [ExportArtifact], toZip url: URL) throws -> [String] {
        let fm = FileManager.default
        do {
            try? fm.removeItem(at: url)
            let archive = try Archive(url: url, accessMode: .create)
            var taken = Set<String>()
            var names: [String] = []
            for artifact in artifacts {
                let name = uniqueName(artifact.suggestedFilename, taken: &taken)
                let bytes = artifact.data
                try archive.addEntry(
                    with: name, type: .file, uncompressedSize: Int64(bytes.count), compressionMethod: .deflate
                ) { position, size in
                    bytes.subdata(in: Int(position)..<Int(position) + size)
                }
                names.append(name)
            }
            return names
        } catch {
            throw AppError.exportFailed(reason: "Could not write the .zip archive: \(error.localizedDescription)")
        }
    }
}

// MARK: - Presets

/// Built-in export presets and last-used preset persistence (EXP-AC-17).
public enum ExportPresets {
    /// Settings key under which the last used preset ID is stored.
    public static let lastUsedKey = "export.lastUsedPresetID"

    private static func id(_ suffix: Int) -> PresetID {
        PresetID(UUID(uuidString: "E0000000-0000-4000-8000-0000000000\(suffix < 10 ? "0" : "")\(suffix)")!)
    }

    /// Presets shipped with the app (stable IDs, never persisted unless the user duplicates them).
    public static let builtIn: [ExportPreset] = [
        ExportPreset(id: id(1), name: "Plain Text", options: ExportOptions(format: .txt)),
        ExportPreset(id: id(2), name: "Markdown Notes", options: ExportOptions(format: .markdown, paragraphGrouping: true)),
        ExportPreset(id: id(3), name: "Word Document", options: ExportOptions(format: .docx, paragraphGrouping: true)),
        ExportPreset(id: id(4), name: "PDF", options: ExportOptions(format: .pdf, paragraphGrouping: true)),
        ExportPreset(id: id(5), name: "Subtitles (SRT)", options: ExportOptions(format: .srt)),
        ExportPreset(id: id(6), name: "Captions (WebVTT)", options: ExportOptions(format: .vtt)),
        ExportPreset(id: id(7), name: "Data (JSON)", options: ExportOptions(format: .json, includeIgnored: true)),
        ExportPreset(id: id(8), name: "Spreadsheet (CSV)", options: ExportOptions(format: .csv)),
    ]

    /// The preset to preselect when the export sheet opens: the last used one if it still exists, else the first.
    public static func preselect(from presets: [ExportPreset], lastUsedID: PresetID?) -> ExportPreset? {
        let live = presets.filter { $0.deletedAt == nil }
        if let lastUsedID, let match = live.first(where: { $0.id == lastUsedID }) { return match }
        return live.first
    }

    /// Records `id` as the last used preset.
    public static func recordLastUsed(_ id: PresetID, in store: any SettingsStore) async {
        await store.set(id.rawValue.uuidString, for: lastUsedKey)
    }

    /// Resolves the preselected preset from built-ins plus the user's saved presets.
    public static func preselected(settings: any SettingsStore, repository: any PresetRepository) async -> ExportPreset? {
        let saved = (try? await repository.exportPresets()) ?? []
        let stored = await settings.value(for: lastUsedKey, as: String.self)
        let lastID = stored.flatMap { UUID(uuidString: $0) }.map { PresetID($0) }
        return preselect(from: saved + builtIn, lastUsedID: lastID)
    }
}

// MARK: - Watch folder

/// What happened to an auto-export attempt.
public enum AutoExportOutcome: Sendable, Equatable {
    case written(URL)
    case skipped(reason: String)
    case failed(reason: String)
}

/// Writes an export into the configured watch folder when a job completes (EXP-AC-16). Failures are logged and returned
/// as ``AutoExportOutcome/failed(reason:)``; this type never throws, so a failed export cannot fail the job.
public actor AutoExportWriter {
    private let folder: URL
    private let presets: any PresetRepository
    private let exporter: any Exporter
    private let log = AppLog.logger("export.auto")

    public init(folder: URL, presets: any PresetRepository, exporter: any Exporter = ExportService()) {
        self.folder = folder
        self.presets = presets
        self.exporter = exporter
    }

    /// Exports `document` using the preset with `presetID` (the job's `autoExportPresetID`).
    public func exportCompleted(_ document: TranscriptDocument, presetID: PresetID?) async -> AutoExportOutcome {
        guard let presetID else { return .skipped(reason: "No auto-export preset configured") }
        do {
            let saved = try await presets.exportPresets()
            guard let preset = (saved + ExportPresets.builtIn).first(where: { $0.id == presetID && $0.deletedAt == nil }) else {
                log.error("Auto-export preset \(presetID.description, privacy: .public) not found")
                return .failed(reason: "The auto-export preset no longer exists.")
            }
            let artifact = try await exporter.export(document, options: preset.options)
            let fm = FileManager.default
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var taken = Set<String>()
            let name = BatchExporter.uniqueName(artifact.suggestedFilename, taken: &taken) { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
            let url = folder.appendingPathComponent(name)
            try artifact.data.write(to: url, options: .atomic)
            return .written(url)
        } catch {
            log.error("Auto-export failed: \(String(describing: error), privacy: .public)")
            return .failed(reason: String(describing: error))
        }
    }
}
