import AppCore
import DesignSystem
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
                    Text(item.createdAt, style: .date).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                }
            }
            Spacer(minLength: DSSpacing.sm)
            ItemBadges(item: item, model: model)
            Text(durationText(item.duration)).font(DSTypography.timestamp).foregroundStyle(DSColor.secondaryText)
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
        .dsSolidSurface(.sheet, radius: DSRadius.large, selected: isSelected)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(sourceName(item.source)), \(durationText(item.duration))")
    }
}
