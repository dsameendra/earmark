import DesignSystem
import SwiftUI

/// Responsive window rules of the M8 handoff (section 5), as a pure function of the window width.
///
/// - Window minimum 960 x 600 (`DSLayout.minWindowSize`).
/// - Below 1100 pt the Editor inspector hides behind a toolbar toggle and opens as a solid popover.
/// - Below 800 pt the sidebar collapses (a toolbar button reveals it as an overlay). With a 960 pt window minimum this
///   only applies to a window that is narrower than the minimum for a moment (live resize, Stage Manager tiles).
/// - Content never stretches past 1120 pt; wider windows add margin.
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
    /// Maximum content width (centred).
    public var contentMaxWidth: CGFloat { DSLayout.contentMaxWidth }
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

    /// Width of centred content in a window `width` wide (never above `contentMaxWidth`).
    public func contentWidth(available: CGFloat) -> CGFloat { min(available, contentMaxWidth) }
}

private struct ShellLayoutKey: EnvironmentKey {
    static let defaultValue = ShellLayout(width: 1440)
}

private struct InspectorPresentedKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
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
    /// Centres content and caps it at the 1120 pt maximum width.
    public func shellContentWidth() -> some View {
        frame(maxWidth: DSLayout.contentMaxWidth).frame(maxWidth: .infinity)
    }
}
