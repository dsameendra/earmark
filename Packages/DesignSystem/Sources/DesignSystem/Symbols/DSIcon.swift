import AppKit
import SwiftUI

/// How a duotone symbol is drawn.
public enum DSSymbolStyle: Sendable, Hashable {
    /// Ink line in the current foreground style, accent detail in `DSColor.accent` (palette rendering).
    case duotone
    /// Both layers in the current foreground style (rest state in the sidebar, menus, disabled controls).
    case monochrome
    /// Ink in the foreground style, accent detail as a lighter tint of the same style (hierarchical rendering).
    case hierarchical
}

private struct DSSymbolStyleKey: EnvironmentKey {
    static let defaultValue: DSSymbolStyle = .duotone
}

extension EnvironmentValues {
    /// Rendering style of every `DSIcon` below this view. Sidebar rows use `.monochrome` at rest and `.duotone` when selected.
    public var dsSymbolStyle: DSSymbolStyle {
        get { self[DSSymbolStyleKey.self] }
        set { self[DSSymbolStyleKey.self] = newValue }
    }
}

extension View {
    public func dsSymbolStyle(_ style: DSSymbolStyle) -> some View { environment(\.dsSymbolStyle, style) }
}

/// Where a symbol is drawn. Decides the size-aware stock fallback (see ``DSSymbol/prefersStock(atPointSize:)``).
///
/// | Context | Nominal size | Custom symbols |
/// |---|---|---|
/// | `.sidebar` | 17 pt | all |
/// | `.header` | 20 pt and up | all |
/// | `.emptyState` | 40 pt | all |
/// | `.toolbar` | 15 pt | not the heavy five |
/// | `.menu` | 13 pt | not the heavy five |
public enum DSIconContext: Sendable, Hashable {
    case sidebar, header, emptyState, toolbar, menu

    /// Nominal point size of icons in this context.
    public var pointSize: CGFloat {
        switch self {
        case .sidebar: 17
        case .header: 20
        case .emptyState: 40
        case .toolbar: 15
        case .menu: 13
        }
    }
}

extension DSSymbol {
    /// Largest point size at which the stock fallback replaces the custom symbol (toolbar and menu sizes).
    public static let stockFallbackMaxPointSize: CGFloat = 15

    /// Symbols whose custom drawing measured visibly heavier than stock beside system text (`m8-symbol-review.md`:
    /// thickness ratio above 1.2 against stock). At toolbar and menu sizes they render as the stock glyph.
    public static let heavyAtSmallSizes: Set<DSSymbol> = [.liveCaptions, .recentlyDeleted, .settings, .video, .download]

    /// `true` when this symbol must use its stock fallback at `pointSize` (<= 15 pt and one of ``heavyAtSmallSizes``).
    /// A `nil` size means unknown (sidebar, header and empty-state sizes) and keeps the custom symbol.
    public func prefersStock(atPointSize pointSize: CGFloat?) -> Bool {
        guard let pointSize else { return false }
        return pointSize <= Self.stockFallbackMaxPointSize && Self.heavyAtSmallSizes.contains(self)
    }
}

private struct DSIconContextKey: EnvironmentKey {
    static let defaultValue: DSIconContext? = nil
}

extension EnvironmentValues {
    /// Where `DSIcon`s below this view are drawn; toolbars and menus set `.toolbar` / `.menu` to get the stock fallback table.
    public var dsIconContext: DSIconContext? {
        get { self[DSIconContextKey.self] }
        set { self[DSIconContextKey.self] = newValue }
    }
}

extension View {
    /// Declares the surface icons below are drawn on (drives the size-aware stock fallback).
    public func dsIconContext(_ context: DSIconContext?) -> some View { environment(\.dsIconContext, context) }
}

/// Where a symbol name resolves: the custom asset in the DesignSystem resource bundle, or the stock fallback.
public enum DSSymbolResolution: Equatable, Sendable {
    case custom(String)
    case stock(String)

    /// Resolves `assetName` in `bundle`; falls back to the stock `fallback` when the custom symbol is not present
    /// (missing name, or a build where the asset catalog was not compiled).
    public static func resolve(assetName: String, fallback: String, in bundle: Bundle? = nil) -> DSSymbolResolution {
        DSSymbolAssets.contains(assetName, in: bundle ?? .module) ? .custom(assetName) : .stock(fallback)
    }
}

enum DSSymbolAssets {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Bool] = [:]

    static func contains(_ name: String, in bundle: Bundle) -> Bool {
        let key = "\(bundle.bundlePath)|\(name)"
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[key] { return hit }
        let found = NSImage(symbolName: name, bundle: bundle, variableValue: 1) != nil
        cache[key] = found
        return found
    }
}

extension DSSymbol {
    /// Resolution for this symbol in the DesignSystem resource bundle.
    public var resolution: DSSymbolResolution { .resolve(assetName: assetName, fallback: systemImageName) }

    /// `true` when the custom duotone asset is present in the bundle (not just the stock fallback).
    public var hasCustomAsset: Bool {
        if case .custom = resolution { return true }
        return false
    }

