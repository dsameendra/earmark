import AppCore
import FeatureSupport
import Foundation
import Observation
import Processing

public struct ReplacementRuleFile: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var find: String
        public var replacement: String
        public var matchCase: Bool
        public var wholeWord: Bool
        public var isRegex: Bool
        public var isEnabled: Bool
    }
    public static let currentVersion = 1
    public var version: Int
    public var rules: [Entry]
}

/// Settings → Replacements: find→replace rules plus custom vocabulary (SET-AC-14, FR-AC-13).
@MainActor @Observable
public final class ReplacementsModel {
    public private(set) var rules: [ReplacementRule] = []
    public private(set) var vocabulary: [String] = []
    public var searchText = ""
    public var errorMessage: String?
    public let applyByDefault: Pref<Bool>

    @ObservationIgnored private let repository: any RuleRepository
    @ObservationIgnored private let store: any SettingsStore

    public init(repository: any RuleRepository, store: any SettingsStore) {
        self.repository = repository
        self.store = store
        applyByDefault = Pref(SettingsKey.applyReplacementsByDefault, default: true, store: store)
    }

    public func load() async {
        await applyByDefault.load()
        rules = ((try? await repository.replacementRules()) ?? []).filter { $0.deletedAt == nil }
        vocabulary = await store.value(for: SettingsKey.customVocabulary, as: [String].self) ?? []
    }

    public var visibleRules: [ReplacementRule] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return rules }
        return rules.filter { $0.find.localizedCaseInsensitiveContains(query) || $0.replacement.localizedCaseInsensitiveContains(query) }
    }

    /// Returns an error message when the rule cannot be saved.
    public static func validate(_ rule: ReplacementRule) -> String? {
        if rule.find.isEmpty { return "Enter text to find." }
        if rule.isRegex, (try? NSRegularExpression(pattern: rule.find)) == nil { return "Invalid regular expression." }
        return nil
    }

    @discardableResult
    public func save(_ rule: ReplacementRule) async -> Bool {
        if let message = Self.validate(rule) {
            errorMessage = message
            return false
        }
        do {
            try await repository.saveReplacementRule(rule)
            if let index = rules.firstIndex(where: { $0.id == rule.id }) { rules[index] = rule } else { rules.append(rule) }
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Could not save the rule: \(error)"
            return false
        }
    }

    /// Soft delete.
    public func remove(_ id: RuleID) async {
        guard var rule = rules.first(where: { $0.id == id }) else { return }
        rule.deletedAt = Date()
        do {
            try await repository.saveReplacementRule(rule)
            rules.removeAll { $0.id == id }
        } catch {
            errorMessage = "Could not remove the rule: \(error)"
        }
    }

    /// "Test rule" field: runs one rule over sample text (FR-AC-13).
    public static func test(_ rule: ReplacementRule, on text: String) -> String {
        var enabled = rule
        enabled.isEnabled = true
        return ReplacementProcessor(rules: [enabled]).apply(to: text)
    }

    /// Rules that could feed each other (replacement contains another rule's find text).
    public var loopWarnings: Set<RuleID> { Set(ReplacementProcessor.loopWarnings(for: rules)) }

    // MARK: Vocabulary

    public func addVocabulary(_ term: String) async {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !vocabulary.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        vocabulary.append(trimmed)
        await store.set(vocabulary, for: SettingsKey.customVocabulary)
    }

    public func removeVocabulary(_ term: String) async {
        vocabulary.removeAll { $0 == term }
        await store.set(vocabulary, for: SettingsKey.customVocabulary)
    }

    // MARK: Import / export

    public func exportJSON() throws -> Data {
        let file = ReplacementRuleFile(
            version: ReplacementRuleFile.currentVersion,
            rules: rules.map {
                .init(
                    find: $0.find, replacement: $0.replacement, matchCase: $0.matchCase, wholeWord: $0.wholeWord,
                    isRegex: $0.isRegex, isEnabled: $0.isEnabled)
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }

    @discardableResult
    public func importJSON(_ data: Data) async throws -> ImportSummary {
        guard let file = try? JSONDecoder().decode(ReplacementRuleFile.self, from: data),
            file.version == ReplacementRuleFile.currentVersion
        else {
            errorMessage = "That file is not a valid replacement list."
            throw IgnoreRuleError.malformedFile("replacement rules")
        }
        var summary = ImportSummary()
        for entry in file.rules {
            let rule = ReplacementRule(
                find: entry.find, replacement: entry.replacement, matchCase: entry.matchCase, wholeWord: entry.wholeWord,
                isRegex: entry.isRegex, isEnabled: entry.isEnabled)
            if Self.validate(rule) != nil {
                summary.invalid += 1
            } else if rules.contains(where: {
                $0.find == rule.find && $0.replacement == rule.replacement && $0.matchCase == rule.matchCase
                    && $0.wholeWord == rule.wholeWord && $0.isRegex == rule.isRegex
            }) {
                summary.skipped += 1
            } else if await save(rule) {
                summary.added += 1
            } else {
                summary.invalid += 1
            }
        }
        errorMessage = nil
        return summary
    }
}
