import DesignSystem
import SwiftUI

/// Lays out children left to right and wraps to a new line, so capability chips never clip or crush each other.
public struct WrappingChips: Layout {
    public var spacing: CGFloat
    public init(spacing: CGFloat = DSSpacing.xs) { self.spacing = spacing }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxWidth = max(maxWidth, x - spacing)
        }
        return (CGSize(width: maxWidth.isFinite ? maxWidth : 0, height: y + rowHeight), origins)
    }
}

public extension ModelCapabilityChip.Tone {
    var dsTone: DSTone {
        switch self {
        case .neutral: .neutral
        case .positive: .success
        case .info: .info
        case .warning: .warning
        }
    }
}

/// A single capability chip. Never colour alone: the icon and text carry the meaning, and VoiceOver reads `spoken`.
public struct CapabilityChipView: View {
    public let chip: ModelCapabilityChip
    public init(_ chip: ModelCapabilityChip) { self.chip = chip }

    public var body: some View {
        HStack(spacing: DSSpacing.xs) {
            if let symbol = chip.symbol { Image(systemName: symbol).accessibilityHidden(true) }
            Text(chip.text)
        }
        .font(DSTypography.badge)
        .foregroundStyle(chip.tone.dsTone.color)
        .padding(.horizontal, DSSpacing.sm)
        .padding(.vertical, DSSpacing.xxs + 1)
        .background(chip.tone.dsTone.color.opacity(0.12), in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chip.spoken)
        .accessibilityIdentifier("model.chip.\(chip.id)")
    }
}

/// The wrapped chip list for one model.
public struct ModelChipsFlow: View {
    public let chips: [ModelCapabilityChip]
    public init(_ chips: [ModelCapabilityChip]) { self.chips = chips }

    public var body: some View {
        WrappingChips(spacing: DSSpacing.xs) {
            ForEach(chips) { CapabilityChipView($0) }
        }
    }
}
