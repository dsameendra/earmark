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

/// A per-file deviation from the batch settings (FILE-AC-04). Every field is `nil` to inherit the batch value; a non-nil
/// ``Choice`` wraps the overriding value, which can itself be `nil` (model "Auto", translation "None", export "Off").
public struct FileOverride: Equatable, Sendable {
    /// Wraps an overriding value so an overriding `nil` differs from "inherit".
    public struct Choice<Value: Equatable & Sendable>: Equatable, Sendable {
        public var value: Value
        public init(_ value: Value) { self.value = value }
    }

    public var languageMode: LanguageMode?
    public var model: Choice<ModelID?>?
    public var diarize: Bool?
    public var translateTo: Choice<LanguageCode?>?
    public var autoExportPresetID: Choice<PresetID?>?

    public init(
        languageMode: LanguageMode? = nil, model: Choice<ModelID?>? = nil, diarize: Bool? = nil,
        translateTo: Choice<LanguageCode?>? = nil, autoExportPresetID: Choice<PresetID?>? = nil
    ) {
        self.languageMode = languageMode
        self.model = model
        self.diarize = diarize
        self.translateTo = translateTo
        self.autoExportPresetID = autoExportPresetID
    }

    /// `true` when nothing is overridden.
    public var isEmpty: Bool { self == FileOverride() }
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
    /// Expected speaker count when `diarize` is on (SCR-013); automatic by default.
    public var speakerCount: SpeakerCount = .auto
    /// "Dont ask again, use these settings": turns `files.askBeforeAdding` off when the batch is added.
    public var dontAskAgain = false
    public var translateTo: LanguageCode?
    public var autoExportPresetID: PresetID?
    public var skipDuplicates = true
    /// FILE-AC-16: copy the media into the library (library-owned) instead of referencing it with a bookmark.
    public var copyIntoLibrary = false
    /// Per-file overrides keyed by the dropped file or folder (FILE-AC-04).
    public private(set) var overrides: [URL: FileOverride] = [:]

