import AppCore
import DesignSystem
import SwiftUI

/// Solid inspector cards; the same content is a popover below the 1100 pt window breakpoint.
struct EditorInspector: View {
    let model: TranscriptEditorModel
    let onSpeakers: () -> Void
    let onBookmarks: () -> Void
    /// Wraps the control a panel opens from, so the popover hangs off that control.
    let speakersPopover: (AnyView) -> AnyView
    let bookmarksPopover: (AnyView) -> AnyView

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpacing.md) {
                SheetCard(radius: DSRadius.card) {
                    VStack(alignment: .leading, spacing: DSSpacing.md) {
                        SectionCaption("Speakers")
                        ForEach(model.speakers) { speaker in
                            Button(action: onSpeakers) {
                                HStack(spacing: DSSpacing.sm) {
                                    SpeakerChip(
                                        name: String(speaker.name.prefix(1)),
                                        slot: SpeakerPalette.slot(
                                            forHex: speaker.colorHex, fallback: model.speakers.firstIndex(where: { $0.id == speaker.id }) ?? 0))
                                    Text(speaker.name).font(DSTypography.body.weight(.medium)).lineLimit(2)
                                    Spacer(minLength: 0)
                                    Text("\(model.segmentCount(for: speaker.id))").font(DSTypography.timestamp).foregroundStyle(
                                        DSColor.secondaryText)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(model.isLockedByJob)
                            .help(model.lockedHelp ?? "")
                            .accessibilityLabel("Edit speaker \(speaker.name), \(model.segmentCount(for: speaker.id)) segments")
                        }
                        speakersPopover(
                            AnyView(
                                Button(model.speakers.isEmpty ? "Add speakers…" : "Edit speakers…", action: onSpeakers)
                                    .buttonStyle(.plain).foregroundStyle(DSColor.accentText)
                                    .disabled(model.isLockedByJob)
                                    .help(model.lockedHelp ?? "")))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                SheetCard(radius: DSRadius.card) {
                    VStack(alignment: .leading, spacing: DSSpacing.md) {
                        SectionCaption("Earmarks")
                        ForEach(model.bookmarks.prefix(8)) { bookmark in
                            Button {
                                model.go(to: bookmark)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: DSSpacing.sm) {
                                    DSIcon(.earmark)
                                    Text(
                                        "\(TimeFormat.clock(bookmark.time)) · \(bookmark.note.isEmpty ? "Earmarked moment" : bookmark.note)"
                                    )
                                    .font(DSTypography.caption).multilineTextAlignment(.leading)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        bookmarksPopover(
                            AnyView(
                                Button(model.bookmarks.isEmpty ? "Add an earmark…" : "All bookmarks and highlights…", action: onBookmarks)
                                    .buttonStyle(.plain).foregroundStyle(DSColor.accentText)))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                SheetCard(radius: DSRadius.card) {
                    VStack(alignment: .leading, spacing: DSSpacing.md) {
                        SectionCaption("Hidden")
                        Text("\(model.hiddenIgnoredCount) ignored segments. Nothing is deleted; show them at any time.")
                            .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                        Toggle("Show ignored segments", isOn: Binding(get: { model.showIgnored }, set: { model.setShowIgnored($0) }))
                            .accessibilityIdentifier("editor.inspector.showIgnored")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .accessibilityLabel("Transcript inspector")
        .accessibilityIdentifier("editor.inspector")
    }
}
