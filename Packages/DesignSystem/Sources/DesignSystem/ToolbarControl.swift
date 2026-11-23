import SwiftUI

extension View {
    /// Large toolbar control with comfortable horizontal breathing room inside the system glass capsule.
    ///
    /// Apply to buttons, menus and pickers placed in a `ToolbarItem`; the system supplies the capsule and vertical centring.
    public func dsToolbarControl() -> some View {
        controlSize(.large)
            .padding(.horizontal, DSSpacing.sm)
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