    public private(set) var catalog: [ModelDescriptor] = []
    public private(set) var installed: Set<ModelID> = []
    public private(set) var presets: [ExportPreset] = []
    public private(set) var duplicates: [URL] = []
    public private(set) var download: BatchModelDownload = .idle
    /// Languages used recently for files, most recent first (offered at the top of the language menu).
    public private(set) var recentLanguages: [LanguageCode] = []
    /// The offline speaker model and its install/download state (SCR-013: the sheet offers it instead of silently skipping).
    public private(set) var speakerModel: ModelDescriptor?
    public private(set) var speakerModelInstalled = false
    public private(set) var speakerModelPreflight: ModelPreflightResult?
    public private(set) var speakerDownload: BatchModelDownload = .idle
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
            diarize = defaults.diarize
            speakerCount = SpeakerCount(diarization: defaults.diarization)
            recentLanguages = await FileJobSettings.recentLanguages(in: services.settings)
            installed = await services.models.installedModels()
            // Nothing saved yet: preselect the recommended model for this language and Mac (never starts a download).
            let saved = await services.settings.value(for: SettingsKey.filesLastModel, as: String.self)
            let preferred = await services.settings.value(for: SettingsKey.preferredModel, as: String.self)
            if !hasEditedConfiguration, saved == nil, preferred == nil {
                // Only a model with an explicit recommendation rule is preselected; otherwise it stays Automatic.
                modelID = ModelChoices.recommended(for: languageMode, tier: tier, catalog: catalog, allowFallback: false)?.id
            }
        }
        installed = await services.models.installedModels()
        speakerModel = catalog.first { $0.kind == .diarization && $0.capabilities.speakerLabels == .offline }
        speakerModelInstalled = speakerModel.map { installed.contains($0.id) } ?? false
        if let speakerModel, !speakerModelInstalled { speakerModelPreflight = await services.models.preflight(speakerModel.id) }
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

    /// ``languageOptions`` with the recently used languages first (SCR-013).
    public var recentFirstLanguageOptions: [LanguageCode] {
        let all = languageOptions
        let recent = recentLanguages.filter { all.contains($0) }
        return recent + all.filter { !recent.contains($0) }
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
    public var availableModels: [ModelDescriptor] { models(covering: languageMode) }

    func models(covering mode: LanguageMode) -> [ModelDescriptor] {
        let required: Set<LanguageCode>
        switch mode {
        case .single(let code): required = [code]
        case .multilingual(let codes): required = codes
        case .autoDetect: required = []
        }
        var models = table.models(coveringAll: required)
        if case .autoDetect = mode { models = models.filter { $0.languages.count > 1 } }
        return models.sorted { $0.displayName < $1.displayName }
    }

    public func isInstalled(_ id: ModelID) -> Bool { installed.contains(id) }

    /// This Mac's memory tier, for model compatibility.
    public var tier: HardwareTier { services.hardware.profile.tier }

    /// Every runnable ASR model with whether it suits the chosen language(s); unsupported rows are greyed out with a reason.
    public var modelRows: [ModelChoiceRow] {
        ModelChoices.rows(catalog: catalog, installed: installed, mode: languageMode, tier: tier)
    }

    /// The model the router would pick on its own for the chosen language(s): shown as "Automatic (Recommended: ...)".
    public var recommendedModel: ModelDescriptor? {
        ModelChoices.recommended(for: languageMode, tier: tier, catalog: catalog)
    }

    // MARK: Speakers (SCR-013)

    /// `true` when "Identify speakers" is on but the speaker model is missing, so the sheet offers to download it.
    public var needsSpeakerModel: Bool { diarize && speakerModel != nil && !speakerModelInstalled }

    public var speakerModelSizeText: String {
        ByteCountFormatter.string(fromByteCount: speakerModel?.sizeBytes ?? 0, countStyle: .file)
    }

    /// Downloads the speaker model with inline progress (the model manager runs its preflight and consent first).
    public func downloadSpeakerModel() async {
        guard let id = speakerModel?.id, !speakerModelInstalled else { return }
        if case .downloading = speakerDownload { return }
        speakerDownload = .downloading(model: id, fraction: 0, verifying: false)
        do {
            for try await event in services.models.ensureAvailable(id) {
                switch event {
                case .progress(let fraction, _, _): speakerDownload = .downloading(model: id, fraction: fraction, verifying: false)
                case .verifying: speakerDownload = .downloading(model: id, fraction: 1, verifying: true)
                case .completed: break
                }
            }
            speakerModelInstalled = true
            installed.insert(id)
            speakerDownload = .idle
        } catch {
            if case AppError.cancelled = error {
                speakerDownload = .idle
            } else {
                speakerDownload = .failed(model: id, reason: ModelDownloadErrorText.message(for: error, modelName: speakerModel?.displayName))
            }
        }
    }

    public var isDownloadingSpeakerModel: Bool {
        if case .downloading = speakerDownload { return true }
        return false
    }

    /// Stops any download this sheet started (Cancel, Esc, or switching to another model); a half-finished model is not wanted
    /// once the sheet is gone.
    public func cancelDownloads() async {
        if case .downloading(let id, _, _) = download {
            download = .idle
            if modelID == id { modelID = nil }
            await services.models.cancelDownload(id)
        }
        if case .downloading(let id, _, _) = speakerDownload {
            speakerDownload = .idle
            await services.models.cancelDownload(id)
        }
    }

    public func setKind(_ newKind: LanguageModeKind) {
        hasEditedConfiguration = true
        kind = newKind
        reconcileModel()
    }

    /// Marks the model/language configuration as edited by the user (it is then saved on submit).
    public func markEdited() { hasEditedConfiguration = true }

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

    /// Picks a model (`nil` = Auto). An undownloaded model is downloaded with inline progress; switching away from a model that is
    /// still downloading cancels that download.
    public func selectModel(_ id: ModelID?) async {
        hasEditedConfiguration = true
        if case .downloading(let previous, _, _) = download, previous != id {
            download = .idle
            await services.models.cancelDownload(previous)
        }
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
            if await services.models.installedModels().contains(id) { installed.insert(id) }
            guard modelID == id else { return }
            download = .idle
        } catch {
            guard modelID == id else { return }
            if case AppError.cancelled = error {
                download = .idle  // the user cancelled: back to Automatic rather than a model that is not there
                modelID = nil
            } else {
                download = .failed(model: id, reason: ModelDownloadErrorText.message(for: error, modelName: modelName(id)))
            }
        }
    }

    private func modelName(_ id: ModelID) -> String? { catalog.first { $0.id == id }?.displayName }

    // MARK: Submit

    public var isDownloading: Bool {
        if case .downloading = download { return true }
        return false
    }

    public var jobSettings: JobSettings {
        JobSettings(
            languageMode: languageMode, modelID: modelID, diarize: diarize, diarization: diarize ? speakerCount.diarization : [:],
            translateTo: translateTo, autoExportPresetID: autoExportPresetID, copyIntoLibrary: copyIntoLibrary)
    }

    // MARK: Per-file overrides (FILE-AC-04)

    public func override(for url: URL) -> FileOverride { overrides[url] ?? FileOverride() }

    public func hasOverride(_ url: URL) -> Bool { overrides[url] != nil }

    /// Edits one file's override. An override whose fields are all inherited is dropped, and a model override that no longer
    /// covers the file's language falls back to Auto (the same rule the batch applies).
    public func updateOverride(for url: URL, _ change: (inout FileOverride) -> Void) {
        var edited = override(for: url)
        change(&edited)
        if let mode = edited.languageMode, let choice = edited.model, let id = choice.value,
            !models(covering: mode).contains(where: { $0.id == id })
        {
            edited.model = .init(nil)
        }
        overrides[url] = edited.isEmpty ? nil : edited
    }

    public func clearOverride(for url: URL) { overrides[url] = nil }

    public func clearAllOverrides() { overrides = [:] }

    /// The language mode that applies to `url`.
    public func effectiveLanguageMode(for url: URL) -> LanguageMode { overrides[url]?.languageMode ?? languageMode }

    /// ASR models usable with the language mode that applies to `url`.
    public func availableModels(for url: URL) -> [ModelDescriptor] { models(covering: effectiveLanguageMode(for: url)) }

    /// The final settings of one file: the batch settings with its overrides on top. A batch-level model that cannot handle
    /// a file's overridden language is replaced by Auto so the file never fails routing.
    public func settings(for url: URL) -> JobSettings {
        var settings = jobSettings
        guard let item = overrides[url] else { return settings }
        if let mode = item.languageMode { settings.languageMode = mode }
        if let choice = item.model { settings.modelID = choice.value }
        if let id = settings.modelID, !models(covering: settings.languageMode).contains(where: { $0.id == id }) {
            settings.modelID = nil
        }
        if let value = item.diarize { settings.diarize = value }
        if let choice = item.translateTo { settings.translateTo = choice.value }
        if let choice = item.autoExportPresetID { settings.autoExportPresetID = choice.value }
        return settings
    }

    /// Inputs that will be enqueued (folders are expanded by the queue, which honours the media type filter).
    public var urlsToEnqueue: [URL] { skipDuplicates ? urls.filter { !duplicates.contains($0) } : urls }

    public var canSubmit: Bool { !isSubmitting && submitBlockReason == nil }

    /// Why "Transcribe" is unavailable, in words (`nil` when it can go ahead).
    public var submitBlockReason: String? {
        if isDownloading { return "Wait for the model download to finish, or choose Automatic." }
        if isDownloadingSpeakerModel { return "Wait for the speaker model download to finish." }
        if kind == .multilingual, multiLanguages.isEmpty { return "Choose at least one language." }
        if urlsToEnqueue.isEmpty { return "Everything here is already in the queue. Turn off \u{201C}Skip\u{201D} to add it again." }
        return nil
    }

    /// Saves what was chosen so the next add starts from it (SCR-013), and honours the "Dont ask again" checkbox.
    func rememberChoices() async {
        let choices = FileJobSettings.Choices(
            languageMode: languageMode, modelID: modelID, diarize: diarize, speakerCount: speakerCount)
        await FileJobSettings.save(choices, persistLanguageAndModel: hasEditedConfiguration, to: services.settings)
        if dontAskAgain { await services.settings.set(false, for: SettingsKey.askBeforeAdding) }
    }

    /// Enqueues the batch. Returns `true` on success.
    public func submit() async -> Bool {
        guard canSubmit else { return false }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let requests = urlsToEnqueue.map { FileJobRequest(url: $0, settings: settings(for: $0)) }
            _ = try await services.jobQueue.enqueue(requests: requests, recursive: true)
            errorMessage = nil
            await rememberChoices()
            return true
        } catch {
            errorMessage = String(describing: error)
            return false
        }
    }
}
