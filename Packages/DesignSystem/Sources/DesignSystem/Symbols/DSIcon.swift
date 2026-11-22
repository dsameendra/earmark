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
    @Environment(\.dsSymbolStyle) private var environmentStyle

    nonisolated public init(_ symbol: DSSymbol, style: DSSymbolStyle? = nil, decorative: Bool = true) {
        self.symbol = symbol
        self.stockName = symbol.systemImageName
        self.styleOverride = style
        self.decorative = decorative
    }

    /// Mixed models (a section list where only some entries are covered by `DSSymbol`): custom symbol when present, otherwise the stock name.
    nonisolated public init(_ symbol: DSSymbol?, orStock stockName: String, style: DSSymbolStyle? = nil, decorative: Bool = true) {
        self.symbol = symbol
        self.stockName = stockName
        self.styleOverride = style
        self.decorative = decorative
    }

    @ViewBuilder public var body: some View {
        if decorative {
            rendered.accessibilityHidden(true)
        } else {
            rendered.accessibilityLabel(symbol?.accessibilityLabel ?? "")
        }
    }

    @ViewBuilder private var rendered: some View {
        switch symbol?.resolution ?? .stock(stockName) {
        case .stock(let name):
            Image(systemName: name)
        case .custom(let name):
            switch styleOverride ?? environmentStyle {
            case .duotone:
                Image(name, bundle: .module).symbolRenderingMode(.palette).foregroundStyle(.primary, DSColor.accent)
            case .hierarchical:
                Image(name, bundle: .module).symbolRenderingMode(.hierarchical)
            case .monochrome:
                Image(name, bundle: .module).symbolRenderingMode(.monochrome)
            }
        }
    }
}

// MARK: - Call-site initialisers (the codemod target: `Button("Retry", symbol: .retry)`)

extension Label where Title == Text, Icon == DSIcon {
    nonisolated public init(_ title: LocalizedStringKey, symbol: DSSymbol) {
        self.init { Text(title) } icon: { DSIcon(symbol) }
    }

    nonisolated public init<S: StringProtocol>(_ title: S, symbol: DSSymbol) {
        self.init { Text(title) } icon: { DSIcon(symbol) }
    }

    /// For models that cover only some entries with `DSSymbol` (`symbol` nil falls back to the stock name).
    nonisolated public init<S: StringProtocol>(_ title: S, symbol: DSSymbol?, orStock stockName: String) {
        self.init { Text(title) } icon: { DSIcon(symbol, orStock: stockName) }
    }
}

extension Button where Label == SwiftUI.Label<Text, DSIcon> {
    nonisolated public init(_ title: LocalizedStringKey, symbol: DSSymbol, role: ButtonRole? = nil, action: @escaping () -> Void) {
        // Same call-site contract as the SDK initialisers (non-Sendable closures from main-actor views are accepted).
        nonisolated(unsafe) let run = action
        self.init(role: role, action: { run() }) { SwiftUI.Label(title, symbol: symbol) }
    }

    nonisolated public init<S: StringProtocol>(_ title: S, symbol: DSSymbol, role: ButtonRole? = nil, action: @escaping () -> Void) {
        // Same call-site contract as the SDK initialisers (non-Sendable closures from main-actor views are accepted).
        nonisolated(unsafe) let run = action
        self.init(role: role, action: { run() }) { SwiftUI.Label(title, symbol: symbol) }
    }
}

extension Menu where Label == SwiftUI.Label<Text, DSIcon> {
    nonisolated public init(_ title: LocalizedStringKey, symbol: DSSymbol, @ViewBuilder content: () -> Content) {
        self.init(content: content) { SwiftUI.Label(title, symbol: symbol) }
    }
}
