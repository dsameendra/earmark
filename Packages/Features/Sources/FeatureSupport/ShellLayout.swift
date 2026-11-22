import DesignSystem
import SwiftUI

/// Responsive window rules of the M8 handoff (section 5), as a pure function of the window width.
///
/// - Window minimum 960 x 600 (`DSLayout.minWindowSize`).
/// - Below 1100 pt the Editor inspector hides behind a toolbar toggle and opens as a solid popover.
/// - Below 800 pt the sidebar collapses (a toolbar button reveals it as an overlay). With a 960 pt window minimum this
///   only applies to a window that is narrower than the minimum for a moment (live resize, Stage Manager tiles).
/// - Workspace surfaces fill the detail column. Long-form prose may set a local reading width.
/// - Home action cards: four across, two across when narrow, one column when compact.
public struct ShellLayout: Equatable, Sendable {
    public var width: CGFloat

    public init(width: CGFloat) { self.width = width }

    /// Width class of the `Responsive` board.
    public enum WidthClass: Sendable, Equatable {
        /// Below 800 pt.
        case compact
        /// 800 pt up to (not including) 1100 pt.
        case narrow
        /// 1100 pt and above.
        case regular
    }

    public var widthClass: WidthClass {
        if width < DSLayout.sidebarCollapseWidth { return .compact }
        if width < DSLayout.inspectorCollapseWidth { return .narrow }
        return .regular
    }

    /// `true` below 800 pt.
    public var sidebarCollapsed: Bool { width < DSLayout.sidebarCollapseWidth }
    /// `true` below 1100 pt: the Editor inspector is behind a toolbar toggle.
    public var inspectorCollapsed: Bool { width < DSLayout.inspectorCollapseWidth }
    /// Available workspace width. The user's full-window refinement supersedes the old global 1120 pt cap.
    public var contentMaxWidth: CGFloat { .infinity }
    /// Home quick-action cards across.
    public var homeActionColumns: Int {
        switch widthClass {
        case .compact: 1
        case .narrow: 2
        case .regular: 4
        }
    }

    /// Library table columns hidden at this width, in the order they drop (Language first, then Speakers).
    public var droppedLibraryColumns: [String] {
        switch widthClass {
        case .compact: ["Language", "Speakers"]
        case .narrow: ["Language"]
        case .regular: []
        }
    }

    /// Uses every available point for the workspace; individual prose views retain their own readable line length.
    public func contentWidth(available: CGFloat) -> CGFloat { max(0, available) }
}

private struct ShellLayoutKey: EnvironmentKey {
    static let defaultValue = ShellLayout(width: 1440)
}

private struct InspectorPresentedKey: EnvironmentKey {
    static let defaultValue = true
}

private struct InspectorToggleKey: EnvironmentKey {
    static let defaultValue: Binding<Bool> = .constant(false)
}

extension EnvironmentValues {
    /// The narrow-window inspector toggle, shared with the popover so dismissing it updates the toolbar.
    public var inspectorToggle: Binding<Bool> {
        get { self[InspectorToggleKey.self] }
        set { self[InspectorToggleKey.self] = newValue }
    }
    /// The shell's current responsive layout (set by `ShellView` from the window width).
    public var shellLayout: ShellLayout {
        get { self[ShellLayoutKey.self] }
        set { self[ShellLayoutKey.self] = newValue }
    }

    /// Whether the Editor inspector should be shown: always when the window is wide, otherwise only while the toolbar
    /// toggle is on. The Editor reads this (T36); the shell owns the toggle.
    public var inspectorPresented: Bool {
        get { self[InspectorPresentedKey.self] }
        set { self[InspectorPresentedKey.self] = newValue }
    }
}

extension View {
    /// Fills the workspace and paints its whole extent, including empty/loading states and maximized windows.
    public func shellContentWidth() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DSColor.paper)
    }
}
