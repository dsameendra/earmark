import AppCore
import AppCoreTesting
import FeatureSettings
import FeatureSupport
import Foundation
import Processing
import Testing

private func descriptor(
    _ id: String, _ languages: Set<LanguageCode>, nonCommercial: Bool = false, minTier: HardwareTier = .tier8
) -> ModelDescriptor {
    ModelDescriptor(
        id: ModelID(id), displayName: id, kind: .asr, runtime: .coreML, languages: languages, sizeBytes: 1_000_000,
        license: LicenseInfo(spdx: nonCommercial ? "CC-BY-NC-4.0" : "MIT", isNonCommercial: nonCommercial), minTier: minTier)
}

@MainActor private func makeModels(
    installed: Set<ModelID> = [], catalog: [ModelDescriptor]? = nil, store: InMemorySettingsStore = InMemorySettingsStore()
) async -> (ModelManagerModel, LanguageSelectionModel, MockModelManager, InMemorySettingsStore) {
    let descriptors =
        catalog ?? [
            descriptor("A", ["en", "de"]), descriptor("B", ["si"]), descriptor("C", ["en", "de", "si"], nonCommercial: true),
        ]
    let mock = MockModelManager(descriptors: descriptors, installed: installed)
    let manager = ModelManagerModel(manager: mock, hardware: PlaceholderHardware(), store: store, freeDiskBytes: { Int64.max })
    let languages = LanguageSelectionModel(manager: manager, store: store)
    await languages.load()
    return (manager, languages, mock, store)
}

@Suite @MainActor struct ModelDownloadTests {
    @Test func downloadFlowInstallsAndClearsProgress() async {  // SET-AC-04, ENG-AC-03
        let (manager, _, _, _) = await makeModels()
        #expect(manager.row("A")?.state == .notInstalled)
        let outcome = await manager.download("A")
        #expect(outcome == .completed)
        #expect(manager.row("A")?.isInstalled == true)
        #expect(manager.row("A")?.progress == nil)
    }

    @Test func installedModelCompletesImmediately() async {
        let (manager, _, _, _) = await makeModels(installed: ["A"])
        #expect(await manager.download("A") == .completed)
    }

    @Test func nonCommercialModelNeedsConfirmationBeforeDownload() async {  // SET-AC-03 / edge case
        let (manager, _, _, _) = await makeModels()
        let outcome = await manager.download("C")
        #expect(outcome == .needsConfirmation([.nonCommercial(spdx: "CC-BY-NC-4.0")]))
        #expect(manager.row("C")?.state == .notInstalled)
        #expect(await manager.download("C", confirmed: true) == .completed)
    }

    @Test func tierWarningWhenModelNeedsMoreMemory() async {  // ENG-AC-18
        let heavy = descriptor("H", ["en"], minTier: .tier32Plus)
        let (manager, _, _, _) = await makeModels(catalog: [heavy])
        #expect(manager.preflight("H") == [.hardwareTier(required: .tier32Plus)])
    }

    @Test func lowDiskSpaceWarns() async {
        let mock = MockModelManager(descriptors: [descriptor("A", ["en"])])
        let manager = ModelManagerModel(
            manager: mock, hardware: PlaceholderHardware(), store: InMemorySettingsStore(), freeDiskBytes: { 10 })
        await manager.load()
        #expect(manager.preflight("A") == [.lowDiskSpace(needed: 1_000_000, available: 10)])
    }

    @Test func deleteUpdatesStateAndActiveDefaultNeedsConfirmation() async {  // ENG-AC-06
        let store = InMemorySettingsStore()
        await store.set("A", for: SettingsKey.preferredModel)
        let (manager, _, _, _) = await makeModels(installed: ["A", "B"], store: store)
        await manager.requestDelete("B")
        #expect(manager.row("B")?.state == .notInstalled)
        await manager.requestDelete("A")
        #expect(manager.pendingDeletion?.id == "A")
        #expect(manager.row("A")?.isInstalled == true)
        await manager.confirmPendingDeletion()
        #expect(manager.row("A")?.state == .notInstalled)
    }

