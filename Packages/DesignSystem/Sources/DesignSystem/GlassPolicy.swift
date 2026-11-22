import SwiftUI

/// Pure decision logic for when glass must degrade to a solid surface or motion must be suppressed.
///
/// Reduce Transparency or Increase Contrast force solid backgrounds with high-contrast text;
/// Reduce Motion suppresses animation.
public struct AccessibilityPolicy: Sendable, Equatable {
    public var reduceTransparency: Bool
    public var increaseContrast: Bool
    public var reduceMotion: Bool

    public init(reduceTransparency: Bool = false, increaseContrast: Bool = false, reduceMotion: Bool = false) {
        self.reduceTransparency = reduceTransparency
        self.increaseContrast = increaseContrast
        self.reduceMotion = reduceMotion
    }

    /// `true` when glass must be replaced by an opaque surface.
    public var usesSolidSurface: Bool { reduceTransparency || increaseContrast }
    /// `true` when borders and high-contrast text should be drawn.
    public var usesHighContrast: Bool { increaseContrast || reduceTransparency }
    /// `true` when animations should be replaced by cuts.
    public var suppressesMotion: Bool { reduceMotion }

    /// Returns `animation`, or `nil` when Reduce Motion is on.
    public func animation(_ animation: Animation?) -> Animation? { reduceMotion ? nil : animation }
}

private struct AccessibilityPolicyKey: EnvironmentKey {
    static let defaultValue: AccessibilityPolicy? = nil
}

extension EnvironmentValues {
    /// Test/preview override of the accessibility policy. When `nil`, system settings are read.
    public var accessibilityPolicyOverride: AccessibilityPolicy? {
        get { self[AccessibilityPolicyKey.self] }
        set { self[AccessibilityPolicyKey.self] = newValue }
    }
}

/// Reads the effective ``AccessibilityPolicy`` from the environment.
struct PolicyReader<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityPolicyOverride) private var override
    let content: (AccessibilityPolicy) -> Content

    init(@ViewBuilder content: @escaping (AccessibilityPolicy) -> Content) { self.content = content }

    var body: some View {
        content(
            override
                ?? AccessibilityPolicy(
                    reduceTransparency: reduceTransparency, increaseContrast: contrast == .increased, reduceMotion: reduceMotion))
    }
}

/// The three glass layers of the M8 design (Handoff 1 "Glass materials"). Budget: at most
/// ``DSGlass/maxLayersPerScreen`` glass layers per screen (sidebar, one floating toolbar group, one transient
/// floater). Glass is for chrome that floats over content, never for content.
public enum DSGlassLayer: Sendable, Hashable, CaseIterable {
    /// Blur 16, fill 30 %. Small pills and the scrubber dock floating over media. `Glass.clear`.
    case clear
    /// Blur 28, fill 58 %. Sidebar, floating toolbar groups, menu bar popover. `Glass.regular`.
    case regular
    /// Blur 40, fill 72-82 %. Live overlay, dictation HUD, prompts that must read over anything.
    /// There is no `Glass.prominent` in the SDK: this is `Glass.regular` with a stronger Paper tint.
    case prominent

    /// Blur radius from the boards (documentation and AppKit panels; SwiftUI glass owns its own blur).
    public var blurRadius: CGFloat {
        switch self {
        case .clear: 16
        case .regular: 28
        case .prominent: 40
        }
    }

    /// Fill opacity from the boards (documentation and `NSVisualEffectView` fallbacks).
    public var fillOpacity: Double {
        switch self {
        case .clear: 0.30
        case .regular: 0.58
        case .prominent: 0.82
        }
    }

    /// The SDK glass for this layer, with an optional extra tint and interactivity.
    public func glass(tint: Color? = nil, interactive: Bool = false) -> Glass {
        var g: Glass
        switch self {
        case .clear: g = .clear
        case .regular: g = .regular
        case .prominent: g = Glass.regular.tint(DSColor.paper.opacity(0.55))
        }
        if let tint { g = g.tint(tint) }
        return interactive ? g.interactive() : g
    }
}

/// Glass budget constants.
public enum DSGlass {
    /// At most this many glass layers per screen: sidebar, one floating toolbar group, one transient floater.
    public static let maxLayersPerScreen = 3
    /// Source markers a file outside DesignSystem must carry to apply glass (`// glass-layer: sidebar|toolbar|floater`).
    public static let allowedLayerMarkers = ["sidebar", "toolbar", "floater"]
}

