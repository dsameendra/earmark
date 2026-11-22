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
            .dsPressScale(configuration.isPressed)
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

/// Press feedback for icon-style buttons: a small scale-down and dim on the exit curve (140 ms). Under Reduce Motion the
/// button only dims (a 120 ms crossfade), it never scales.
public struct DSPressButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        PressBody(configuration: configuration)
    }

    private struct PressBody: View {
        let configuration: ButtonStyle.Configuration
        var body: some View {
            PolicyReader { policy in
                configuration.label
                    .scaleEffect(configuration.isPressed && !policy.suppressesMotion ? 0.94 : 1)
                    .opacity(configuration.isPressed ? 0.82 : 1)
                    .dsAnimation(.exit, value: configuration.isPressed)
            }
        }
    }
}

extension View {
    /// A 2 % scale-down while pressed on the exit curve; nothing moves under Reduce Motion.
    func dsPressScale(_ isPressed: Bool) -> some View {
        PolicyReader { policy in
            self.scaleEffect(isPressed && !policy.suppressesMotion ? 0.98 : 1).dsAnimation(.exit, value: isPressed)
        }
    }
}