    @Test func importCustomModelRegistersDescriptor() async {  // ENG-AC-07, SET-AC-05
        let (manager, _, _, _) = await makeModels()
        let imported = await manager.importModel(folder: URL(fileURLWithPath: "/tmp/x"), displayName: "Sinhala FT", languages: ["si"])
        #expect(imported?.isCustom == true)
        #expect(manager.row(imported?.id ?? "")?.isInstalled == true)
        #expect(await manager.importModel(folder: URL(fileURLWithPath: "/tmp/x"), displayName: " ", languages: ["si"]) == nil)
    }

    @Test func etaExtrapolatesFromFraction() {
        let start = Date(timeIntervalSince1970: 0)
        let progress = ModelManagerModel.Progress(fraction: 0.25, bytesReceived: 25, bytesTotal: 100, isVerifying: false, startedAt: start)
        #expect(progress.eta(now: Date(timeIntervalSince1970: 10)) == 30)
    }
}

@Suite @MainActor struct LinkedPickerTests {
    @Test func englishIsTheDefault() async {  // LANG-AC-01, SET-AC-08
        let (_, languages, _, _) = await makeModels()
        #expect(languages.languageMode == .single(.english))
        #expect(languages.kind == .single)
        #expect(languages.selectedModel == nil)
        #expect(languages.isExperimental(.sinhala))
    }

    @Test func languagesFilterModels() async {  // LANG-AC-02, SET-AC-06
        let (_, languages, _, _) = await makeModels()
        #expect(languages.availableModels.map(\.id) == ["A", "C"])
        await languages.selectLanguage("si")
        #expect(languages.availableModels.map(\.id) == ["B", "C"])
        await languages.setKind(.multilingual)
        await languages.selectLanguage("en")
        #expect(languages.languages == ["si", "en"])
        #expect(languages.availableModels.map(\.id) == ["C"])
        languages.showAllModels = true
        #expect(languages.availableModels.count == 3)
    }

    @Test func modelRestrictsLanguagesAndResetsWhenInvalid() async {  // LANG-AC-03
        let (_, languages, _, store) = await makeModels(installed: ["B"])
        languages.showAllModels = true
        #expect(languages.availableLanguages.contains("de"))
        #expect(await languages.chooseModel("B") == true)
        #expect(languages.languages == ["si"])  // english invalid for B: reset to the model's first language
        #expect(languages.availableLanguages == ["si"])
        #expect(await store.value(for: SettingsKey.preferredModel, as: String.self) == "B")
        #expect(await store.value(for: SettingsKey.languageMode, as: LanguageMode.self) == .single("si"))
    }

    @Test func currentLanguageKeptWhenStillSupported() async {
        let (_, languages, _, _) = await makeModels(installed: ["A"])
        await languages.selectLanguage("de")
        #expect(await languages.chooseModel("A") == true)
        #expect(languages.languages == ["de"])
    }

    @Test func choosingUndownloadedModelDownloadsThenApplies() async {  // SET-AC-07, ENG-AC-03
        let (manager, languages, _, store) = await makeModels()
        #expect(await languages.chooseModel("A") == true)
        #expect(manager.row("A")?.isInstalled == true)
        #expect(languages.selectedModel == "A")
        #expect(languages.downloadingModel == nil)
        #expect(await store.value(for: SettingsKey.preferredModel, as: String.self) == "A")
    }

    @Test func nonCommercialChoiceWaitsForConfirmation() async {
        let (manager, languages, _, _) = await makeModels()
        #expect(await languages.chooseModel("C") == false)
        #expect(languages.selectedModel == nil)
        #expect(languages.pendingChoice?.model == "C")
        await languages.confirmPendingChoice()
        #expect(languages.selectedModel == "C")
        #expect(manager.row("C")?.isInstalled == true)
        #expect(languages.pendingChoice == nil)
    }

