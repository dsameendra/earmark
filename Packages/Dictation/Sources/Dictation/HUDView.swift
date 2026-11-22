import DesignSystem
import SwiftUI

// glass-layer: floater (the one transient floater of its screen: caption overlay / dictation HUD)

/// The dictation HUD capsule: recording dot, listening bars, live text and the release hint.
/// Recording is always `DSColor.recording`, never the accent. Glass falls back to solid under Reduce Transparency
/// (via `glassBackground`), and bars do not animate under Reduce Motion (DICT-AC-16). M8 restyles this view only.
public struct DictationHUDView: View {
    public static let size = CGSize(width: 460, height: 56)
    let model: DictationHUDModel

    public init(model: DictationHUDModel) { self.model = model }

    public var body: some View {
        HStack(spacing: DSSpacing.md) {
            leading
            Text(model.displayText)
                .font(DSTypography.body)
                .foregroundStyle(model.phase.isError ? DSColor.danger : DSColor.primaryText)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("dictation.hud.text")
            if model.isExperimental {
                StatusPill("Experimental", tone: .warning)
                    .accessibilityIdentifier("dictation.hud.experimental")
            }
            if !model.hint.isEmpty, model.phase == .listening {
                Text(model.hint)
                    .font(DSTypography.caption)
                    .foregroundStyle(DSColor.secondaryText)
                    .accessibilityIdentifier("dictation.hud.hint")
            }
        }
        .padding(.horizontal, DSSpacing.lg)
        .frame(width: Self.size.width, height: Self.size.height)
        .glassBackground(radius: DSRadius.pill)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(model.accessibilitySummary))
        .accessibilityIdentifier("dictation.hud")
    }

    @ViewBuilder private var leading: some View {
        switch model.phase {
        case .listening:
            HStack(spacing: DSSpacing.sm) {
                Circle().fill(DSColor.recording).frame(width: 8, height: 8)
                ListeningBars(levels: model.levels)
            }
            .accessibilityIdentifier("dictation.hud.bars")
        case .processing, .error:
            if let name = model.phase.systemImage {
                Image(systemName: name)
                    .foregroundStyle(model.phase.isError ? DSColor.danger : DSColor.secondaryText)
            }
        }
    }
}

extension DictationHUDModel.Phase {
    var isError: Bool { if case .error = self { true } else { false } }
}

/// Level bars in the recording colour. Heights follow recent input levels; no animation under Reduce Motion.
struct ListeningBars: View {
    let levels: [Float]
    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(DSColor.recording)
                    .frame(width: 3, height: 4 + CGFloat(levels[i]) * 20)
            }
        }
        .frame(height: 24)
        .dsAnimation(.linear(duration: 0.08), value: levels)
        .accessibilityHidden(true)
    }
}