/// Opaque twin of a glass layer: Sheet fill and a stronger 1 px hairline, same geometry.
private struct SolidTwinModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let policy: AccessibilityPolicy
    func body(content: Content) -> some View {
        content
            .background(DSColor.contentBackground, in: shape)
            .overlay(shape.strokeBorder(DSColor.hairlineStrong, lineWidth: policy.usesHighContrast ? 1.5 : 1))
    }
}

/// Glass chrome with automatic solid twin.
private struct GlassLayerModifier<S: InsettableShape>: ViewModifier {
    let layer: DSGlassLayer
    let shape: S
    let tint: Color?
    let interactive: Bool

    func body(content: Content) -> some View {
        PolicyReader { policy in
            if policy.usesSolidSurface {
                content.modifier(SolidTwinModifier(shape: shape, policy: policy))
            } else {
                content.glassEffect(layer.glass(tint: tint, interactive: interactive), in: shape)
            }
        }
    }
}

extension View {
    /// Applies a glass layer behind floating chrome in `shape`, or its opaque twin when Reduce Transparency or
    /// Increase Contrast is on. **Never use on content** (cards, lists, inspector, transcript, settings): use
    /// ``SheetCard`` / ``InsetCard``. Files outside DesignSystem must carry a `// glass-layer:` marker (guard test).
    public func dsGlass<S: InsettableShape>(
        _ layer: DSGlassLayer = .regular, in shape: S, tint: Color? = nil, interactive: Bool = false
    ) -> some View {
        modifier(GlassLayerModifier(layer: layer, shape: shape, tint: tint, interactive: interactive))
    }

    /// Rounded-rectangle convenience for ``dsGlass(_:in:tint:interactive:)``.
    public func dsGlass(
        _ layer: DSGlassLayer = .regular, radius: CGFloat = DSRadius.large, tint: Color? = nil, interactive: Bool = false
    ) -> some View {
        dsGlass(layer, in: RoundedRectangle(cornerRadius: radius, style: .continuous), tint: tint, interactive: interactive)
    }

    /// Applies Regular glass behind chrome, falling back to a solid, bordered surface when Reduce Transparency
    /// or Increase Contrast is on. Do not use for transcript content areas. Same as `dsGlass(.regular, ...)`.
    public func glassBackground(radius: CGFloat = DSRadius.large, tint: Color? = nil, interactive: Bool = false) -> some View {
        dsGlass(.regular, radius: radius, tint: tint, interactive: interactive)
    }

    /// Animates `value` changes unless Reduce Motion is on.
    public func dsAnimation<V: Equatable>(_ animation: Animation? = .smooth(duration: 0.25), value: V) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }

    /// Animates `value` changes with a ``DSMotion`` token; under Reduce Motion it becomes a 120 ms linear fade
    /// (pair moving content with `DSTransition` so it crossfades instead of travelling).
    public func dsAnimation<V: Equatable>(_ motion: DSMotion, value: V) -> some View {
        modifier(TokenMotionModifier(motion: motion, value: value))
    }

    /// A semantic arrival/departure transition; reduced motion always crossfades without travel or scale.
    public func dsTransition(_ motion: DSMotion = .settle) -> some View {
        modifier(SemanticTransitionModifier(motion: motion))
    }

    /// One calm arrival when this view enters the hierarchy. Never loops or moves under Reduce Motion.
    public func dsEntrance() -> some View { modifier(EntranceModifier()) }

    /// Guarantees the macOS 26 minimum control height (28 pt).
    public func dsMinControlHeight() -> some View { frame(minHeight: DSLayout.minControlHeight) }
}

private struct SemanticTransitionModifier: ViewModifier {
    let motion: DSMotion
    func body(content: Content) -> some View {
        PolicyReader { policy in
            content.transition(
                .asymmetric(
                    insertion: (motion == .settle ? DSTransition.settle(policy) : .opacity).animation(motion.animation(policy)),
                    removal: AnyTransition.opacity.animation(DSMotion.exit.animation(policy))))
        }
    }
}

private struct EntranceModifier: ViewModifier {
    @State private var entered = false
    func body(content: Content) -> some View {
        PolicyReader { policy in
            content
                .opacity(entered ? 1 : 0)
                .offset(y: entered || policy.suppressesMotion ? 0 : 18)
                .scaleEffect(entered || policy.suppressesMotion ? 1 : 0.985)
                .task {
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    withAnimation(DSMotion.settle.animation(policy)) { entered = true }
                }
        }
    }
}

private struct MotionModifier<V: Equatable>: ViewModifier {
    let animation: Animation?
    let value: V
    func body(content: Content) -> some View {
        PolicyReader { policy in content.animation(policy.animation(animation), value: value) }
    }
}