    @Test func autoClearsSelectedModelAndAutoDetectListsAllModels() async {
        let (_, languages, _, _) = await makeModels(installed: ["A"])
        await languages.chooseModel("A")
        await languages.chooseModel(nil)
        #expect(languages.selectedModel == nil)
        await languages.setKind(.autoDetect)
        #expect(languages.availableModels.count == 3)
        #expect(languages.languageMode == .autoDetect)
    }

    @Test func persistedModeRestores() async {
        let store = InMemorySettingsStore()
        await store.set(LanguageMode.multilingual(["en", "si"]), for: SettingsKey.languageMode)
        let (_, languages, _, _) = await makeModels(store: store)
        #expect(languages.kind == .multilingual)
        #expect(languages.languages == ["en", "si"])
    }
}

@Suite @MainActor struct IgnoredSegmentsTests {
    private func make() async -> (IgnoredSegmentsModel, InMemoryRuleRepository) {
        let repo = InMemoryRuleRepository()
        let model = IgnoredSegmentsModel(repository: repo, store: InMemorySettingsStore())
        await model.load()
        return (model, repo)
    }

    @Test func firstLaunchSeedsExactlyTheDefaults() async {  // IGN-AC-01
        let (model, _) = await make()
        #expect(model.visibleRules(hallucination: false).map(\.pattern) == IgnoreRuleDefaults.patterns)
        #expect(model.visibleRules(hallucination: true).map(\.pattern) == IgnoreRuleDefaults.hallucinationPatterns)
        #expect(model.visibleRules(hallucination: true).allSatisfy { !$0.isEnabled })
        #expect(model.hallucinationFilter.value == false)  // off by default
        #expect(IgnoreRuleDefaults.patterns.count == 30)
    }

