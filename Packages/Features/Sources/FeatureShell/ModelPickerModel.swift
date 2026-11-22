import AppCore
import FeatureSupport
import Foundation
import Observation

/// A download the user is being asked to confirm (size, licence, hardware) before it starts.
public struct PendingModelDownload: Equatable, Sendable {
    public var preflight: ModelPreflightResult
    public var text: ModelConsentText
    /// `true` when the model failed before: the download restarts cleanly.
    public var isRetry: Bool
}

/// The sidebar's model picker: one list of speech models per use case (file transcription, live captions, dictation), greyed
/// by `ModelCompatibility` for the current language, with download (preflight + confirmation + progress) and persistence.
@MainActor @Observable
public final class ModelPickerModel {
    public private(set) var useCase: UseCase = .file
    public private(set) var entries: [ModelPickerEntry] = []
    /// The explicit choice for the current use case; `nil` is "Automatic".
    public private(set) var selected: ModelID?
    public private(set) var recommendations: [ModelRecommendation] = []
    public private(set) var downloads: [ModelID: Double] = [:]
    public private(set) var pending: PendingModelDownload?
    public var errorMessage: String?
    public private(set) var languageMode: LanguageMode = .default

    @ObservationIgnored private let services: AppServices

    public init(services: AppServices) { self.services = services }

    public var isAutomaticSelected: Bool { selected == nil }

    /// Entries for one group, in display order.
    public func entries(in group: ModelPickerGroup) -> [ModelPickerEntry] { entries.filter { $0.group == group } }

    /// "Language: English · File transcription" — what the greying is based on.
    public var contextSummary: String {
        let language: String
        switch languageMode {
        case .single(let code): language = ModelCapabilitySummary.languageName(code)
        case .multilingual(let codes): language = "\(codes.count) languages"
        case .autoDetect: language = "Auto-detect"
        }
        return "Language: \(language)"
    }

    public static func title(for useCase: UseCase) -> String {
        switch useCase {
        case .file: "Files"
        case .live: "Live"
        case .dictation: "Dictation"
        }
    }

    public func setUseCase(_ newValue: UseCase) async {
        useCase = newValue
        errorMessage = nil
        pending = nil
        await reload()
    }

    public func reload() async {
        let catalog = await services.models.catalog()
        let tier = services.hardware.profile.tier
        languageMode = await services.settings.value(for: SettingsKey.languageMode, as: LanguageMode.self) ?? .default
        selected = await PreferredModel.explicitID(for: useCase, settings: services.settings)
        var states: [ModelID: ModelState] = [:]
        for model in catalog { states[model.id] = await services.models.state(of: model.id) }
        recommendations = ModelRecommendations.compute(catalog: catalog, tier: tier)
        entries = ModelPicker.entries(
            catalog: catalog, states: states, tier: tier, useCase: useCase, mode: languageMode, selected: selected)
    }

    /// Applies one model's new state without re-reading everything (download progress arrives many times a second). A
    /// transition that changes grouping (installed, failed) re-reads the list.
    public func apply(_ state: ModelState, for id: ModelID) async {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        if case .downloading = state {
            entries[index].state = state
        } else {
            await reload()
        }
    }

    /// The recommendation text for a row's "why" line, when it is recommended for the current use case.
    public func recommendationWhy(for id: ModelID) -> String? {
        recommendations.first { $0.model == id && $0.useCase == useCase }?.why
    }

    // MARK: Selection

    /// Chooses a model (`nil` is Automatic). An undownloaded model first needs the user's confirmation.
    public func select(_ id: ModelID?) async {
        errorMessage = nil
        guard let id else {
            await PreferredModel.set(nil, for: useCase, settings: services.settings)
            await reload()
            return
        }
        guard let entry = entries.first(where: { $0.id == id }), !entry.isDisabled else { return }
        switch entry.state {
        case .installed:
            await persist(id)
        case .downloading, .paused:
            return  // already on its way; progress shows in the row
        case .notInstalled, .failed:
            await requestDownload(entry)
        }
    }

    private func requestDownload(_ entry: ModelPickerEntry) async {
        let preflight = await services.models.preflight(entry.id)
        if let blocking = preflight.issues.first(where: \.isBlocking) {
            errorMessage = ModelConsentText.insufficientDisk(preflight) ?? blocking.message
            return
        }
        var isRetry = false
        if case .failed = entry.state { isRetry = true }
        pending = PendingModelDownload(preflight: preflight, text: ModelConsentText.make(preflight), isRetry: isRetry)
    }

    public func cancelPending() { pending = nil }

    /// Starts the confirmed download, shows progress, and selects the model once it is installed.
    public func confirmPending() async {
        guard let pending else { return }
        self.pending = nil
        let id = pending.preflight.model
        // The user just saw the licence and size here, so the manager's consent hook must not ask a second time.
        await services.models.recordConsent(for: id)
        downloads[id] = 0
        do {
            let stream = pending.isRetry ? services.models.retryDownload(id) : services.models.ensureAvailable(id)
            for try await event in stream {
                switch event {
                case .progress(let fraction, _, _): downloads[id] = fraction
                case .verifying: downloads[id] = 1
                case .completed: break
                }
            }
        } catch {
            downloads[id] = nil
            if case AppError.cancelled = error {
                await reload()
                return
            }
            errorMessage = ModelDownloadErrorText.message(for: error, modelName: pending.preflight.displayName)
            await reload()
            return
        }
        downloads[id] = nil
        if await services.models.state(of: id) == .notInstalled {
            await reload()  // cancelled or paused mid-way
            return
        }
        await persist(id)
    }

    public func cancelDownload(_ id: ModelID) async {
        await services.models.cancelDownload(id)
        downloads[id] = nil
        await reload()
    }

    private func persist(_ id: ModelID) async {
        await PreferredModel.set(id, for: useCase, settings: services.settings)
        await reload()
    }
}
