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

/// Glass chrome with automatic solid fallback.
private struct GlassBackgroundModifier: ViewModifier {
    let radius: CGFloat
    let tint: Color?
    let interactive: Bool

    func body(content: Content) -> some View {
        PolicyReader { policy in
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            if policy.usesSolidSurface {
                content
                    .background(DSColor.solidChrome, in: shape)
                    .overlay(shape.strokeBorder(DSColor.hairline, lineWidth: policy.usesHighContrast ? 1.5 : 1))
            } else {
                content.glassEffect(glass, in: shape)
            }
        }
    }

    private var glass: Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint) }
        return interactive ? g.interactive() : g
    }
}

extension View {
    /// Applies Liquid Glass behind chrome, falling back to a solid, bordered surface when Reduce Transparency
    /// or Increase Contrast is on. Do not use for transcript content areas.
    public func glassBackground(radius: CGFloat = DSRadius.large, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassBackgroundModifier(radius: radius, tint: tint, interactive: interactive))
    }

    /// Animates `value` changes unless Reduce Motion is on.
    public func dsAnimation<V: Equatable>(_ animation: Animation? = .smooth(duration: 0.25), value: V) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }
}

private struct MotionModifier<V: Equatable>: ViewModifier {
    let animation: Animation?
    let value: V
    func body(content: Content) -> some View {
        PolicyReader { policy in content.animation(policy.animation(animation), value: value) }
    }
}

/// Fade/scale transition that degrades to an instant cut under Reduce Motion.
public enum DSTransition {
    /// Returns `.identity` when motion is reduced; otherwise opacity + slight scale.
    public static func appear(_ policy: AccessibilityPolicy) -> AnyTransition {
        policy.suppressesMotion ? .identity : .opacity.combined(with: .scale(scale: 0.96))
    }
}

/// Wraps content in a `GlassEffectContainer` unless glass is disabled, so adjacent glass shapes blend.
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
