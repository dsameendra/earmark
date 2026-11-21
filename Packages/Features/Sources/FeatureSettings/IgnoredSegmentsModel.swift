import AppCore
import FeatureSupport
import Foundation
import Observation
import Processing

/// The shipped ignore lists (IGN default rules). Hallucination rules are stored disabled and governed by the global toggle.
public enum IgnoreRuleDefaults {
    public static let patterns: [String] = [
        "[BLANK_AUDIO]", "[ BLANK_AUDIO ]", "[Music]", "[music]", "[MUSIC PLAYING]", "[MUSIC]", "(music)", "[no audio]", "[ Silence ]",
        "[silence]", "[inaudible]", "[GASP]", "[ Pause ]", "( retirement bell rang )", "( silence )", "(crunching)", "(door slams)",
        "(silence)", "[Pause]", "[Silencio]", "(scissors snipping)", "(Applause.)", "(Pause)", "[APPLAUSE]", "[LAUGHTER]", "(laughs)",
        "[NOISE]", "*music*", "♪", "♪♪",
    ]
    public static let hallucinationPatterns: [String] = ["Thank you for watching.", "Subtitles by the Amara.org community"]

    /// Deterministic ids so "Restore defaults" can find and revive its own rules.
    static func id(_ index: Int, hallucination: Bool) -> RuleID {
        let group = hallucination ? "0002" : "0001"
        let tail = String(format: "%012d", index)
        return RuleID(UUID(uuidString: "E4A2\(group)-0000-4000-8000-\(tail)") ?? UUID())
    }

    public static func rules() -> [IgnoreRule] {
        patterns.enumerated().map { IgnoreRule(id: id($0.offset, hallucination: false), pattern: $0.element) }
            + hallucinationPatterns.enumerated().map {
                IgnoreRule(
                    id: id($0.offset, hallucination: true), pattern: $0.element, isEnabled: false, isHallucinationRule: true)
            }
    }
}

/// Versioned JSON schema for import/export (IGN-AC-10); export then import round-trips.
public struct IgnoreRuleFile: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var pattern: String
        public var match: RuleMatch
        public var scope: RuleScope
        public var isEnabled: Bool
        public var isHallucinationRule: Bool
        public init(pattern: String, match: RuleMatch, scope: RuleScope, isEnabled: Bool, isHallucinationRule: Bool) {
            self.pattern = pattern
            self.match = match
            self.scope = scope
            self.isEnabled = isEnabled
            self.isHallucinationRule = isHallucinationRule
        }
    }
    public static let currentVersion = 1
    public var version: Int
    public var rules: [Entry]
    public init(version: Int = currentVersion, rules: [Entry]) {
        self.version = version
        self.rules = rules
    }
}

public struct ImportSummary: Equatable, Sendable {
    public var added = 0
    public var skipped = 0
    public var invalid = 0
    public init(added: Int = 0, skipped: Int = 0, invalid: Int = 0) {
        self.added = added
        self.skipped = skipped
        self.invalid = invalid
    }
}

public enum IgnoreRuleError: Error, Equatable, Sendable {
    case duplicate
    case invalid(String)
    case malformedFile(String)
}

/// Settings → Ignored Segments (SET-AC-13, SET-AC-18, IGN-AC-01/09/10/11/13/14).
@MainActor @Observable
public final class IgnoredSegmentsModel {
    public private(set) var rules: [IgnoreRule] = []
    public var searchText = ""
    public var errorMessage: String?
    public private(set) var lastImport: ImportSummary?
    public let hallucinationFilter: Pref<Bool>
    public let lowConfidence: Pref<Double>
    public let noSpeech: Pref<Double>

    @ObservationIgnored private let repository: any RuleRepository
    @ObservationIgnored private let store: any SettingsStore
    @ObservationIgnored private var undoSnapshot: [IgnoreRule]?

    public init(repository: any RuleRepository, store: any SettingsStore) {
        self.repository = repository
        self.store = store
        hallucinationFilter = Pref(SettingsKey.hallucinationFilterEnabled, default: false, store: store)
        lowConfidence = Pref(SettingsKey.lowConfidenceThreshold, default: 0.5, store: store)
        noSpeech = Pref(SettingsKey.noSpeechThreshold, default: 0.6, store: store)
    }

