import AppCore
import DesignSystem
import SwiftUI
import UniformTypeIdentifiers

struct IgnoredSegmentsView: View {
    let model: IgnoredSegmentsModel
    @State private var newPattern = ""
    @State private var newMatch: RuleMatch = .exact
    @State private var newScope: RuleScope = .wholeSegment
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDocument = JSONDocument(data: Data())
    @State private var confirmResetAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            HStack {
                TextField("Search", text: Binding(get: { model.searchText }, set: { model.searchText = $0 }), prompt: Text("Search rules"))
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                Spacer()
                Button("Import…", systemImage: "square.and.arrow.down") { showImporter = true }
                Button("Export…", symbol: .export) {
                    if let data = try? model.exportJSON() {
                        exportDocument = JSONDocument(data: data)
                        showExporter = true
                    }
                }
                if model.canUndoImport { Button("Undo import") { Task { await model.undoImport() } } }
                Menu("Defaults") {
                    Button("Restore defaults") { Task { await model.restoreDefaults() } }
                    Button("Reset all…", role: .destructive) { confirmResetAll = true }
                }
            }
            HStack {
                TextField("Add a segment to ignore", text: $newPattern).textFieldStyle(.roundedBorder)
                    .onSubmit(addRule)
                Picker("Match", selection: $newMatch) { ForEach(RuleMatch.allCases, id: \.self) { Text($0.title).tag($0) } }
                    .labelsHidden().frame(width: 110)
                Picker("Scope", selection: $newScope) { ForEach(RuleScope.allCases, id: \.self) { Text($0.title).tag($0) } }
                    .labelsHidden().frame(width: 130)
                Button("Add", action: addRule).disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle").font(DSTypography.caption).foregroundStyle(DSColor.danger)
            }
            if let summary = model.lastImport {
                Text("Imported \(summary.added), skipped \(summary.skipped) duplicates, \(summary.invalid) invalid.")
                    .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
            }
            table(model.visibleRules(hallucination: false))
            GroupBox {
                VStack(alignment: .leading, spacing: DSSpacing.sm) {
                    Toggle("Filter likely hallucinations (off by default)", isOn: model.hallucinationFilter.binding)
                    Text("Phrases like “Thank you for watching.” are only hidden when the engine was unsure about them.")
                        .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                    if model.hallucinationFilter.value {
                        LabeledContent("Low confidence below") {
                            Slider(value: model.lowConfidence.binding, in: 0...1).frame(width: 160)
                        }
                        LabeledContent("No-speech at or above") {
                            Slider(value: model.noSpeech.binding, in: 0...1).frame(width: 160)
                        }
                    }
                    table(model.visibleRules(hallucination: true), minHeight: 70)
                }
            } label: {
                Text("Hallucination list")
            }
        }
        .padding(DSSpacing.lg)
        .task { await model.load() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            Task { _ = try? await model.importJSON(data) }
        }
        .fileExporter(isPresented: $showExporter, document: exportDocument, contentType: .json, defaultFilename: "ignored-segments") { _ in
        }
        .confirmationDialog("Remove all your own rules and restore the defaults?", isPresented: $confirmResetAll) {
            Button("Reset all", role: .destructive) { Task { await model.resetAll() } }
        }
    }

    private func addRule() {
        let pattern = newPattern
        Task {
            if case .success = await model.add(pattern: pattern, match: newMatch, scope: newScope) { newPattern = "" }
        }
    }

    private func table(_ rules: [IgnoreRule], minHeight: CGFloat = 180) -> some View {
        Table(rules) {
            TableColumn("Segment") { rule in Text(rule.pattern).font(.body.monospaced()).lineLimit(1) }
            TableColumn("Match") { rule in
                Picker(
                    "Match", selection: Binding(get: { rule.match }, set: { value in Task { await model.update(rule.id, match: value) } })
                ) {
                    ForEach(RuleMatch.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
            }
            .width(100)
            TableColumn("Scope") { rule in
                Picker(
                    "Scope", selection: Binding(get: { rule.scope }, set: { value in Task { await model.update(rule.id, scope: value) } })
                ) {
                    ForEach(RuleScope.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
            }
            .width(120)
            TableColumn("On") { rule in
                if !rule.isHallucinationRule {
                    Toggle(
                        "Enabled", isOn: Binding(get: { rule.isEnabled }, set: { value in Task { await model.setEnabled(rule.id, value) } })
                    )
                    .labelsHidden()
                }
            }
            .width(40)
            TableColumn("") { rule in
                Button("Remove", systemImage: "minus.circle") { Task { await model.remove(rule.id) } }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).accessibilityLabel("Remove \(rule.pattern)")
            }
            .width(30)
        }
        .frame(minHeight: minHeight)
    }
}

extension RuleMatch {
    var title: String {
        switch self {
        case .exact: "Exact"
        case .contains: "Contains"
        case .regex: "Regex"
        }
    }
}

extension RuleScope {
    var title: String {
        switch self {
        case .wholeSegment: "Whole segment"
        case .inline: "Inline"
        }
    }
}

struct JSONDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct ReplacementsView: View {
    let model: ReplacementsModel
    @State private var draft = ReplacementRule(find: "", replacement: "")
    @State private var testText = ""
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDocument = JSONDocument(data: Data())
    @State private var newTerm = ""

    var body: some View {
        Form {
            Section("Add a rule") {
                TextField("Find", text: $draft.find)
                TextField("Replace with", text: $draft.replacement)
                HStack {
                    Toggle("Match case", isOn: $draft.matchCase)
                    Toggle("Whole word", isOn: $draft.wholeWord)
                    Toggle("Regex", isOn: $draft.isRegex)
                }
                TextField("Test on sample text", text: $testText)
                if !testText.isEmpty, ReplacementsModel.validate(draft) == nil {
                    Text(ReplacementsModel.test(draft, on: testText)).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                }
                if let message = model.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(DSColor.danger)
                }
                Button("Add rule") {
                    Task {
                        if await model.save(draft) { draft = ReplacementRule(find: "", replacement: "") }
                    }
                }
                .disabled(draft.find.isEmpty)
            }
            Section {
                Toggle("Apply replacements to new jobs", isOn: model.applyByDefault.binding)
                TextField("Search", text: Binding(get: { model.searchText }, set: { model.searchText = $0 }))
                ForEach(model.visibleRules) { rule in
                    HStack {
                        Toggle(
                            "Enabled",
                            isOn: Binding(
                                get: { rule.isEnabled },
                                set: { value in
                                    var copy = rule
                                    copy.isEnabled = value
                                    Task { await model.save(copy) }
                                })
                        ).labelsHidden()
                        Text(rule.find).font(.body.monospaced())
                        Image(systemName: "arrow.right").foregroundStyle(DSColor.secondaryText)
                        Text(rule.replacement.isEmpty ? "(delete)" : rule.replacement)
                        if rule.isRegex { StatusPill("Regex", tone: .info) }
                        if model.loopWarnings.contains(rule.id) {
                            StatusPill("May loop", systemImage: "exclamationmark.triangle", tone: .warning)
                        }
                        Spacer()
                        Button("Remove", systemImage: "minus.circle") { Task { await model.remove(rule.id) } }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                }
                HStack {
                    Button("Import…", systemImage: "square.and.arrow.down") { showImporter = true }
                    Button("Export…", symbol: .export) {
                        if let data = try? model.exportJSON() {
                            exportDocument = JSONDocument(data: data)
                            showExporter = true
                        }
                    }
                }
            } header: {
                Text("Rules")
            }
            Section {
                HStack {
                    TextField("Add a name or term", text: $newTerm).onSubmit(addTerm)
                    Button("Add", action: addTerm).disabled(newTerm.isEmpty)
                }
                ForEach(model.vocabulary, id: \.self) { term in
                    HStack {
                        Text(term)
                        Spacer()
                        Button("Remove", systemImage: "minus.circle") { Task { await model.removeVocabulary(term) } }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Custom vocabulary")
            } footer: {
                Text("Names and jargon passed to engines that support vocabulary hints.")
            }
        }
        .formStyle(.grouped)
        .task { await model.load() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            Task { _ = try? await model.importJSON(data) }
        }
        .fileExporter(isPresented: $showExporter, document: exportDocument, contentType: .json, defaultFilename: "replacements") { _ in }
    }

    private func addTerm() {
        let term = newTerm
        newTerm = ""
        Task { await model.addVocabulary(term) }
    }
}