    /// The raw resolved image: custom symbol when available, stock fallback otherwise. No rendering mode applied.
    public var image: Image {
        switch resolution {
        case .custom(let name): Image(name, bundle: .module)
        case .stock(let name): Image(systemName: name)
        }
    }

    /// A `Label` with this symbol as its icon (decorative; the title is the accessible name).
    public func label(_ title: LocalizedStringKey) -> Label<Text, DSIcon> { Label(title, symbol: self) }
}

/// A symbol as a view. Inherits size from the environment font like an SF Symbol, so it sits on the text baseline.
///
/// Decorative by default (hidden from VoiceOver, because it normally sits inside a `Label` or next to text); pass
/// `decorative: false` for a standalone symbol and VoiceOver reads `DSSymbol.accessibilityLabel`.
public struct DSIcon: View {
    private let symbol: DSSymbol?
    private let stockName: String
    private let decorative: Bool
    private let styleOverride: DSSymbolStyle?
    private let pointSize: CGFloat?
    @Environment(\.dsSymbolStyle) private var environmentStyle
    @Environment(\.dsIconContext) private var context

    /// `pointSize` (when the call site knows it) overrides the ``DSIconContext`` for the stock-fallback table.
    nonisolated public init(_ symbol: DSSymbol, style: DSSymbolStyle? = nil, pointSize: CGFloat? = nil, decorative: Bool = true) {
        self.symbol = symbol
        self.stockName = symbol.systemImageName
        self.styleOverride = style
        self.pointSize = pointSize
        self.decorative = decorative
    }

    /// Mixed models (a section list where only some entries are covered by `DSSymbol`): custom symbol when present, otherwise the stock name.
    nonisolated public init(_ symbol: DSSymbol?, orStock stockName: String, style: DSSymbolStyle? = nil, decorative: Bool = true) {
        self.symbol = symbol
        self.stockName = stockName
        self.styleOverride = style
        self.pointSize = nil
        self.decorative = decorative
    }

    @ViewBuilder public var body: some View {
        if decorative {
            rendered.accessibilityHidden(true)
        } else {
            rendered.accessibilityLabel(symbol?.accessibilityLabel ?? "")
        }
    }

    private var resolved: DSSymbolResolution {
        guard let symbol else { return .stock(stockName) }
        if symbol.prefersStock(atPointSize: pointSize ?? context?.pointSize) { return .stock(symbol.systemImageName) }
        return symbol.resolution
    }

    @ViewBuilder private var rendered: some View {
        switch resolved {
        case .stock(let name):
            Image(systemName: name)
        case .custom(let name):
            switch styleOverride ?? environmentStyle {
            case .duotone:
                Image(name, bundle: .module).symbolRenderingMode(.palette).foregroundStyle(.primary, DSColor.accent)
            case .hierarchical:
                Image(name, bundle: .module).symbolRenderingMode(.hierarchical)
            case .monochrome:
                Image(name, bundle: .module).symbolRenderingMode(.palette).foregroundStyle(.primary, .primary)
            }
        }
    }
}

// MARK: - Call-site initialisers (the codemod target: `Button("Retry", symbol: .retry)`)

extension Label where Title == Text, Icon == DSIcon {
    nonisolated public init(_ title: LocalizedStringKey, symbol: DSSymbol) {
        self.init {
            Text(title)
        } icon: {
            DSIcon(symbol)
        }
    }

    nonisolated public init<S: StringProtocol>(_ title: S, symbol: DSSymbol) {
        self.init {
            Text(title)
        } icon: {
            DSIcon(symbol)
        }
    }

    /// For models that cover only some entries with `DSSymbol` (`symbol` nil falls back to the stock name).
    nonisolated public init<S: StringProtocol>(_ title: S, symbol: DSSymbol?, orStock stockName: String) {
        self.init {
            Text(title)
        } icon: {
            DSIcon(symbol, orStock: stockName)
        }
    }
}

extension Button where Label == SwiftUI.Label<Text, DSIcon> {
    nonisolated public init(_ title: LocalizedStringKey, symbol: DSSymbol, role: ButtonRole? = nil, action: @escaping () -> Void) {
        // Same call-site contract as the SDK initialisers (non-Sendable closures from main-actor views are accepted).
        nonisolated(unsafe) let run = action
        self.init(role: role, action: { run() }, label: { SwiftUI.Label(title, symbol: symbol) })
    }

    nonisolated public init<S: StringProtocol>(_ title: S, symbol: DSSymbol, role: ButtonRole? = nil, action: @escaping () -> Void) {
        // Same call-site contract as the SDK initialisers (non-Sendable closures from main-actor views are accepted).
        nonisolated(unsafe) let run = action
        self.init(role: role, action: { run() }, label: { SwiftUI.Label(title, symbol: symbol) })
    }
}

extension Menu where Label == SwiftUI.Label<Text, DSIcon> {
    nonisolated public init(_ title: LocalizedStringKey, symbol: DSSymbol, @ViewBuilder content: () -> Content) {
        self.init(content: content) { SwiftUI.Label(title, symbol: symbol) }
    }
}
