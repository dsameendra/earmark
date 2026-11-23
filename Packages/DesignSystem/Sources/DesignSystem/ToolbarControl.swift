import SwiftUI

// MARK: - Toolbar controls

/// The label of a toolbar button, menu or toggle, with its horizontal padding INSIDE the label.
///
/// The system draws the toolbar item's hover and pressed highlight (and the prominent capsule) around the control's
/// label. Padding applied outside the `Button`/`Menu` only widens the glass capsule and leaves the highlight hugging the
/// bare label; padding inside the label makes the highlight exactly the padded button, concentric with the capsule.
/// `contentShape(Capsule())` makes the whole padded area the hit target.
///
/// Use it as `Button(action:) { DSToolbarLabel("Find", symbol: .find) }` or as a `Menu`/`Toggle` label, then apply
/// `.labelStyle(.titleAndIcon)` or `.iconOnly` on the control as before.
public struct DSToolbarLabel: View {
    /// Horizontal padding inside a title+icon toolbar control.
    public static let horizontalPadding: CGFloat = DSSpacing.sm
    /// Horizontal padding inside an icon-only toolbar control: equal to the system's vertical inset, so it stays square-ish.
    public static let iconOnlyPadding: CGFloat = DSSpacing.xs

    /// Height of the label, so the system hover and pressed highlight fills the toolbar capsule instead of hugging the text.
    public static let minHeight: CGFloat = 30

    private let label: AnyView
    private let iconOnly: Bool

    public init(_ title: LocalizedStringKey, systemImage: String, iconOnly: Bool = false) {
        label = AnyView(Label(title, systemImage: systemImage))
        self.iconOnly = iconOnly
    }

    public init<S: StringProtocol>(_ title: S, systemImage: String, iconOnly: Bool = false) {
        label = AnyView(Label(title, systemImage: systemImage))
        self.iconOnly = iconOnly
    }

    public init(_ title: LocalizedStringKey, symbol: DSSymbol, iconOnly: Bool = false) {
        label = AnyView(Label(title, symbol: symbol))
        self.iconOnly = iconOnly
    }

    public var body: some View {
        label
            .padding(.horizontal, iconOnly ? Self.iconOnlyPadding : Self.horizontalPadding)
            .frame(minWidth: iconOnly ? Self.minHeight : nil, minHeight: Self.minHeight)
            .contentShape(Capsule())
    }
}

extension View {
    /// Marks a control as a toolbar control and sizes it `.large`.
    ///
    /// Adds NO padding: a `Button`/`Menu`/`Toggle` gets its horizontal padding from ``DSToolbarLabel`` inside its label (so the
    /// system hover/pressed highlight covers it); a segmented `Picker` grows with `controlSize(.large)` (its segments are its
    /// highlight). Padding outside the control would sit in the capsule but outside the highlight.
    public func dsToolbarControl() -> some View {
        controlSize(.large)
    }
}

// MARK: - Custom hover/pressed controls

/// Shape of a ``DSHoverButtonStyle`` highlight.
public enum DSHoverShape: Sendable, Hashable {
    case capsule
    case rounded(CGFloat)
}

/// For controls the system does not draw (sidebar footer rows, in-row action buttons): a button style whose hover and
/// pressed highlight is drawn behind the FULL padded button (padding and minimum size live inside the style), in a shape
/// that is also the hit shape. Hover fades in with `DSMotion.glide`, a 120 ms fade under Reduce Motion.
public struct DSHoverButtonStyle: ButtonStyle {
    public var shape: DSHoverShape
    public var horizontalPadding: CGFloat
    public var iconOnly: Bool

    public init(shape: DSHoverShape = .capsule, horizontalPadding: CGFloat = DSSpacing.sm, iconOnly: Bool = false) {
        self.shape = shape
        self.horizontalPadding = horizontalPadding
        self.iconOnly = iconOnly
    }

    public func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, style: self)
    }

    private struct HoverBody: View {
        let configuration: ButtonStyleConfiguration
        let style: DSHoverButtonStyle
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            PolicyReader { policy in
                let fillOpacity = !isEnabled ? 0 : configuration.isPressed ? 0.16 : hovering ? 0.08 : 0
                configuration.label
                    .padding(.horizontal, style.iconOnly ? DSSpacing.xs : style.horizontalPadding)
                    .frame(minWidth: style.iconOnly ? DSLayout.minControlHeight : nil, minHeight: DSLayout.minControlHeight)
                    .background { shapeView.fill(DSColor.primaryText.opacity(fillOpacity)) }
                    .contentShape(shapeView)
                    .onHover { hovering = $0 }
                    .animation(DSMotion.glide.animation(policy), value: hovering)
                    .animation(DSMotion.glide.animation(policy), value: configuration.isPressed)
            }
        }

        private var shapeView: AnyShape {
            switch style.shape {
            case .capsule: AnyShape(Capsule())
            case .rounded(let radius): AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            }
        }
    }
}

extension ButtonStyle where Self == DSHoverButtonStyle {
    /// Hover/pressed highlight over the full padded button (capsule by default).
    public static var dsHover: DSHoverButtonStyle { DSHoverButtonStyle() }
    /// Square-ish icon-only variant.
    public static var dsHoverIcon: DSHoverButtonStyle { DSHoverButtonStyle(iconOnly: true) }
    public static func dsHover(shape: DSHoverShape, horizontalPadding: CGFloat = DSSpacing.sm) -> DSHoverButtonStyle {
        DSHoverButtonStyle(shape: shape, horizontalPadding: horizontalPadding)
    }
}

extension View {
    /// Outer inset for a full-window content panel under a unified toolbar.
    ///
    /// The toolbar already centres its controls in their band, so the panel keeps only a thin top gap; a full-size gap made
    /// the controls look pushed toward the window's top edge.
    public func dsPanelInset() -> some View {
        padding(EdgeInsets(top: DSSpacing.xs, leading: DSSpacing.md, bottom: DSSpacing.md, trailing: DSSpacing.md))
    }
}
