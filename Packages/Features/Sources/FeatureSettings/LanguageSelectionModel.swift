import AppCore
import FeatureSupport
import Foundation
import Observation

public enum LanguageModeKind: String, CaseIterable, Identifiable, Sendable {
    case single, autoDetect, multilingual
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .single: "Single language"
        case .autoDetect: "Auto-detect"
        case .multilingual: "Multilingual set"
        }
    }
}

/// Whether a language can be used on this Mac (LANG-AC-10, LANG-AC-14).
public enum LanguageAvailability: Equatable, Sendable {
    case available
    /// A model covers it but is not downloaded yet; shown with size and licence before use.
    case needsDownload(ModelDescriptor)
    /// No supported engine: the reason is shown instead of failing silently.
    case unavailable(reason: String)

    public var isUnavailable: Bool {
        if case .unavailable = self { true } else { false }
    }
}

/// Linked language ↔ model pickers (ADR-008, SET-AC-06/07/08, LANG-AC-01..03).
/// Choosing languages filters the model list; choosing a model restricts the language list.
@MainActor @Observable
public final class LanguageSelectionModel {
    public private(set) var kind: LanguageModeKind = .single
    public private(set) var languages: Set<LanguageCode> = [.english]
    /// `nil` means "Auto (recommended)": the router picks the model.
    public private(set) var selectedModel: ModelID?
    public private(set) var table = LanguageCapabilityTable(models: [])
    /// Model whose download is in flight because the user picked it.
    public private(set) var downloadingModel: ModelID?
    /// A model choice waiting for the user to confirm download warnings.
    public private(set) var pendingChoice: (model: ModelID, warnings: [DownloadWarning])?
    public var errorMessage: String?
    /// A download started from a language row, waiting for the user to confirm its warnings (size, licence).
    public private(set) var pendingDownload: (model: ModelID, warnings: [DownloadWarning])?

    public let manager: ModelManagerModel
    @ObservationIgnored private let store: any SettingsStore

    public init(manager: ModelManagerModel, store: any SettingsStore) {
        self.manager = manager
        self.store = store
    }

    // MARK: Derived

    /// Languages offered by the language picker: all ASR languages, or only the chosen model's (ADR-008).
    public var availableLanguages: [LanguageCode] {
        let set = selectedModel.map { table.languages(forModel: $0) } ?? table.languages()
        return set.sorted { Self.displayName($0).localizedCompare(Self.displayName($1)) == .orderedAscending }
    }

    /// Models offered by the advanced model picker: only those covering all chosen languages (LANG-AC-02).
    public var availableModels: [ModelDescriptor] {
        table.models(coveringAll: (kind == .autoDetect || showAllModels) ? [] : languages)
    }

    /// Lists every ASR model regardless of the chosen languages, so a model can be picked first (ADR-008).
    public var showAllModels = false

    public var languageMode: LanguageMode {
        switch kind {
        case .single: .single(languages.sorted().first ?? .english)
        case .autoDetect: .autoDetect
        case .multilingual: .multilingual(languages)
        }
    }

    /// LANG-AC-14: a language with no installed or supported engine here is unavailable with a reason; one whose model is
    /// merely not downloaded offers the download with size and licence (LANG-AC-10).
    public func availability(for code: LanguageCode) -> LanguageAvailability {
        let covering = table.models(coveringAll: [code])
        guard !covering.isEmpty else {
            return .unavailable(reason: "No speech model in this build supports \(Self.displayName(code)).")
        }
        // System-managed (Apple) models are checked by their engine, which falls back to Whisper with a notice.
        if covering.contains(where: { $0.runtime == .appleAsset || manager.row($0.id)?.isInstalled == true }) { return .available }
        let supported = covering.filter { $0.minTier <= manager.tier }
        guard let best = supported.min(by: { ($0.isExperimental ? 1 : 0, $0.sizeBytes) < ($1.isExperimental ? 1 : 0, $1.sizeBytes) })
        else {
            let needed = covering.map(\.minTier).min() ?? .tier8
            return .unavailable(
                reason: "\(Self.displayName(code)) needs a Mac with more memory (\(needed.rawValue) or higher).")
        }
        return .needsDownload(best)
    }

    /// Starts downloading the model for `code` (asks for confirmation first when there are warnings).
    public func downloadModel(for code: LanguageCode) async {
        guard case .needsDownload(let descriptor) = availability(for: code) else { return }
        errorMessage = nil
        downloadingModel = descriptor.id
        defer { downloadingModel = nil }
        switch await manager.download(descriptor.id, confirmed: false) {
        case .completed, .cancelled: break
        case .needsConfirmation(let warnings): pendingDownload = (descriptor.id, warnings)
        case .failed(let reason): errorMessage = reason
        }
    }

