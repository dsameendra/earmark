import AppCore
import Foundation

// SCR-011 wave 2: pure presentation logic shared by the sidebar model picker, Settings > Models and the consent dialog.
// No I/O and no SwiftUI, so it is unit tested and the views stay thin.

// MARK: - Capability chips

/// One capability chip on a model row. `spoken` is the VoiceOver label (it also explains negatives).
public struct ModelCapabilityChip: Hashable, Identifiable, Sendable {
    public enum Tone: Sendable, Hashable { case neutral, positive, info, warning }
    public var id: String
    public var text: String
    public var symbol: String?
    public var tone: Tone
    public var spoken: String
    public init(id: String, text: String, symbol: String? = nil, tone: Tone = .neutral, spoken: String? = nil) {
        self.id = id
        self.text = text
        self.symbol = symbol
        self.tone = tone
        self.spoken = spoken ?? text
    }
}

public enum ModelCapabilitySummary {
    public static func languageName(_ code: LanguageCode) -> String {
        Locale.current.localizedString(forLanguageCode: code.rawValue) ?? code.rawValue
    }

    /// Distinct primary languages, sorted by display name.
    public static func languageNames(_ model: ModelDescriptor) -> [String] {
        Set(model.languages.map(\.primary)).map(languageName).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// "English", "English, German, French" or "99 languages".
    public static func languageSummary(_ model: ModelDescriptor) -> String {
        let names = languageNames(model)
        switch names.count {
        case 0: return "No languages"
        case 1...3: return names.joined(separator: ", ")
        default: return "\(names.count) languages"
        }
    }

    public static func speedText(_ tier: SpeedTier) -> String {
        switch tier {
        case .fast: "Fast"
        case .balanced: "Balanced speed"
        case .slow: "Slower"
        }
    }

    public static func memoryText(_ tier: MemoryTier) -> String {
        switch tier {
        case .light: "Low memory"
        case .moderate: "Medium memory"
        case .heavy: "High memory"
        }
    }

    public static func licenseChip(_ license: LicenseInfo) -> ModelCapabilityChip {
        if license.isNonCommercial {
            return ModelCapabilityChip(
                id: "license", text: "\(license.spdx) · non-commercial", symbol: "exclamationmark.triangle", tone: .warning,
                spoken: "Licence \(license.spdx), non-commercial use only")
        }
        if license.needsAcknowledgement {
            return ModelCapabilityChip(
                id: "license", text: "\(license.spdx) · share-alike", tone: .info, spoken: "Licence \(license.spdx), share-alike terms")
        }
        return ModelCapabilityChip(id: "license", text: license.spdx, spoken: "Licence \(license.spdx)")
    }

    /// What `model` supports, in reading order. Only features the model has are chips; the absence of a chip means "no".
    public static func chips(for model: ModelDescriptor) -> [ModelCapabilityChip] {
        let c = model.capabilities
        var chips: [ModelCapabilityChip] = []
        if model.kind == .asr || model.kind == .translation {
            let count = Set(model.languages.map(\.primary)).count
            chips.append(
                ModelCapabilityChip(
                    id: "languages", text: languageSummary(model), symbol: "globe",
                    spoken: "\(count) \(count == 1 ? "language" : "languages"): \(languageNames(model).joined(separator: ", "))"))
        }
        if model.kind == .asr {
            if c.live {
                let text: String
                switch c.streaming {
                case .native: text = "Native streaming"
                case .buffered: text = "Buffered captions"
                case nil: text = "Live captions"
                }
                chips.append(ModelCapabilityChip(id: "live", text: text, symbol: "waveform", tone: .positive))
            } else if c.file {
                chips.append(
                    ModelCapabilityChip(
                        id: "fileOnly", text: "Files only", symbol: "doc", spoken: "Files only, no live streaming"))
            }
            if c.wordTimestamps { chips.append(ModelCapabilityChip(id: "words", text: "Word timestamps", symbol: "clock", tone: .positive)) }
            if c.autoDetectLanguage {
                chips.append(ModelCapabilityChip(id: "detect", text: "Detects language", symbol: "sparkle.magnifyingglass", tone: .positive))
            }
        }
        switch c.speakerLabels {
        case .none: break
        case .offline: chips.append(ModelCapabilityChip(id: "speakers", text: "Speaker labels", symbol: "person.2", tone: .positive))
        case .streaming:
            chips.append(ModelCapabilityChip(id: "speakers", text: "Live speaker labels", symbol: "person.2", tone: .positive))
        }
        if c.translation { chips.append(ModelCapabilityChip(id: "translation", text: "Translation", symbol: "character.bubble", tone: .positive)) }
        if let speed = c.speed { chips.append(ModelCapabilityChip(id: "speed", text: speedText(speed), symbol: "speedometer")) }
        if let memory = c.memory { chips.append(ModelCapabilityChip(id: "memory", text: memoryText(memory), symbol: "memorychip")) }
        chips.append(
            ModelCapabilityChip(
                id: "size", text: ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .file), symbol: "internaldrive",
                spoken: "Download size \(ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .file))"))
        chips.append(licenseChip(model.license))
        if model.isExperimental {
            chips.append(ModelCapabilityChip(id: "experimental", text: "Experimental", symbol: "flask", tone: .warning))
        }
        if model.minTier > .tier8 {
            chips.append(
                ModelCapabilityChip(
                    id: "tier", text: "Best on \(tierText(model.minTier))+", symbol: "desktopcomputer", tone: .info,
                    spoken: "Recommended for \(tierText(model.minTier)) Macs or more"))
        }
        return chips
    }

