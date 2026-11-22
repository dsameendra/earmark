import AppCore
import DesignSystem
import FeatureSupport
import SwiftUI

private func durationText(_ seconds: TimeInterval) -> String {
    Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
}

/// Compact metadata shared by row and card: source icon, languages, speakers, tags, missing-media and retention badges.
private struct ItemBadges: View {
    let item: Transcript
    let model: LibraryModel

    var body: some View {
        HStack(spacing: DSSpacing.xs) {
            ForEach(item.languages.sorted(), id: \.self) { LanguageBadge($0) }
            if !item.speakers.isEmpty {
                Label("\(item.speakers.count)", symbol: .speaker).font(DSTypography.caption)
                    .foregroundStyle(DSColor.secondaryText)
                    .accessibilityLabel("\(item.speakers.count) speakers")
            }
            ForEach(item.tags.prefix(3), id: \.self) { StatusPill(LocalizedStringKey($0), systemImage: "tag") }
            if model.mediaStates[item.id] == .missing {
                StatusPill("Media missing", systemImage: "exclamationmark.triangle", tone: .warning)
            }
            if let days = model.daysRemaining(for: item) {
                StatusPill("\(days) days left", systemImage: "clock", tone: days <= 3 ? .warning : .neutral)
            }
        }
    }
}

private func sourceSymbol(_ source: TranscriptSource) -> DSSymbol {
    switch source {
    case .file: .library
    case .meeting: .meetings
    case .liveCaptions: .liveCaptions
    case .dictation: .dictation
    }
}

private func sourceName(_ source: TranscriptSource) -> String {
    switch source {
    case .file: "File"
    case .meeting: "Meeting"
    case .liveCaptions: "Live captions"
    case .dictation: "Dictation"
    }
}

/// List row.
struct LibraryRow: View {
    @Environment(\.shellLayout) private var layout
    let item: Transcript
    let model: LibraryModel

    var body: some View {
        HStack(spacing: DSSpacing.md) {
            DSIcon(sourceSymbol(item.source)).dsSymbolStyle(.monochrome).foregroundStyle(DSColor.secondaryText).frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                Text(item.title).lineLimit(1)
                if let hit = model.snippets[item.id] {
                    Text("\(durationText(hit.time))  \(hit.snippet)")
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColor.secondaryText)
                        .lineLimit(2)
                } else {
                    Text(sourceName(item.source)).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                }
                HStack(spacing: DSSpacing.xs) {
                    if model.mediaStates[item.id] == .missing {
                        Label("Media missing", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(DSColor.warning)
                    }
                    ForEach(item.tags.prefix(2), id: \.self) { Text($0).foregroundStyle(DSColor.secondaryText) }
                }
                .font(DSTypography.caption)
            }
            Spacer(minLength: DSSpacing.sm)
            Text(item.createdAt, format: .dateTime.month(.abbreviated).day())
                .font(DSTypography.caption).foregroundStyle(DSColor.secondaryText).frame(width: 70, alignment: .leading)
            Text(durationText(item.duration)).font(DSTypography.timestamp).foregroundStyle(DSColor.secondaryText)
                .frame(width: 64, alignment: .trailing)
            if !layout.droppedLibraryColumns.contains("Language") {
                Text(item.languages.sorted().map { $0.rawValue.uppercased() }.joined(separator: " · "))
                    .font(DSTypography.badge).foregroundStyle(DSColor.secondaryText).lineLimit(1).frame(width: 80)
            }
            if !layout.droppedLibraryColumns.contains("Speakers") {
                HStack(spacing: 3) {
                    ForEach(Array(item.speakers.prefix(3).enumerated()), id: \.element.id) { index, _ in
                        Circle().fill(SpeakerPalette.color(forSlot: index)).frame(width: 8, height: 8)
                    }
                    Text("\(item.speakers.count)").font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                }.frame(width: 80, alignment: .leading)
                    .accessibilityLabel("\(item.speakers.count) speakers")
            }
            if let days = model.daysRemaining(for: item) {
                Text("\(days) days left").font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                Button("Restore") { Task { await model.restore([item.id]) } }.buttonStyle(.borderless)
            }
        }
        .padding(.vertical, DSSpacing.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [item.title, sourceName(item.source), durationText(item.duration)]
        if let hit = model.snippets[item.id] { parts.append("match: \(hit.snippet)") }
        if model.mediaStates[item.id] == .missing { parts.append("media missing") }
        if let days = model.daysRemaining(for: item) { parts.append("\(days) days left") }
        return parts.joined(separator: ", ")
    }
}

/// Grid card.
struct LibraryCard: View {
    let item: Transcript
    let model: LibraryModel
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            HStack {
                DSIcon(sourceSymbol(item.source)).dsSymbolStyle(.monochrome).foregroundStyle(DSColor.secondaryText)
                Spacer()
                Text(durationText(item.duration)).font(DSTypography.timestamp).foregroundStyle(DSColor.secondaryText)
            }
            Text(item.title).font(DSTypography.headline).lineLimit(2)
            if let hit = model.snippets[item.id] {
                Text(hit.snippet).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText).lineLimit(3)
            } else {
                Text(item.createdAt, style: .date).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
            }
            ItemBadges(item: item, model: model)
        }
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
        .padding(DSSpacing.md)
        .dsSolidSurface(.inset, radius: DSRadius.card, selected: isSelected)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(sourceName(item.source)), \(durationText(item.duration))")
    }
}

/// Column labels follow the same responsive rules as each row.
struct LibraryColumnsHeader: View {
    @Environment(\.shellLayout) private var layout
    var body: some View {
        HStack(spacing: DSSpacing.md) {
            SectionCaption("Title").frame(maxWidth: .infinity, alignment: .leading)
            SectionCaption("Date").frame(width: 70, alignment: .leading)
            SectionCaption("Length").frame(width: 64, alignment: .trailing)
            if !layout.droppedLibraryColumns.contains("Language") { SectionCaption("Language").frame(width: 80) }
            if !layout.droppedLibraryColumns.contains("Speakers") { SectionCaption("Speakers").frame(width: 80, alignment: .leading) }
        }
        .padding(.horizontal, DSSpacing.lg).padding(.vertical, DSSpacing.sm)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityHidden(true)
    }
}
