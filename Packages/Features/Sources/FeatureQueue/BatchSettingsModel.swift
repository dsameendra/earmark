import AppCore
import FeatureSupport
import Foundation
import Observation

/// How the batch chooses its language(s) (FILE-AC-04).
public enum LanguageModeKind: String, Sendable, CaseIterable, Identifiable {
    case single, autoDetect, multilingual
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .single: "One language"
        case .autoDetect: "Detect automatically"
        case .multilingual: "Several languages"
        }
    }
}

/// Download state of the model picked in the batch sheet (ADR-008 / FILE-AC-05).
public enum BatchModelDownload: Sendable, Equatable {
    case idle
    case downloading(model: ModelID, fraction: Double, verifying: Bool)
    case failed(model: ModelID, reason: String)
}

/// Settings for one batch of files and folders. Language mode defaults to English; the model list is filtered by the chosen
/// languages through `LanguageCapabilityTable`; picking an undownloaded model downloads it inline via `ensureAvailable`.
@MainActor @Observable
public final class BatchSettingsModel {
    public let urls: [URL]
    public private(set) var kind: LanguageModeKind = .single
    public private(set) var singleLanguage: LanguageCode = .english
    public private(set) var multiLanguages: Set<LanguageCode> = [.english]
    /// `nil` is "Auto".
    public private(set) var modelID: ModelID?
    public var diarize = false
    public var translateTo: LanguageCode?
    public var autoExportPresetID: PresetID?
    public var skipDuplicates = true

    public private(set) var catalog: [ModelDescriptor] = []
    public private(set) var installed: Set<ModelID> = []
    public private(set) var presets: [ExportPreset] = []
    public private(set) var duplicates: [URL] = []
    public private(set) var download: BatchModelDownload = .idle
    public private(set) var isSubmitting = false
    public private(set) var errorMessage: String?

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private var defaultsLoaded = false
    @ObservationIgnored private var hasEditedConfiguration = false

    public init(urls: [URL], services: AppServices) {
        self.urls = urls
        self.services = services
    }

    /// Loads the model catalog, install state, export presets and queued duplicates.
    public func prepare() async {
        catalog = await services.models.catalog()
        if !defaultsLoaded {
            defaultsLoaded = true
            let defaults = await FileJobSettings.load(from: services.settings, catalog: catalog)
            if !hasEditedConfiguration {
                switch defaults.languageMode {
                case .single(let language):
                    kind = .single
                    singleLanguage = language
                    multiLanguages = [language]
                case .multilingual(let languages):
                    kind = .multilingual
                    multiLanguages = languages
                case .autoDetect: kind = .autoDetect
                }
                modelID = defaults.modelID
            }
        }
        installed = await services.models.installedModels()
        presets = (try? await services.presets?.exportPresets())?.filter { $0.deletedAt == nil } ?? []
        let queued = Set(await services.jobQueue.jobs().filter { $0.state != .completed && $0.state != .cancelled }.compactMap(\.input))
        duplicates = urls.filter { queued.contains($0) }
    }

    // MARK: Language / model linkage (ADR-008)

    public var table: LanguageCapabilityTable { LanguageCapabilityTable(models: catalog) }

    /// Catalog languages plus the current choice, so a saved language is never silently replaced.
    public var languageOptions: [LanguageCode] {
        let all = table.languages()
        return Set(all).union(multiLanguages).union([singleLanguage]).sorted()
    }

    /// Languages offered as translation targets.
    public var translationOptions: [LanguageCode] {
        let all = table.languages(kind: .translation)
        return (all.isEmpty ? [.english] : Array(all)).sorted()
    }

    public var languageMode: LanguageMode {
        switch kind {
        case .single: .single(singleLanguage)
        case .autoDetect: .autoDetect
        case .multilingual: .multilingual(multiLanguages)
        }
    }

    /// ASR models usable with the chosen language mode, sorted by name.
    public var availableModels: [ModelDescriptor] {
        let required: Set<LanguageCode>
        switch languageMode {
        case .single(let code): required = [code]
        case .multilingual(let codes): required = codes
        case .autoDetect: required = []
        }
        var models = table.models(coveringAll: required)
        if kind == .autoDetect { models = models.filter { $0.languages.count > 1 } }
        return models.sorted { $0.displayName < $1.displayName }
    }

    public func isInstalled(_ id: ModelID) -> Bool { installed.contains(id) }

    public func setKind(_ newKind: LanguageModeKind) {
        hasEditedConfiguration = true
        kind = newKind
        reconcileModel()
    }

    public func setSingleLanguage(_ code: LanguageCode) {
        hasEditedConfiguration = true
        singleLanguage = code
        reconcileModel()
    }

    public func toggleLanguage(_ code: LanguageCode) {
        hasEditedConfiguration = true
        if multiLanguages.contains(code) { multiLanguages.remove(code) } else { multiLanguages.insert(code) }
        reconcileModel()
    }

    /// Resets the model to Auto when it no longer covers the chosen languages.
    private func reconcileModel() {
        if let id = modelID, !availableModels.contains(where: { $0.id == id }) {
            modelID = nil
            download = .idle
        }
    }

    /// Picks a model (`nil` = Auto). An undownloaded model is downloaded with inline progress.
    public func selectModel(_ id: ModelID?) async {
        hasEditedConfiguration = true
        modelID = id
        download = .idle
        guard let id, !installed.contains(id) else { return }
        download = .downloading(model: id, fraction: 0, verifying: false)
        do {
            for try await event in services.models.ensureAvailable(id) {
                guard modelID == id else { return }  // selection changed while downloading
                switch event {
                case .progress(let fraction, _, _): download = .downloading(model: id, fraction: fraction, verifying: false)
                case .verifying: download = .downloading(model: id, fraction: 1, verifying: true)
                case .completed: break
                }
            }
            guard modelID == id else { return }
            installed.insert(id)
            download = .idle
        } catch {
            guard modelID == id else { return }
            download = .failed(model: id, reason: String(describing: error))
        }
    }

    // MARK: Submit

    public var isDownloading: Bool {
        if case .downloading = download { return true }
        return false
    }

    public var jobSettings: JobSettings {
        JobSettings(
            languageMode: languageMode, modelID: modelID, diarize: diarize, translateTo: translateTo,
            autoExportPresetID: autoExportPresetID)
    }

    /// Inputs that will be enqueued (folders are expanded by the queue, which honours the media type filter).
    public var urlsToEnqueue: [URL] { skipDuplicates ? urls.filter { !duplicates.contains($0) } : urls }

    public var canSubmit: Bool {
        !isDownloading && !isSubmitting && !urlsToEnqueue.isEmpty && (kind != .multilingual || !multiLanguages.isEmpty)
    }

    /// Enqueues the batch. Returns `true` on success.
    public func submit() async -> Bool {
        guard canSubmit else { return false }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            _ = try await services.jobQueue.enqueue(files: urlsToEnqueue, settings: jobSettings, recursive: true)
            errorMessage = nil
            return true
        } catch {
            errorMessage = String(describing: error)
            return false
        }
    }
}
