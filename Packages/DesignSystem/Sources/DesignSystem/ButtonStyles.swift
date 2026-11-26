import SwiftUI

extension View {
    /// The app's prominent button: system prominent capsule with a label colour that passes contrast on the ember fill in both
    /// appearances (white on dark ember is only 2.5:1).
    public func dsProminentButton() -> some View {
        buttonStyle(.borderedProminent).foregroundStyle(DSColor.onAccent)
    }
}

/// Inline text link in the app accent (the system `.link` style ignores the tint and draws system blue).
public struct DSLinkButtonStyle: ButtonStyle {
    public init() {}
    @State private var hovering = false
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(DSColor.accentText)
            .underline(hovering)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hovering = $0 }
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == DSLinkButtonStyle {
    public static var dsLink: DSLinkButtonStyle { DSLinkButtonStyle() }
}