    private final class RederiveLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [IgnoreFilterSettings] = []
        func record(_ settings: IgnoreFilterSettings) { lock.withLock { items.append(settings) } }
        var all: [IgnoreFilterSettings] { lock.withLock { items } }
    }

    @Test func ruleChangesTriggerARederiveWithTheCurrentFilterSettings() async {  // IGN-AC-05
        let log = RederiveLog()
        let repo = InMemoryRuleRepository()
        let model = IgnoredSegmentsModel(
            repository: repo, store: InMemorySettingsStore(),
            rederive: { settings in
                log.record(settings)
                return IgnoreRederiver.Summary(transcripts: 1, segments: 3)
            })
        await model.load()
        #expect(log.all.isEmpty, "loading and seeding must not touch transcripts")
        let victim = model.rules[0].id
        await model.setEnabled(victim, false)
        await model.remove(model.rules[1].id)
        _ = await model.add(pattern: "[Applause!]")
        await model.resetAll()
        #expect(log.all.count == 4)
        #expect(log.all.allSatisfy { $0 == IgnoreFilterSettings(hallucinationFilter: false, lowConfidence: 0.5, noSpeech: 0.6) })
        #expect(model.lastRederive == IgnoreRederiver.Summary(transcripts: 1, segments: 3))
        #expect(!model.isRederiving)
    }

    @Test func failedOrInvalidEditsDoNotRederive() async {  // IGN-AC-03
        let log = RederiveLog()
        let model = IgnoredSegmentsModel(
            repository: InMemoryRuleRepository(), store: InMemorySettingsStore(),
            rederive: { settings in
                log.record(settings)
                return IgnoreRederiver.Summary(transcripts: 0, segments: 0)
            })
        await model.load()
        _ = await model.add(pattern: "   ")
        _ = await model.add(pattern: "(", match: .regex)
        #expect(log.all.isEmpty)
    }

    @Test func seedingHappensOnlyOnce() async {
        let repo = InMemoryRuleRepository()
        let store = InMemorySettingsStore()
        let first = IgnoredSegmentsModel(repository: repo, store: store)
        await first.load()
        let victim = first.rules[0].id
        await first.remove(victim)
        let second = IgnoredSegmentsModel(repository: repo, store: store)
        await second.load()
        #expect(!second.rules.contains { $0.id == victim })
    }

    @Test func addRemoveAndSoftDelete() async {  // IGN-AC-09, IGN-AC-13
        let (model, repo) = await make()
        guard case .success(let rule) = await model.add(pattern: "  [Laughs] ") else {
            Issue.record("add failed")
            return
        }
        #expect(rule.pattern == "[Laughs]")
        await model.remove(rule.id)
        #expect(!model.rules.contains { $0.id == rule.id })
        let stored = await repo.ignoreRules().first { $0.id == rule.id }
        #expect(stored?.deletedAt != nil)  // soft delete
    }

    @Test func duplicatesAndInvalidRulesAreRefused() async {  // IGN-AC-03, IGN-AC-11
        let (model, _) = await make()
        let duplicate = await model.add(pattern: "[music]")
        #expect(duplicate == .failure(.duplicate))
        #expect(model.errorMessage == "That rule already exists.")
        #expect(await model.add(pattern: "(", match: .regex) == .failure(.invalid("Invalid regular expression.")))
        #expect(await model.add(pattern: "   ") == .failure(.invalid("Enter a pattern.")))
        // same pattern with a different match mode is not a duplicate
        if case .failure = await model.add(pattern: "[music]", match: .contains) { Issue.record("should be allowed") }
    }

    @Test func searchFilters() async {  // IGN-AC-09
        let (model, _) = await make()
        model.searchText = "applause"
        #expect(model.visibleRules(hallucination: false).map(\.pattern) == ["(Applause.)", "[APPLAUSE]"])
    }

    @Test func restoreDefaultsRevivesDefaultsAndKeepsUserRules() async {  // IGN-AC-01
        let (model, _) = await make()
        await model.add(pattern: "[custom]")
        let removed = model.rules.first { $0.pattern == "[Music]" }!.id
        await model.remove(removed)
        await model.restoreDefaults()
        #expect(model.rules.contains { $0.id == removed })
        #expect(model.rules.contains { $0.pattern == "[custom]" })
        await model.resetAll()
        #expect(!model.rules.contains { $0.pattern == "[custom]" })
        #expect(model.rules.count == IgnoreRuleDefaults.rules().count)
    }

    @Test func exportImportRoundTrips() async throws {  // IGN-AC-10
        let (model, _) = await make()
        await model.add(pattern: "foo.*bar", match: .regex, scope: .inline)
        let data = try model.exportJSON()
        let (other, _) = await make()
        await other.resetAll()
        for rule in other.rules { await other.remove(rule.id) }
        let summary = try await other.importJSON(data)
        #expect(summary.added == model.rules.count)
        #expect(summary.skipped == 0 && summary.invalid == 0)
        #expect(try other.exportJSON() == data)
    }

    @Test func importReportsCountsAndIsUndoable() async throws {
        let (model, _) = await make()
        let file = IgnoreRuleFile(
            version: 1,
            rules: [
                .init(pattern: "[music]", match: .exact, scope: .wholeSegment, isEnabled: true, isHallucinationRule: false),
                .init(pattern: "(", match: .regex, scope: .wholeSegment, isEnabled: true, isHallucinationRule: false),
                .init(pattern: "[new]", match: .exact, scope: .wholeSegment, isEnabled: true, isHallucinationRule: false),
            ])
        let before = model.rules.count
        let summary = try await model.importJSON(JSONEncoder().encode(file))
        #expect(summary == ImportSummary(added: 1, skipped: 1, invalid: 1))
        #expect(model.rules.count == before + 1)
        await model.undoImport()
        #expect(model.rules.count == before)
        #expect(!model.canUndoImport)
    }

    @Test func malformedImportThrowsAndChangesNothing() async {  // SET-AC-18
        let (model, _) = await make()
        let before = model.rules
        await #expect(throws: IgnoreRuleError.self) { try await model.importJSON(Data("not json".utf8)) }
        await #expect(throws: IgnoreRuleError.self) { try await model.importJSON(Data(#"{"version":9,"rules":[]}"#.utf8)) }
        #expect(model.rules == before)
    }

    @Test func matchAndScopeEditsAreValidated() async {
        let (model, _) = await make()
        guard case .success(let rule) = await model.add(pattern: "(abc") else {
            Issue.record("add failed")
            return
        }
        await model.update(rule.id, match: .regex)  // invalid regex: rejected
        #expect(model.rules.first { $0.id == rule.id }?.match == .exact)
        await model.update(rule.id, scope: .inline)
        #expect(model.rules.first { $0.id == rule.id }?.scope == .inline)
    }
}

