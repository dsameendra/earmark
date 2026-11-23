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
