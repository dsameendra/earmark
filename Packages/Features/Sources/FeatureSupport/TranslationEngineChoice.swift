import AppCore
import Foundation

/// Shared engine choices derived from executable translation catalog entries.
/// Preserve an unavailable saved choice so opening a screen never replaces it.
public struct TranslationEngineChoice: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let isUnavailable: Bool

    public static func choices(in catalog: [ModelDescriptor], selected: String) -> [Self] {
        var choices = [Self(id: "auto", title: "Auto", isUnavailable: false), Self(id: "apple", title: "Apple Translation", isUnavailable: false)]
        let groups = Dictionary(grouping: catalog.filter {
            $0.kind == .translation && $0.isRunnable && $0.capabilities.translation && $0.engine != nil
        }) { $0.engine!.rawValue }
        for engine in groups.keys.sorted() where engine != "apple.translation" {
            let models = groups[engine] ?? []
            let title = name(engine, fallback: models.first?.displayName ?? engine)
            let notice = models.contains(where: { $0.license.isNonCommercial }) ? " (non-commercial)" : ""
            choices.append(Self(id: engine, title: title + notice, isUnavailable: false))
        }
        if !selected.isEmpty, !choices.contains(where: { $0.id == selected }) {
            choices.append(Self(id: selected, title: name(selected, fallback: selected) + " (unavailable)", isUnavailable: true))
        }
        return choices
    }

    private static func name(_ engine: String, fallback: String) -> String {
        switch engine {
        case "nllb": "NLLB"
        case "madlad": "MADLAD-400"
        case "opus-mt": "OPUS language packs"
        default: fallback
        }
    }
}