@Suite @MainActor struct DefaultsTests {
    @Test func meetingBehaviourDefaultsToAskFirst() async {  // SET-AC-10
        let model = MeetingsSettingsModel(store: InMemorySettingsStore())
        await model.load()
        for app in MeetingApp.allCases { #expect(model.policy(for: app).behavior == .askFirst) }
        #expect(model.consentNotice.value == true)
    }

    @Test func meetingPolicyPersistsAndClampsGrace() async {
        let store = InMemorySettingsStore()
        let model = MeetingsSettingsModel(store: store)
        await model.setBehavior(.autoTranscribeAndRecord, for: .zoom)
        await model.update(.zoom) { $0.autoStopGraceSeconds = 9_999 }
        await model.addExclusion("Standup", for: .zoom)
        await model.addExclusion("standup", for: .zoom)
        let reloaded = MeetingsSettingsModel(store: store)
        await reloaded.load()
        #expect(reloaded.policy(for: .zoom).behavior == .autoTranscribeAndRecord)
        #expect(reloaded.policy(for: .zoom).autoStopGraceSeconds == 300)
        #expect(reloaded.policy(for: .zoom).excludedKeywords == ["Standup"])
        #expect(reloaded.policy(for: .teams).behavior == .askFirst)
    }

    @Test func generalDefaultsAndLoginItem() async {  // SET-AC-02
        let store = InMemorySettingsStore()
        let login = InMemoryLaunchAtLogin()
        let model = GeneralSettingsModel(store: store, loginItem: login)
        await model.load()
        #expect(model.languageMode.value == .single(.english))
        #expect(model.languageKind == .single)
        #expect(model.showDockIcon && model.showMenuBarIcon.value && model.notificationsEnabled.value)
        #expect(!model.launchAtLogin)
        await model.setLaunchAtLogin(true)
        #expect(login.isEnabled && model.launchAtLogin)
        #expect(await store.value(for: SettingsKey.launchAtLogin, as: Bool.self) == true)
        await model.setLanguageKind(.autoDetect)
        #expect(await store.value(for: SettingsKey.languageMode, as: LanguageMode.self) == .autoDetect)
    }

    @Test func retentionDefaultsTo30Days() async {  // SET-AC-15
        let model = StorageSettingsModel(
            store: InMemorySettingsStore(), models: MockModelManager(), transcripts: InMemoryTranscripts(), clearCaches: { 42 })
        await model.load()
        #expect(model.retentionDays.value == 30)
        await model.clearCaches()
        #expect(model.lastFreedBytes == 42)
    }

    @Test func permissionsListsEveryKindWithDeepLinks() async {  // SET-AC-17
        let model = PermissionsSettingsModel(service: PlaceholderPermissions())
        await model.load()
        #expect(model.statuses.count == PermissionKind.allCases.count)
        for kind in PermissionKind.allCases { #expect(model.settingsURL(for: kind).scheme == "x-apple.systempreferences") }
    }

    @Test func permissionRowStatesDriveActionsAndRecovery() {  // SET-AC-17, ONB-AC-05/06
        let fresh = PermissionRowState(kind: .microphone, status: .notDetermined)
        #expect(fresh.action == .request && fresh.chipLabel == "Not requested" && fresh.recoveryNote == nil)
        #expect(fresh.showsSettingsLink)
        let onboarding = PermissionRowState(kind: .microphone, status: .notDetermined, context: .onboarding)
        #expect(onboarding.chipLabel == "Ask later" && !onboarding.showsSettingsLink && onboarding.actionTitle == "Allow now")
        let denied = PermissionRowState(kind: .accessibility, status: .denied, context: .onboarding)
        #expect(denied.action == .none && denied.showsSettingsLink && denied.recoveryNote?.contains("System Settings") == true)
        let granted = PermissionRowState(kind: .notifications, status: .granted)
        #expect(granted.action == .none && granted.recoveryNote == nil && granted.status.chipTone == .success)
        #expect(PermissionRowState(kind: .screenRecording, status: .restricted).recoveryNote != nil)
        #expect(Set(PermissionKind.allCases.map(\.systemImage)).count == PermissionKind.allCases.count)
        let ids = PermissionKind.allCases.map { PermissionRowState(kind: $0, status: .granted).identifierBase }
        #expect(Set(ids).count == PermissionKind.allCases.count)
    }

    @Test func permissionsModelRequestUpdatesStatusAndNeverBlocks() async {
        let model = PermissionsSettingsModel(service: ScriptedPermissions(initial: .notDetermined, afterRequest: .denied))
        await model.load()
        #expect(model.rowState(.microphone).action == .request)
        await model.request(.microphone)
        #expect(model.status(.microphone) == .denied)
        let denied = model.rowState(.microphone)
        #expect(denied.action == .request && denied.actionTitle == "Request access" && denied.showsRecheck)
        #expect(denied.helpNote?.contains("tccutil reset Microphone lk.dumindu.earmark.Earmark") == true)
        #expect(model.rowState(.accessibility).showsRecheck == false)
    }

    @Test func builtInCaptionPresetsExistAndAreReadOnly() async {  // SET-AC-11
        let model = CaptionPresetsModel(repository: InMemoryPresetRepository(), store: InMemorySettingsStore())
        await model.load()
        #expect(model.presets.map(\.name) == ["Subtle", "Presentation", "High contrast"])
        #expect(!model.isDraftEditable)
        await model.duplicateDraft()
        #expect(model.isDraftEditable && model.presets.count == 4)
    }

    @Test func shortcutConflictsWarnBeforeApplying() async {  // SET-AC-16
        let model = ShortcutsModel(store: InMemorySettingsStore(), hotkeys: nil)
        await model.load()
        let find = model.combo(for: .find)!
        #expect(await model.record(find, for: .quickOpen) == false)
        #expect(model.pendingConflict?.conflictsWith == .find)
        await model.confirmConflict()
        #expect(model.combo(for: .quickOpen) == find)
        #expect(model.combo(for: .find) == nil)
        #expect(await model.record(KeyCombo(keyCode: 0, modifiers: 0), for: .find) == false)  // needs a modifier
        await model.clear(.dictation)
        #expect(model.combo(for: .dictation) == nil)
    }

    @Test func replacementRulesValidateImportAndTest() async throws {  // SET-AC-14
        let model = ReplacementsModel(repository: InMemoryRuleRepository(), store: InMemorySettingsStore())
        await model.load()
        #expect(await model.save(ReplacementRule(find: "(", replacement: "x", isRegex: true)) == false)
        #expect(await model.save(ReplacementRule(find: "teh", replacement: "the")))
        #expect(ReplacementsModel.test(ReplacementRule(find: "teh", replacement: "the"), on: "teh cat") == "the cat")
        await model.addVocabulary("Earmark")
        await model.addVocabulary("earmark")
        #expect(model.vocabulary == ["Earmark"])
        let data = try model.exportJSON()
        #expect(try await model.importJSON(data).skipped == 1)
        await #expect(throws: IgnoreRuleError.self) { try await model.importJSON(Data("{}".utf8)) }
    }
}