    public static func tierText(_ tier: HardwareTier) -> String {
        switch tier {
        case .tier8: "8 GB"
        case .tier16: "16 GB"
        case .tier32Plus: "32 GB"
        }
    }
}

// MARK: - Recommendations ("Recommended for this Mac")

public struct ModelRecommendation: Hashable, Sendable {
    public var model: ModelID
    public var useCase: UseCase
    /// Languages the recommendation is specific to; empty means "any language".
    public var languages: [LanguageCode]
    /// One line explaining why.
    public var why: String

    public static func useCaseTitle(_ useCase: UseCase) -> String {
        switch useCase {
        case .file: "file transcription"
        case .live: "live captions"
        case .dictation: "dictation"
        }
    }

    /// "Recommended for live captions" (optionally "in English").
    public var badgeText: String {
        let base = "Recommended for \(Self.useCaseTitle(useCase))"
        guard !languages.isEmpty, languages.count <= 2 else { return base }
        return base + " in " + languages.map(ModelCapabilitySummary.languageName).sorted().joined(separator: " and ")
    }
}

public enum ModelRecommendations {
    /// The recommended ASR model per use case on this Mac, through the one ``ModelRecommender`` rule. A model recommended only
    /// for particular languages (Apple Speech for live English, Qwen for Sinhala) carries those languages.
    public static func compute(
        catalog: [ModelDescriptor], tier: HardwareTier, availableEngines: Set<EngineID>? = nil
    ) -> [ModelRecommendation] {
        let asr = catalog.filter { $0.kind == .asr && $0.isRunnable }
        let languages = Set(asr.flatMap(\.languages).map(\.primary)).sorted()
        var result: [ModelRecommendation] = []
        for useCase in UseCase.allCases {
            let base = ModelRecommender.recommendedModel(
                for: tier, useCase: useCase, language: nil, in: catalog, availableEngines: availableEngines, allowFallback: true)
            var byModel: [ModelID: Set<LanguageCode>] = [:]
            if let base { byModel[base.id] = [] }
            for language in languages {
                guard
                    let model = ModelRecommender.recommendedModel(
                        for: tier, useCase: useCase, language: language, in: catalog, availableEngines: availableEngines,
                        allowFallback: true),
                    model.id != base?.id
                else { continue }
                byModel[model.id, default: []].insert(language)
            }
            for (id, langs) in byModel.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                guard let model = catalog.first(where: { $0.id == id }) else { continue }
                let sorted = langs.sorted()
                result.append(
                    ModelRecommendation(
                        model: id, useCase: useCase, languages: sorted, why: why(model, useCase: useCase, tier: tier, languages: sorted)))
            }
        }
        return result
    }

    static func why(_ model: ModelDescriptor, useCase: UseCase, tier: HardwareTier, languages: [LanguageCode]) -> String {
        if model.runtime == .appleAsset { return "Built into macOS: nothing to download, fast and private." }
        if model.isExperimental, !languages.isEmpty {
            let names = languages.map(ModelCapabilitySummary.languageName).joined(separator: ", ")
            return "The best option for \(names), the only one that supports it."
        }
        switch useCase {
        case .live, .dictation:
            return "Quick enough to keep up with speech on \(ModelCapabilitySummary.tierText(tier)) of memory."
        case .file:
            switch tier {
            case .tier8: return "The most accurate model that runs comfortably on an 8 GB Mac."
            case .tier16: return "The most accurate model that suits a 16 GB Mac."
            case .tier32Plus: return "The most accurate model, with plenty of memory to spare on this Mac."
            }
        }
    }
}

