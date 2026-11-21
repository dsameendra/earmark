import AppCore
import FeatureSupport
import Foundation
import Observation

/// Live Captions: built-in and user presets with an editable draft (SET-AC-11).
@MainActor @Observable
public final class CaptionPresetsModel {
    public private(set) var presets: [CaptionPreset] = []
    public private(set) var activeID: PresetID?
    /// The preset being edited (a user preset or a fresh copy of a built-in). Drives the live preview.
    public var draft: CaptionPreset
    public var errorMessage: String?

    @ObservationIgnored private let repository: any PresetRepository
    @ObservationIgnored private let store: any SettingsStore

    public static let builtIns: [CaptionPreset] = [
        CaptionPreset(
            id: PresetID(UUID(uuidString: "C0A10000-0000-4000-8000-000000000001") ?? UUID()), name: "Subtle", fontSize: 22,
            textColorHex: "#FFFFFF", background: .liquidGlass, backgroundOpacity: 0.6, visibleLines: 2, isBuiltIn: true),
        CaptionPreset(
            id: PresetID(UUID(uuidString: "C0A10000-0000-4000-8000-000000000002") ?? UUID()), name: "Presentation", fontSize: 40,
            fontWeight: 0.6, textColorHex: "#FFFFFF", background: .solid, backgroundOpacity: 0.85, visibleLines: 3, maxWidth: 1100,
            isBuiltIn: true),
        CaptionPreset(
            id: PresetID(UUID(uuidString: "C0A10000-0000-4000-8000-000000000003") ?? UUID()), name: "High contrast", fontSize: 32,
            fontWeight: 0.7, textColorHex: "#FFFF00", background: .solid, backgroundOpacity: 1, textOutline: true,
            isBuiltIn: true),
    ]

    public init(repository: any PresetRepository, store: any SettingsStore) {
        self.repository = repository
        self.store = store
        draft = Self.builtIns[0]
    }

    public func load() async {
        let saved = ((try? await repository.captionPresets()) ?? []).filter { $0.deletedAt == nil && !$0.isBuiltIn }
        presets = Self.builtIns + saved
        if let raw = await store.value(for: SettingsKey.activeCaptionPreset, as: String.self), let uuid = UUID(uuidString: raw) {
            activeID = PresetID(uuid)
        } else {
            activeID = Self.builtIns[0].id
        }
        if let active = presets.first(where: { $0.id == activeID }) { draft = active }
    }

    public func select(_ id: PresetID) async {
        guard let preset = presets.first(where: { $0.id == id }) else { return }
        activeID = id
        draft = preset
        await store.set(id.rawValue.uuidString, for: SettingsKey.activeCaptionPreset)
    }

    public var isDraftEditable: Bool { !draft.isBuiltIn }

    /// Built-in presets are read-only; editing one first duplicates it into a user preset.
    public func duplicateDraft() async {
        var copy = draft
        copy.id = PresetID()
        copy.name = "\(draft.name) copy"
        copy.isBuiltIn = false
        await save(copy)
        await select(copy.id)
    }

    public func newPreset() async {
        let preset = CaptionPreset(name: "My preset")
        await save(preset)
        await select(preset.id)
    }

    /// Persists the draft (user presets only).
    public func saveDraft() async {
        guard !draft.isBuiltIn else { return }
        draft.visibleLines = min(max(draft.visibleLines, 1), 6)
        draft.fontSize = min(max(draft.fontSize, 10), 120)
        draft.backgroundOpacity = min(max(draft.backgroundOpacity, 0), 1)
        await save(draft)
    }

    private func save(_ preset: CaptionPreset) async {
        do {
            try await repository.save(preset)
            if let index = presets.firstIndex(where: { $0.id == preset.id }) { presets[index] = preset } else { presets.append(preset) }
        } catch {
            errorMessage = "Could not save the preset: \(error)"
        }
    }

    public func deleteDraft() async {
        guard !draft.isBuiltIn else { return }
        let id = draft.id
        do {
            try await repository.softDeletePreset(id)
            presets.removeAll { $0.id == id }
            await select(Self.builtIns[0].id)
        } catch {
            errorMessage = "Could not delete the preset: \(error)"
        }
    }
}

/// Export defaults and presets (SET-AC-15).
@MainActor @Observable
public final class ExportDefaultsModel {
    public let defaultOptions: Pref<ExportOptions>
    public private(set) var presets: [ExportPreset] = []
    public var errorMessage: String?

    @ObservationIgnored private let repository: any PresetRepository

    public init(repository: any PresetRepository, store: any SettingsStore) {
        self.repository = repository
        defaultOptions = Pref(SettingsKey.exportDefaultOptions, default: ExportOptions(format: .txt), store: store)
    }

    public func load() async {
        await defaultOptions.load()
        presets = ((try? await repository.exportPresets()) ?? []).filter { $0.deletedAt == nil }
    }

    public func mutateOptions(_ change: (inout ExportOptions) -> Void) {
        var options = defaultOptions.value
        change(&options)
        defaultOptions.update(options)
    }

    /// Saves the current defaults as a named preset.
    public func saveCurrentAsPreset(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Enter a preset name."
            return
        }
        let preset = ExportPreset(name: trimmed, options: defaultOptions.value)
        do {
            try await repository.save(preset)
            presets.append(preset)
            errorMessage = nil
        } catch {
            errorMessage = "Could not save the preset: \(error)"
        }
    }

    public func apply(_ preset: ExportPreset) async { await defaultOptions.set(preset.options) }

    public func delete(_ id: PresetID) async {
        do {
            try await repository.softDeletePreset(id)
            presets.removeAll { $0.id == id }
        } catch {
            errorMessage = "Could not delete the preset: \(error)"
        }
    }
}
