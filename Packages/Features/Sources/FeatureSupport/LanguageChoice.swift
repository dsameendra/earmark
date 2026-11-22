import AppCore
import Foundation

/// A lossless language choice for capture controls. Options come from the app's ASR catalog,
/// and a stored multilingual choice remains distinct from automatic language detection.
public struct TranscriptionLanguageChoice: Hashable, Identifiable, Sendable {
    public let mode: LanguageMode
    public init(mode: LanguageMode) { self.mode = mode }

    public static let english = Self(mode: .single(.english))
    public static let sinhala = Self(mode: .single(.sinhala))
    public static let auto = Self(mode: .autoDetect)
    /// Original quick-choice conveniences. UI pickers use the catalog-backed options.
    public static let allCases: [Self] = [.auto, .english, .sinhala]

    public var id: String {
        switch mode {
        case .single(let code): "single:\(code.rawValue)"
        case .autoDetect: "auto"
        case .multilingual(let languages): "multilingual:" + languages.sorted().map(\.rawValue).joined(separator: ",")
        }
    }

    public var title: String {
        switch mode {
        case .single(let code): Self.name(code)
        case .autoDetect: "Auto-detect"
        case .multilingual(let languages): "Multilingual (\(languages.count))"
        }
    }

    public static func name(_ code: LanguageCode) -> String {
        Locale.current.localizedString(forLanguageCode: code.rawValue) ?? code.rawValue
    }

    /// Saves a quick capture choice without leaving an incompatible explicit engine pinned.
    /// Clearing the model first makes subsequent preference observers resolve a compatible automatic model.
    public func persist(to settings: any SettingsStore, catalog: [ModelDescriptor]) async {
        guard !Task.isCancelled else { return }
        if let preferred = await settings.value(for: SettingsKey.preferredModel, as: String.self), !preferred.isEmpty {
            let descriptor = catalog.first { $0.kind == .asr && $0.id.rawValue == preferred }
            let compatible: Bool
            if let descriptor {
                switch mode {
                case .single(let language):
                    compatible = descriptor.languages.contains(language) || descriptor.languages.contains(language.primary)
                case .multilingual(let languages):
                    compatible = languages.allSatisfy { descriptor.languages.contains($0) || descriptor.languages.contains($0.primary) }
                case .autoDetect: compatible = descriptor.runtime != .appleAsset && descriptor.languages.count > 1
                }
            } else {
                compatible = false
            }
            guard !Task.isCancelled else { return }
            if !compatible { await settings.set("", for: SettingsKey.preferredModel) }
        }
        guard !Task.isCancelled else { return }
        await settings.set(mode, for: SettingsKey.languageMode)
    }

    /// Offers supported ASR languages, Auto-detect and the exact currently selected mode.
    /// A stored choice remains when its model is removed, rather than silently changing to English.
    public static func options(catalog: [ModelDescriptor], including current: LanguageMode) -> [Self] {
        var languages = Set(catalog.filter { $0.kind == .asr }.flatMap(\.languages))
        if case .single(let code) = current { languages.insert(code) }
        var choices: [Self] = [.auto]
        if case .multilingual = current { choices.append(Self(mode: current)) }
        choices += languages.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
            .map { Self(mode: .single($0)) }
        return choices
    }
}
