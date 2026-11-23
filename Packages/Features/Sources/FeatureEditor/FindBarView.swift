import AppCore
import DesignSystem
import SwiftUI

/// ⌘F find bar with ⌥⌘F replace row, options, scope, preview and replace one/all (EDIT-AC-11, FR-AC-01...04).
struct FindBarView: View {
    let model: TranscriptEditorModel
    @Bindable var find: FindReplaceModel
    @FocusState.Binding var fieldFocused: Bool

    static let replaceHint = "Replace edits the original text. Switch to Original or Bilingual to replace."

    var body: some View {
        VStack(spacing: DSSpacing.xs) {
            HStack(spacing: DSSpacing.sm) {
                DSIcon(.find).foregroundStyle(DSColor.secondaryText)
                TextField("Find", text: $find.text)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit { find.next() }
                    .onKeyPress(.return, phases: .down) { press in
                        press.modifiers.contains(.shift)
                            ? {
                                find.previous()
                                return .handled
                            }() : .ignored
                    }
                    .frame(minWidth: 160)
                    .accessibilityLabel("Find")
                Text(find.statusText)
                    .font(DSTypography.caption).monospacedDigit()
                    .foregroundStyle(find.errorMessage == nil ? DSColor.secondaryText : DSColor.danger)
                    .lineLimit(1)
                    .frame(minWidth: 60, alignment: .leading)
                Button {
                    find.previous()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(find.matches.isEmpty).help("Previous match (⇧⏎)")
                Button {
                    find.next()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(find.matches.isEmpty).help("Next match (⏎)")
                Toggle("Aa", isOn: $find.matchCase).toggleStyle(.button).help("Match case")
                Toggle("Word", isOn: $find.wholeWord).toggleStyle(.button).help("Whole word")
                Toggle(".*", isOn: $find.isRegex).toggleStyle(.button).help("Regular expression")
                Picker("Scope", selection: $find.scope) {
                    Text("All").tag(FindScopeChoice.all)
                    Text("Selection").tag(FindScopeChoice.selection)
                    Divider()
                    ForEach(model.speakers) { Text("Speaker: \($0.name)").tag(FindScopeChoice.speaker($0.id)) }
                    Divider()
                    ForEach(model.languageChoices, id: \.self) { Text("Language: \($0.rawValue)").tag(FindScopeChoice.language($0)) }
                }
                .labelsHidden().frame(width: 150)
                Button {
                    find.toggleReplace()
                } label: {
                    DSIcon(.replace)
                }
                .help("Show replace (⌥⌘F)")
                Button {
                    find.close()
                } label: {
                    Image(systemName: "xmark")
                }.help("Close")
            }
            if find.showsReplace {
                HStack(spacing: DSSpacing.sm) {
                    DSIcon(.replace).foregroundStyle(DSColor.secondaryText)
                    TextField("Replace with", text: $find.replacement).textFieldStyle(.roundedBorder).frame(minWidth: 160)
                        .accessibilityLabel("Replace with")
                    Button("Replace") { Task { await find.replaceCurrent() } }.disabled(!find.canReplace)
                        .help(model.lockedHelp ?? (find.replaceNeedsOriginalView ? Self.replaceHint : ""))
                    Button("Replace All…") { Task { await find.requestReplaceAll() } }.disabled(!find.canReplace)
                        .help(model.lockedHelp ?? (find.replaceNeedsOriginalView ? Self.replaceHint : ""))
                    if model.isReadOnly {
                        Text(model.lockedHelp ?? "Read-only").font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                    }
                    Spacer()
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, DSSpacing.md)
        .padding(.vertical, DSSpacing.sm)
        .background(DSColor.solidChrome)
        .overlay(alignment: .bottom) { Divider() }
        .sheet(
            isPresented: Binding(get: { find.preview != nil }, set: { if !$0 { find.cancelPreview() } })
        ) {
            ReplacePreviewSheet(find: find)
        }
    }
}

/// Before → after list shown before Replace All is applied (FR-AC-04).
struct ReplacePreviewSheet: View {
    let find: FindReplaceModel

    var body: some View {
        let items = find.preview ?? []
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            Text("Replace All").font(DSTypography.title)
            Text("\(items.reduce(0) { $0 + $1.matchCount }) replacements in \(items.count) segments")
                .foregroundStyle(DSColor.secondaryText)
            List(items, id: \.segmentID) { item in
                VStack(alignment: .leading, spacing: DSSpacing.xs) {
                    Text(item.before).foregroundStyle(DSColor.secondaryText).strikethrough()
                    Text(item.after)
                }
                .font(SinhalaFont.font(size: 13))
                .padding(.vertical, DSSpacing.xxs)
            }
            .frame(minHeight: 200)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { find.cancelPreview() }.keyboardShortcut(.cancelAction)
                Button("Replace All") { Task { await find.confirmReplaceAll() } }
                    .keyboardShortcut(.defaultAction).disabled(items.isEmpty)
            }
        }
        .padding(DSSpacing.lg)
        .frame(width: 520, height: 380)
    }
}