// MARK: - Picker entries (sidebar model picker)

public enum ModelPickerGroup: Int, Sendable, CaseIterable {
    case recommended, installed, available, unavailable
    public var title: String {
        switch self {
        case .recommended: "Recommended"
        case .installed: "Installed"
        case .available: "Available to download"
        case .unavailable: "Not available for this task"
        }
    }
}

public struct ModelPickerEntry: Identifiable, Equatable, Sendable {
    public var descriptor: ModelDescriptor
    public var state: ModelState
    public var availability: ModelAvailability
    public var isSelected: Bool
    public var isRecommended: Bool
    public var group: ModelPickerGroup

    public var id: ModelID { descriptor.id }
    public var isDisabled: Bool { !availability.isOK }
    public var isInstalled: Bool { if case .installed = state { true } else { false } }
    /// The reason(s) a row is greyed out, in one line (`nil` when usable).
    public var disabledReason: String? {
        availability.isOK ? nil : availability.reasons.map(\.message).joined(separator: " · ")
    }
    public var sizeText: String { ByteCountFormatter.string(fromByteCount: descriptor.sizeBytes, countStyle: .file) }
    /// Downloaded / not downloaded / progress, as words.
    public var stateText: String {
        switch state {
        case .installed: descriptor.runtime == .appleAsset ? "Built in" : "Downloaded"
        case .notInstalled: descriptor.runtime == .appleAsset ? "Managed by macOS" : "Not downloaded"
        case .downloading(let f): "Downloading \(Int((f * 100).rounded()))%"
        case .paused(let f): "Paused at \(Int((f * 100).rounded()))%"
        case .failed(let reason): "Download failed: \(reason)"
        }
    }
    public var accessibilityLabel: String {
        var parts = [descriptor.displayName, sizeText, stateText]
        if isRecommended { parts.append("Recommended") }
        if isSelected { parts.append("Selected") }
        if let disabledReason { parts.append("Unavailable: \(disabledReason)") }
        return parts.joined(separator: ", ")
    }
}

public enum ModelPicker {
    /// What the current screen needs, from the saved language mode and the use case.
    public static func requirement(for useCase: UseCase, mode: LanguageMode) -> ModelRequirement {
        switch mode {
        case .single(let language): ModelRequirement(useCase: useCase, languages: [language])
        case .multilingual(let languages): ModelRequirement(useCase: useCase, languages: languages)
        case .autoDetect: ModelRequirement(useCase: useCase, needsAutoDetect: true)
        }
    }