private struct TokenMotionModifier<V: Equatable>: ViewModifier {
    let motion: DSMotion
    let value: V
    func body(content: Content) -> some View {
        PolicyReader { policy in content.animation(motion.animation(policy), value: value) }
    }
}

/// Motion tokens (Handoff 1 "Motion tokens"). One curve family: settle for arrivals, glide for state changes,
/// exit for departures. Reduce Motion swaps every one of them for a 120 ms linear crossfade.
public enum DSMotion: Sendable, Hashable, CaseIterable {
    /// `cubic-bezier(.2,.9,.3,1.1)`, 320-500 ms (default 420): sheets, new items, completions.
    case settle
    /// `cubic-bezier(.4,0,.2,1)`, 200-280 ms (default 240): selection glide, state changes.
    case glide
    /// `cubic-bezier(.4,0,1,1)`, 140 ms: departures, faster than arrivals.
    case exit

    /// Reduce Motion crossfade duration (seconds).
    public static let reducedDuration: TimeInterval = 0.12
    /// Recording pulse loop length (seconds). The only infinite animation besides the skeleton shimmer.
    public static let pulseDuration: TimeInterval = 2.0
    /// Skeleton shimmer loop length (seconds).
    public static let shimmerDuration: TimeInterval = 2.0

    /// Bezier control points (x1, y1, x2, y2).
    public var controlPoints: (Double, Double, Double, Double) {
        switch self {
        case .settle: (0.2, 0.9, 0.3, 1.1)
        case .glide: (0.4, 0, 0.2, 1)
        case .exit: (0.4, 0, 1, 1)
        }
    }

    /// Allowed duration range in seconds.
    public var durationRange: ClosedRange<TimeInterval> {
        switch self {
        case .settle: 0.32...0.5
        case .glide: 0.2...0.28
        case .exit: 0.14...0.14
        }
    }

    /// Default duration in seconds.
    public var defaultDuration: TimeInterval {
        switch self {
        case .settle: 0.42
        case .glide: 0.24
        case .exit: 0.14
        }
    }

    /// The animation for this token, or a 120 ms linear fade when `policy` suppresses motion.
    /// `duration` is clamped to ``durationRange``.
    public func animation(_ policy: AccessibilityPolicy = AccessibilityPolicy(), duration: TimeInterval? = nil) -> Animation {
        if policy.suppressesMotion { return .linear(duration: Self.reducedDuration) }
        let d = min(max(duration ?? defaultDuration, durationRange.lowerBound), durationRange.upperBound)
        let c = controlPoints
        return .timingCurve(c.0, c.1, c.2, c.3, duration: d)
    }

    /// Recording pulse (`cubic-bezier(.2,.7,.2,1)`, 2 s loop); `nil` under Reduce Motion (the dot stays).
    public static func pulse(_ policy: AccessibilityPolicy = AccessibilityPolicy()) -> Animation? {
        policy.suppressesMotion
            ? nil : .timingCurve(0.2, 0.7, 0.2, 1, duration: pulseDuration / 2).repeatForever(autoreverses: true)
    }

    /// Skeleton shimmer (linear, 2 s loop); `nil` under Reduce Motion.
    public static func shimmer(_ policy: AccessibilityPolicy = AccessibilityPolicy()) -> Animation? {
        policy.suppressesMotion ? nil : .linear(duration: shimmerDuration / 2).repeatForever(autoreverses: true)
    }
}

/// Transitions that crossfade without movement under Reduce Motion.
public enum DSTransition {
    /// Returns a crossfade when motion is reduced; otherwise opacity + slight scale.
    public static func appear(_ policy: AccessibilityPolicy) -> AnyTransition {
        policy.suppressesMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.985))
    }

    /// Sheets, prompts and new items arriving: rise 24 pt while fading in; a plain crossfade under Reduce Motion.
    public static func settle(_ policy: AccessibilityPolicy) -> AnyTransition {
        policy.suppressesMotion ? .opacity : .opacity.combined(with: .offset(y: 24))
    }

    /// State changes: opacity only (the glide itself moves things); crossfade under Reduce Motion.
    public static func glide(_ policy: AccessibilityPolicy) -> AnyTransition { .opacity }

    /// Departures: opacity (used with ``DSMotion/exit``).
    public static func exit(_ policy: AccessibilityPolicy) -> AnyTransition { .opacity }
}

/// Wraps glass content in a `GlassEffectContainer` unless glass is disabled, so adjacent glass shapes blend.
public struct DSGlassGroup<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content
    public init(spacing: CGFloat = DSSpacing.sm, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }
    public var body: some View {
        PolicyReader { policy in
            if policy.usesSolidSurface {
                content
            } else {
                GlassEffectContainer(spacing: spacing) { content }
            }
        }
    }
}
