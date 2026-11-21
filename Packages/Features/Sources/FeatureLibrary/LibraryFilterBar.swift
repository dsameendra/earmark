import AppCore
import DesignSystem
import SwiftUI

/// Filter menus: source, language, date, duration, speakers, tags and folder (LIB-AC-01, SCR-001).
struct LibraryFilterBar: View {
    @Bindable var model: LibraryModel
    let onNewFolder: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DSSpacing.sm) {
                sourceMenu
                languageMenu
                dateMenu
                durationMenu
                speakerMenu
                tagMenu
                folderMenu
                if model.filters.isActive {
                    Button("Clear Filters", systemImage: "xmark.circle") { model.filters = LibraryFilters() }
                        .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, DSSpacing.lg)
            .padding(.vertical, DSSpacing.sm)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filters")
    }

    private func toggle<T: Hashable>(_ value: T, in keyPath: WritableKeyPath<LibraryFilters, Set<T>>) -> Binding<Bool> {
        Binding(
            get: { model.filters[keyPath: keyPath].contains(value) },
            set: { on in
                if on { model.filters[keyPath: keyPath].insert(value) } else { model.filters[keyPath: keyPath].remove(value) }
            })
    }

    private func menuLabel(_ title: String, count: Int) -> some View {
        Text(count > 0 ? "\(title) (\(count))" : title)
    }

    private var sourceMenu: some View {
        Menu {
            ForEach(TranscriptSource.allCases, id: \.self) { source in
                Toggle(Self.name(of: source), isOn: toggle(source, in: \.sources))
            }
        } label: {
            menuLabel("Source", count: model.filters.sources.count)
        }
    }

    private var languageMenu: some View {
        Menu {
            ForEach(model.availableLanguages, id: \.self) { code in
                Toggle(Locale.current.localizedString(forLanguageCode: code.rawValue) ?? code.rawValue, isOn: toggle(code, in: \.languages))
            }
            if model.availableLanguages.isEmpty { Text("No languages yet") }
        } label: {
            menuLabel("Language", count: model.filters.languages.count)
        }
    }

    private var dateMenu: some View {
        Menu {
            Picker("Date", selection: $model.filters.date) {
                ForEach(DatePreset.allCases) { Text($0.title).tag($0) }
            }
        } label: {
            Text(model.filters.date == .any ? "Date" : model.filters.date.title)
        }
    }

    private var durationMenu: some View {
        Menu {
            Picker("Duration", selection: $model.filters.duration) {
                ForEach(DurationPreset.allCases) { Text($0.title).tag($0) }
            }
        } label: {
            Text(model.filters.duration == .any ? "Duration" : model.filters.duration.title)
        }
    }

    private var speakerMenu: some View {
        Menu {
            ForEach(model.availableSpeakers, id: \.self) { name in Toggle(name, isOn: toggle(name, in: \.speakerNames)) }
            if model.availableSpeakers.isEmpty { Text("No named speakers yet") }
        } label: {
            menuLabel("Speakers", count: model.filters.speakerNames.count)
        }
    }

    private var tagMenu: some View {
        Menu {
            ForEach(model.availableTags, id: \.self) { tag in Toggle(tag, isOn: toggle(tag, in: \.tags)) }
            if model.availableTags.isEmpty { Text("No tags yet") }
        } label: {
            menuLabel("Tags", count: model.filters.tags.count)
        }
    }

    private var folderMenu: some View {
        Menu {
            Picker("Folder", selection: $model.filters.folderID) {
                Text("All Folders").tag(FolderID?.none)
                ForEach(model.folders) { Text($0.name).tag(FolderID?.some($0.id)) }
            }
            Divider()
            Button("New Folder…", systemImage: "folder.badge.plus", action: onNewFolder)
            if let id = model.filters.folderID {
                Button("Delete This Folder", systemImage: "folder.badge.minus", role: .destructive) {
                    Task { await model.deleteFolder(id) }
                }
            }
        } label: {
            Text(model.folderName(for: model.filters.folderID) ?? "Folder")
        }
    }

    private static func name(of source: TranscriptSource) -> String {
        switch source {
        case .file: "File"
        case .meeting: "Meeting"
        case .liveCaptions: "Live captions"
        case .dictation: "Dictation"
        }
    }
}