    public static func entries(
        catalog: [ModelDescriptor], states: [ModelID: ModelState], tier: HardwareTier, useCase: UseCase, mode: LanguageMode,
        selected: ModelID?, availableEngines: Set<EngineID>? = nil
    ) -> [ModelPickerEntry] {
        let requirement = requirement(for: useCase, mode: mode)
        let language: LanguageCode? = if case .single(let l) = mode { l } else { nil }
        let recommended = ModelRecommender.recommendedModel(
            for: tier, useCase: useCase, language: language, in: catalog, availableEngines: availableEngines)
        let built = catalog.filter { $0.kind == .asr }.map { model -> ModelPickerEntry in
            let state = states[model.id] ?? .notInstalled
            let availability = ModelCompatibility.evaluate(model, for: requirement, tier: tier, availableEngines: availableEngines)
            let isRecommended = availability.isOK && model.id == recommended?.id
            let installed = if case .installed = state { true } else { false }
            let group: ModelPickerGroup =
                !availability.isOK ? .unavailable : isRecommended ? .recommended : installed ? .installed : .available
            return ModelPickerEntry(
                descriptor: model, state: state, availability: availability, isSelected: model.id == selected,
                isRecommended: isRecommended, group: group)
        }
        return built.sorted {
            ($0.group.rawValue, $0.descriptor.displayName.lowercased()) < ($1.group.rawValue, $1.descriptor.displayName.lowercased())
        }
    }
}

// MARK: - Download text (consent dialog and errors)

public struct ModelConsentText: Equatable, Sendable {
    public var title: String
    public var message: String
    public var confirmTitle: String

    /// The licence/size confirmation shown when a download's preflight `requiresConsent`.
    public static func make(_ preflight: ModelPreflightResult) -> ModelConsentText {
        let size = ByteCountFormatter.string(fromByteCount: preflight.downloadBytes, countStyle: .file)
        var lines = ["Download size: \(size)."]
        for issue in preflight.issues where issue.requiresConsent {
            lines.append(issue.message)
            if case .licenseNotice(_, let attribution?) = issue { lines.append(attribution) }
        }
        if let free = preflight.freeDiskBytes {
            lines.append("Free disk space: \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)).")
        }
        return ModelConsentText(
            title: "Download \(preflight.displayName)?", message: lines.joined(separator: "\n\n"), confirmTitle: "Download")
    }

    /// Words for a refusal because the disk is too full (`nil` when the preflight has no such issue).
    public static func insufficientDisk(_ preflight: ModelPreflightResult) -> String? {
        for case .insufficientDisk(let needed, let available) in preflight.issues {
            return "There is not enough free disk space to download \(preflight.displayName). It needs about "
                + "\(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) free and only "
                + "\(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) is available. Free up space and try again."
        }
        return nil
    }
}

public enum ModelDownloadErrorText {
    /// A sentence for any download failure (including the manager's insufficient-disk refusal).
    public static func message(for error: any Error, modelName: String? = nil) -> String {
        let subject = modelName.map { "Could not download \($0)" } ?? "Download failed"
        if let app = error as? AppError {
            switch app {
            case .cancelled: return "The download was cancelled."
            case .checksumMismatch: return "The download was corrupted (checksum mismatch) and was removed. Try again."
            case .modelDownloadFailed(_, let reason): return reason.isEmpty ? "\(subject)." : reason
            case .persistence(let reason), .other(let reason): return reason
            default: return "\(subject): \(app)"
            }
        }
        return "\(subject): \(error.localizedDescription)"
    }
}

// MARK: - Consent hook (installed on the model manager by the app)

/// Shows the licence/size confirmation. The app's implementation is an alert; tests use a scripted one.
public protocol ModelConsentPresenting: Sendable {
    @MainActor func present(_ text: ModelConsentText) async -> Bool
}

/// The ``ModelDownloadConsenting`` hook: every download whose preflight needs consent (non-commercial or share-alike licence,
/// hardware below the model's tier) is confirmed through `presenter`, whichever screen or background job started it.
public struct PromptingModelConsent: ModelDownloadConsenting {
    private let presenter: any ModelConsentPresenting
    public init(presenter: any ModelConsentPresenting) { self.presenter = presenter }

    public func confirmDownload(_ preflight: ModelPreflightResult) async -> Bool {
        await presenter.present(ModelConsentText.make(preflight))
    }
}