    public var canUndoImport: Bool { undoSnapshot != nil }

    // MARK: Loading and seeding

    /// Seeds the default list on first launch (IGN-AC-01), then loads.
    public func load() async {
        await hallucinationFilter.load()
        await lowConfidence.load()
        await noSpeech.load()
        let seeded = await store.value(for: SettingsKey.ignoreRulesSeeded, as: Bool.self) ?? false
        if !seeded {
            let existing = (try? await repository.ignoreRules()) ?? []
            if existing.isEmpty { try? await repository.replaceAllIgnoreRules(IgnoreRuleDefaults.rules()) }
            await store.set(true, for: SettingsKey.ignoreRulesSeeded)
        }
        await reload()
    }

    private func reload() async {
        do {
            rules = try await repository.ignoreRules().filter { $0.deletedAt == nil }
        } catch {
            errorMessage = "Could not load rules: \(error)"
        }
    }

    // MARK: Views of the list

    /// Rules for one list, filtered by the search text (case-insensitive).
    public func visibleRules(hallucination: Bool) -> [IgnoreRule] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return rules.filter { rule in
            rule.isHallucinationRule == hallucination && (query.isEmpty || rule.pattern.localizedCaseInsensitiveContains(query))
        }
    }

    // MARK: CRUD

    /// Duplicates compare literally (after trimming): case variants such as `[Music]` / `[music]` ship as separate rules.
    static func normalized(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func isDuplicate(_ candidate: IgnoreRule, in list: [IgnoreRule]) -> Bool {
        list.contains {
            $0.id != candidate.id && $0.deletedAt == nil && $0.match == candidate.match && $0.scope == candidate.scope
                && Self.normalized($0.pattern) == Self.normalized(candidate.pattern)
        }
    }

    /// Adds a rule; rejects empty/invalid patterns (IGN-AC-03) and duplicates (IGN-AC-11).
    @discardableResult
    public func add(
        pattern: String, match: RuleMatch = .exact, scope: RuleScope = .wholeSegment, hallucination: Bool = false
    ) async -> Result<IgnoreRule, IgnoreRuleError> {
        let rule = IgnoreRule(
            pattern: pattern.trimmingCharacters(in: .whitespacesAndNewlines), match: match, scope: scope,
            isEnabled: !hallucination, isHallucinationRule: hallucination)
        errorMessage = nil
        do {
            try IgnoreFilter.validate(rule)
        } catch {
            errorMessage = match == .regex ? "Invalid regular expression." : "Enter a pattern."
            return .failure(.invalid(errorMessage ?? ""))
        }
        if isDuplicate(rule, in: rules) {
            errorMessage = "That rule already exists."
            return .failure(.duplicate)
        }
        do {
            try await repository.saveIgnoreRule(rule)
            rules.append(rule)
            return .success(rule)
        } catch {
            errorMessage = "Could not save the rule: \(error)"
            return .failure(.invalid("\(error)"))
        }
    }

    /// Soft delete (IGN-AC-13): the rule is kept with `deletedAt` set.
    public func remove(_ id: RuleID) async {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        var rule = rules[index]
        rule.deletedAt = Date()
        do {
            try await repository.saveIgnoreRule(rule)
            rules.remove(at: index)
        } catch {
            errorMessage = "Could not remove the rule: \(error)"
        }
    }

    public func setEnabled(_ id: RuleID, _ enabled: Bool) async {
        await mutate(id) { $0.isEnabled = enabled }
    }

    /// Edits match mode / scope, re-validating and re-checking for duplicates.
    public func update(_ id: RuleID, match: RuleMatch? = nil, scope: RuleScope? = nil) async {
        guard let existing = rules.first(where: { $0.id == id }) else { return }
        var candidate = existing
        if let match { candidate.match = match }
        if let scope { candidate.scope = scope }
        errorMessage = nil
        do { try IgnoreFilter.validate(candidate) } catch {
            errorMessage = "Invalid regular expression."
            return
        }
        if isDuplicate(candidate, in: rules) {
            errorMessage = "That rule already exists."
            return
        }
        await mutate(id) {
            $0.match = candidate.match
            $0.scope = candidate.scope
        }
    }

    private func mutate(_ id: RuleID, _ change: (inout IgnoreRule) -> Void) async {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        var rule = rules[index]
        change(&rule)
        do {
            try await repository.saveIgnoreRule(rule)
            rules[index] = rule
        } catch {
            errorMessage = "Could not save the rule: \(error)"
        }
    }

    // MARK: Defaults

    /// Restores the shipped rules (reviving removed ones, resetting edited ones) without touching user-added rules.
    public func restoreDefaults() async {
        let defaults = IgnoreRuleDefaults.rules()
        let defaultIDs = Set(defaults.map(\.id))
        let all = ((try? await repository.ignoreRules()) ?? []).filter { !defaultIDs.contains($0.id) }
        var merged = all
        for rule in defaults {
            var restored = rule
            if let current = rules.first(where: { $0.id == rule.id }), current.isHallucinationRule {
                restored.isEnabled = current.isEnabled
            }
            merged.append(restored)
        }
        await replace(with: merged)
    }

    /// Deletes user rules too ("Reset all").
    public func resetAll() async { await replace(with: IgnoreRuleDefaults.rules()) }

    private func replace(with newRules: [IgnoreRule]) async {
        do {
            try await repository.replaceAllIgnoreRules(newRules)
            await reload()
        } catch {
            errorMessage = "Could not restore defaults: \(error)"
        }
    }

    // MARK: Import / export

    /// Pretty, stable JSON of the active rules (IGN-AC-10).
    public func exportJSON() throws -> Data {
        let file = IgnoreRuleFile(
            version: IgnoreRuleFile.currentVersion,
            rules: rules.map {
                .init(
                    pattern: $0.pattern, match: $0.match, scope: $0.scope, isEnabled: $0.isEnabled,
                    isHallucinationRule: $0.isHallucinationRule)
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }

    /// Validates and merges a JSON file. Malformed input throws and leaves existing rules untouched (SET-AC-18).
    @discardableResult
    public func importJSON(_ data: Data) async throws -> ImportSummary {
        let file: IgnoreRuleFile
        do {
            file = try JSONDecoder().decode(IgnoreRuleFile.self, from: data)
        } catch {
            errorMessage = "That file is not a valid ignored-segments list."
            throw IgnoreRuleError.malformedFile("\(error)")
        }
        guard file.version == IgnoreRuleFile.currentVersion else {
            errorMessage = "Unsupported file version \(file.version)."
            throw IgnoreRuleError.malformedFile("version \(file.version)")
        }
        var summary = ImportSummary()
        var working = rules
        var toSave: [IgnoreRule] = []
        for entry in file.rules {
            let rule = IgnoreRule(
                pattern: entry.pattern.trimmingCharacters(in: .whitespacesAndNewlines), match: entry.match, scope: entry.scope,
                isEnabled: entry.isEnabled, isHallucinationRule: entry.isHallucinationRule)
            if (try? IgnoreFilter.validate(rule)) == nil {
                summary.invalid += 1
            } else if isDuplicate(rule, in: working) {
                summary.skipped += 1
            } else {
                working.append(rule)
                toSave.append(rule)
                summary.added += 1
            }
        }
        let snapshot = ((try? await repository.ignoreRules()) ?? rules)
        do {
            for rule in toSave { try await repository.saveIgnoreRule(rule) }
        } catch {
            try? await repository.replaceAllIgnoreRules(snapshot)
            await reload()
            errorMessage = "Import failed: \(error)"
            throw IgnoreRuleError.invalid("\(error)")
        }
        undoSnapshot = snapshot
        lastImport = summary
        errorMessage = nil
        await reload()
        return summary
    }

    /// Reverts the last import (IGN-AC-10).
    public func undoImport() async {
        guard let snapshot = undoSnapshot else { return }
        undoSnapshot = nil
        lastImport = nil
        await replace(with: snapshot)
    }
}
