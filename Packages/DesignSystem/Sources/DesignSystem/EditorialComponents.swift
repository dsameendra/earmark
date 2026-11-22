import SwiftUI

/// The single primary action on a screen: a solid Ember capsule in every accessibility mode.
public struct EmberButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DSTypography.body.weight(.semibold))
            .foregroundStyle(colorScheme == .dark ? DSColor.paper : DSColor.contentBackground)
            .padding(.horizontal, DSSpacing.lg)
            .frame(minHeight: DSLayout.prominentControlHeight)
            .background(DSColor.accent.opacity(configuration.isPressed ? 0.85 : 1), in: Capsule())
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}

/// Quiet uppercase section label used by inspectors, lists and model cards.
public struct SectionCaption: View {
    private let title: LocalizedStringKey

    public init(_ title: LocalizedStringKey) { self.title = title }

    public var body: some View {
        Text(title).font(DSTypography.label).textCase(.uppercase)
            .tracking(DSTypography.labelTracking).foregroundStyle(DSColor.secondaryText)
            .accessibilityAddTraits(.isHeader)
    }
}
