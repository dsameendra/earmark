import AppCore
import DesignSystem
import SwiftUI

/// SwiftUI content of the caption overlay. Tokens and DesignSystem components only; M8 restyles this view.
///
/// - Volatile lines are italic and dimmed; finals replace them in place (same `CaptionLine.id`).
/// - Reduce Transparency / Increase Contrast render a solid, high-contrast surface (LIVE-AC-10).
/// - Reduce Motion cuts instead of fading (LIVE-AC-09).
public struct CaptionOverlayView: View {
    private let model: CaptionOverlayModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityPolicyOverride) private var policyOverride

    public init(model: CaptionOverlayModel) { self.model = model }

    private var policy: AccessibilityPolicy {
        policyOverride
            ?? AccessibilityPolicy(
                reduceTransparency: reduceTransparency, increaseContrast: contrast == .increased, reduceMotion: reduceMotion)
    }

    public var body: some View {
        let preset = model.preset
        let policy = policy
        let alignment = Self.horizontalAlignment(preset.alignment)
        ZStack {
            VStack(alignment: alignment, spacing: DSSpacing.xs) {
                ForEach(model.visibleLines) { line in
                    CaptionLineView(line: line, preset: preset, highContrast: policy.usesHighContrast, alignment: alignment)
                        .transition(DSTransition.appear(policy))
                }
            }
            .frame(maxWidth: .infinity, alignment: Self.frameAlignment(preset.alignment))
            .padding(.horizontal, DSSpacing.lg)
            .padding(.vertical, DSSpacing.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .clipped()
            .background { CaptionBackground(preset: preset, policy: policy) }
            // Only the captions fade after silence; the recording dot below always stays visible (LIVE-AC-18).
            .opacity(model.isFaded ? 0 : 1)
            .animation(policy.animation(.easeInOut(duration: 0.4)), value: model.isFaded)
            .animation(policy.animation(.easeOut(duration: 0.15)), value: model.visibleLines.map(\.id))
        }
        .overlay(alignment: .topTrailing) { indicator }
        .overlay(alignment: .top) { dragHandle }
        // Captions are always dark-styled: light text on a dark surface regardless of the system appearance.
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("liveCaptions.overlay")
    }

    /// Grip shown while the overlay is draggable (click-through off, or Option held).
    @ViewBuilder private var dragHandle: some View {
        if model.isDragHandleVisible {
            Capsule()
                .fill(DSColor.secondaryText)
                .frame(width: DSSpacing.xxl, height: DSSpacing.xs)
                .padding(.top, DSSpacing.xs)
                .accessibilityLabel(Text("Drag to move captions"))
                .accessibilityIdentifier("liveCaptions.overlay.dragHandle")
        }
    }

    @ViewBuilder private var indicator: some View {
        if model.isCaptioning {
            HStack(spacing: DSSpacing.xs) {
                if model.isPaused {
                    Image(systemName: CaptionOverlaySymbol.paused.systemName)
                        .font(DSTypography.badge)
                        .foregroundStyle(DSColor.secondaryText)
                }
                RecordingIndicator(label: nil)
            }
            .padding(DSSpacing.sm)
            .accessibilityIdentifier("liveCaptions.overlay.indicator")
        }
    }

    static func horizontalAlignment(_ a: CaptionPreset.Alignment) -> HorizontalAlignment {
        switch a {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    static func frameAlignment(_ a: CaptionPreset.Alignment) -> Alignment {
        switch a {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

struct CaptionLineView: View {
    let line: CaptionLine
    let preset: CaptionPreset
    let highContrast: Bool
    let alignment: HorizontalAlignment

    private var textColor: Color { highContrast ? DSColor.primaryText : CaptionStyle.color(fromHex: preset.textColorHex) }
    private var translation: (text: String, isLowConfidence: Bool)? {
        (preset.showTranslation || preset.translatedOnly) ? CaptionOverlayModel.parseTranslation(line.translation) : nil
    }

    var body: some View {
        VStack(alignment: alignment, spacing: DSSpacing.xxs) {
            if !(preset.translatedOnly && translation != nil) {
                primary(line.text)
            }
            if let translation {
                HStack(spacing: DSSpacing.xs) {
                    if translation.isLowConfidence {
                        Image(systemName: CaptionOverlaySymbol.lowConfidence.systemName)
                            .font(DSTypography.badge)
                            .foregroundStyle(DSColor.warning)
                            .accessibilityLabel(Text("Low confidence translation"))
                    }
                    Text(translation.text)
                        .font(CaptionStyle.font(for: preset).weight(.regular))
                        .scaleEffect(0.7, anchor: .leading)
                        .foregroundStyle(textColor.opacity(0.85))
                }
                .accessibilityIdentifier("liveCaptions.overlay.translation")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("liveCaptions.overlay.line")
    }

    private func primary(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DSSpacing.sm) {
            if preset.showSpeakerLabels, let label = line.speakerLabel {
                SpeakerChip(name: label, slot: line.speakerSlot ?? 0)
            }
            if preset.showLanguageBadge, let language = line.language { LanguageBadge(language) }
            Text(text)
                .font(CaptionStyle.font(for: preset))
                .italic(line.isVolatile)
                .foregroundStyle(textColor.opacity(line.isVolatile ? 0.65 : 1))
                .multilineTextAlignment(textAlignment)
                .shadow(color: preset.textOutline ? DSColor.solidChrome.opacity(0.9) : .clear, radius: 1.5)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var textAlignment: TextAlignment {
        switch preset.alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

/// Liquid Glass, solid, or no background; always solid when Reduce Transparency / Increase Contrast is on.
struct CaptionBackground: View {
    let preset: CaptionPreset
    let policy: AccessibilityPolicy

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: preset.cornerRadius, style: .continuous)
        if policy.usesSolidSurface {
            shape.fill(DSColor.solidChrome).overlay(shape.strokeBorder(DSColor.hairline, lineWidth: 1.5))
        } else {
            switch preset.background {
            case .liquidGlass:
                Color.clear.glassBackground(radius: preset.cornerRadius).opacity(preset.backgroundOpacity)
            case .solid:
                shape.fill(DSColor.solidChrome.opacity(preset.backgroundOpacity))
            case .none:
                Color.clear
            }
        }
    }
}