    public func confirmPendingDownload() async {
        guard let pending = pendingDownload else { return }
        pendingDownload = nil
        downloadingModel = pending.model
        defer { downloadingModel = nil }
        if case .failed(let reason) = await manager.download(pending.model, confirmed: true) { errorMessage = reason }
    }

    public func dismissPendingDownload() { pendingDownload = nil }

    /// Sinhala is first-class but labelled experimental (SET-AC-08).
    public func isExperimental(_ language: LanguageCode) -> Bool { language.primary == .sinhala }

    public static func displayName(_ code: LanguageCode) -> String {
        Locale.current.localizedString(forLanguageCode: code.rawValue) ?? code.rawValue
    }

    // MARK: Loading

    public func load() async {
        if manager.rows.isEmpty { await manager.load() }
        table = LanguageCapabilityTable(models: manager.catalog)
        let stored = await store.value(for: SettingsKey.languageMode, as: LanguageMode.self) ?? .default
        apply(mode: stored)
        let preferred = await PreferredModel.explicitID(for: .file, settings: store)?.rawValue ?? ""
        selectedModel = preferred.isEmpty ? nil : ModelID(preferred)
    }

    private func apply(mode: LanguageMode) {
        switch mode {
        case .single(let code):
            kind = .single
            languages = [code]
        case .autoDetect:
            kind = .autoDetect
        case .multilingual(let set):
            kind = .multilingual
            languages = set.isEmpty ? [.english] : set
        }
    }

    // MARK: Language actions

    public func setKind(_ newKind: LanguageModeKind) async {
        kind = newKind
        if newKind == .single, languages.count > 1 { languages = [languages.sorted().first ?? .english] }
        if languages.isEmpty { languages = [.english] }
        await reconcileModelAndPersist()
    }

    /// Single mode: replaces the selection. Multilingual: toggles membership (never emptying the set).
    public func selectLanguage(_ code: LanguageCode) async {
        switch kind {
        case .single:
            languages = [code]
        case .multilingual:
            if languages.contains(code) {
                if languages.count > 1 { languages.remove(code) }
            } else {
                languages.insert(code)
            }
        case .autoDetect:
            return
        }
        await reconcileModelAndPersist()
    }

    /// A chosen model that no longer covers the languages falls back to Auto.
    private func reconcileModelAndPersist() async {
        if let model = selectedModel, kind != .autoDetect, !languages.isSubset(of: table.languages(forModel: model)) {
            selectedModel = nil
        }
        await persist()
    }

    // MARK: Model actions

    /// Chooses a model (`nil` = Auto). Restricts languages (LANG-AC-03); downloads inline when not installed (SET-AC-07).
    /// Returns `true` when the selection was applied.
    @discardableResult
    public func chooseModel(_ id: ModelID?, confirmed: Bool = false) async -> Bool {
        errorMessage = nil
        pendingChoice = nil
        guard let id else {
            selectedModel = nil
            await persist()
            return true
        }
        guard table.models.contains(where: { $0.id == id }) else { return false }
        if let row = manager.row(id), !row.isInstalled {
            downloadingModel = id
            defer { downloadingModel = nil }
            switch await manager.download(id, confirmed: confirmed) {
            case .completed: break
            case .needsConfirmation(let warnings):
                pendingChoice = (id, warnings)
                return false
            case .cancelled: return false
            case .failed(let reason):
                errorMessage = reason
                return false
            }
        }
        restrictLanguages(to: id)
        selectedModel = id
        await persist()
        return true
    }

    /// Continues a choice that was waiting for the user to confirm warnings.
    public func confirmPendingChoice() async {
        guard let pending = pendingChoice else { return }
        await chooseModel(pending.model, confirmed: true)
    }

    public func dismissPendingChoice() { pendingChoice = nil }

    /// Keeps the current languages if the model supports them all; otherwise resets to the model's first language
    /// (English when supported) (LANG-AC-03).
    private func restrictLanguages(to id: ModelID) {
        let supported = table.languages(forModel: id)
        guard kind != .autoDetect, !supported.isEmpty, !languages.isSubset(of: supported) else { return }
        let kept = languages.intersection(supported)
        if kind == .multilingual, !kept.isEmpty {
            languages = kept
        } else {
            languages = [supported.contains(.english) ? .english : (supported.sorted().first ?? .english)]
        }
    }

    private func persist() async {
        await store.set(languageMode, for: SettingsKey.languageMode)
        await PreferredModel.set(selectedModel, for: .file, settings: store)
    }
}
