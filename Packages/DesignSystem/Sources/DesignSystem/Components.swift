import AppCore
import SwiftUI

/// Solid surface card in the primary tier (Sheet): Sheet fill, 1 px hairline, soft warm shadow.
/// The default container for content (cards, inspector sections, settings groups). Never glass.
public struct SheetCard<Content: View>: View {
    private let padding: CGFloat
    private let radius: CGFloat
    private let selected: Bool
    private let content: Content
    public init(
        padding: CGFloat = DSSpacing.lg, radius: CGFloat = DSRadius.card, selected: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.radius = radius
        self.selected = selected
        self.content = content()
    }
    public var body: some View {
        content.padding(padding).dsSolidSurface(.sheet, radius: radius, selected: selected)
    }
}

/// Solid surface card in the secondary tier (Inset): rows, chips, grouped regions inside a Sheet.
public struct InsetCard<Content: View>: View {
    private let padding: CGFloat
    private let radius: CGFloat
    private let selected: Bool
    private let content: Content
    public init(
        padding: CGFloat = DSSpacing.md, radius: CGFloat = DSRadius.large, selected: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.radius = radius
        self.selected = selected
        self.content = content()
    }
    public var body: some View {
        content.padding(padding).dsSolidSurface(.inset, radius: radius, selected: selected)
    }
}

/// Solid surface tier.
public enum DSSurfaceTier: Sendable, Hashable {
    case sheet, inset
}

private struct SolidSurfaceModifier: ViewModifier {
    let tier: DSSurfaceTier
    let radius: CGFloat
    let selected: Bool

    func body(content: Content) -> some View {
        PolicyReader { policy in
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            let fill: Color = selected ? DSColor.accentTint : (tier == .sheet ? DSColor.contentBackground : DSColor.insetBackground)
            let border: Color = selected ? DSColor.accent : (policy.usesHighContrast ? DSColor.hairlineStrong : DSColor.hairline)
            content
                .background(fill, in: shape)
                .overlay(shape.strokeBorder(border, lineWidth: selected ? 1.5 : (policy.usesHighContrast ? 1.5 : 1)))
                .shadow(color: DSColor.shadow.opacity(tier == .sheet && !policy.usesHighContrast ? 0.07 : 0), radius: 12, y: 4)
        }
    }
}

extension View {
    /// Draws a solid Sheet or Inset surface behind the view (fill, hairline, soft shadow for Sheet). `selected`
    /// switches to the Ember tint fill with an Ember stroke. Use instead of glass for any content.
    public func dsSolidSurface(_ tier: DSSurfaceTier = .sheet, radius: CGFloat = DSRadius.card, selected: Bool = false) -> some View {
        modifier(SolidSurfaceModifier(tier: tier, radius: radius, selected: selected))
    }
}

/// Deprecated: glass must not be applied to content. Forwards to a solid ``SheetCard``.
@available(*, deprecated, message: "Glass on content is not allowed in the M8 design; use SheetCard or InsetCard.")
public struct GlassCard<Content: View>: View {
    private let padding: CGFloat
    private let content: Content
    public init(padding: CGFloat = DSSpacing.lg, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }
    public var body: some View { SheetCard(padding: padding, radius: DSRadius.large) { content } }
}

/// Larger panel for a transient floater (overlay, HUD, popover body): the Prominent glass layer with its solid twin.
/// Not for content. Deprecated name kept for source compatibility; prefer `dsGlass(.prominent, ...)`.
@available(*, deprecated, message: "Use dsGlass(.prominent, radius:) on a transient floater, or SheetCard for content.")
public struct GlassPanel<Content: View>: View {
    private let radius: CGFloat
    private let content: Content
    public init(radius: CGFloat = DSRadius.large, @ViewBuilder content: () -> Content) {
        self.radius = radius
        self.content = content()
    }
    public var body: some View {
        content.padding(DSSpacing.md).dsGlass(.prominent, radius: radius)
    }
}

/// Toolbar button using the system glass button style (bordered fallback when transparency is reduced).
public struct GlassToolbarButton: View {
    private let title: LocalizedStringKey
    private let systemImage: String?
    private let symbol: DSSymbol?
    private let prominent: Bool
    private let action: () -> Void
    public init(_ title: LocalizedStringKey, systemImage: String, prominent: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.symbol = nil
        self.prominent = prominent
        self.action = action
    }
    /// Custom symbol (stock fallback at toolbar size for the heavy five, see ``DSIconContext``).
    public init(_ title: LocalizedStringKey, symbol: DSSymbol, prominent: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = nil
        self.symbol = symbol
        self.prominent = prominent
        self.action = action
    }
    public var body: some View {
        PolicyReader { policy in
            let button = Button(action: action) { buttonLabel }
                .labelStyle(.iconOnly).help(Text(title)).dsIconContext(.toolbar)
            if policy.usesSolidSurface {
                if prominent { button.buttonStyle(.borderedProminent) } else { button.buttonStyle(.bordered) }
            } else {
                if prominent { button.buttonStyle(.glassProminent) } else { button.buttonStyle(.glass) }
            }
        }
    }
}

extension GlassToolbarButton {
    @ViewBuilder fileprivate var buttonLabel: some View {
        if let symbol { Label { Text(title) } icon: { DSIcon(symbol) } } else { Label(title, systemImage: systemImage ?? "questionmark") }
    }
}

/// Small capsule showing a status with icon and text (never color alone).
public struct StatusPill: View {
    private let text: LocalizedStringKey
    private let systemImage: String?
    private let symbol: DSSymbol?
    private let tone: DSTone
    public init(_ text: LocalizedStringKey, systemImage: String? = nil, tone: DSTone = .neutral) {
        self.text = text
        self.systemImage = systemImage
        self.symbol = nil
        self.tone = tone
    }

    /// Pill with a `DSSymbol` icon.
    public init(_ text: LocalizedStringKey, symbol: DSSymbol, tone: DSTone = .neutral) {
        self.text = text
        self.systemImage = nil
        self.symbol = symbol
        self.tone = tone
    }

    /// Pill for a job state.
    public init(state: JobState) {
        switch state {
        case .pending: self.init("Pending", systemImage: "clock", tone: .neutral)
        case .running: self.init("Running", systemImage: "waveform", tone: .info)
        case .paused: self.init("Paused", systemImage: "pause.fill", tone: .warning)
        case .failed: self.init("Failed", systemImage: "exclamationmark.triangle.fill", tone: .danger)
        case .completed: self.init("Completed", systemImage: "checkmark.circle.fill", tone: .success)
        case .cancelled: self.init("Cancelled", systemImage: "xmark.circle", tone: .neutral)
        }
    }

    public var body: some View {
        HStack(spacing: DSSpacing.xs) {
            if let symbol { DSIcon(symbol).dsIconContext(.menu) } else if let systemImage {
                Image(systemName: systemImage).accessibilityHidden(true)
            }
            Text(text)
        }
        .font(DSTypography.badge)
        .foregroundStyle(tone.color)
        .padding(.horizontal, DSSpacing.sm)
        .padding(.vertical, DSSpacing.xxs + 1)
        .background(tone.color.opacity(0.15), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// Pulsing red dot plus label for active recording/captioning. Pulse is suppressed under Reduce Motion.
public struct RecordingIndicator: View {
    private let label: LocalizedStringKey?
    @State private var pulsing = false
    public init(label: LocalizedStringKey? = "Recording") { self.label = label }

    public var body: some View {
        PolicyReader { policy in
            HStack(spacing: DSSpacing.xs) {
                Circle()
                    .fill(DSColor.recording)
                    .frame(width: 8, height: 8)
                    .opacity(pulsing && !policy.suppressesMotion ? 0.35 : 1)
                    .animation(DSMotion.pulse(policy), value: pulsing)
                if let label { Text(label).font(DSTypography.badge).foregroundStyle(DSColor.recordingText) }
            }
            .onAppear { pulsing = true }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Recording in progress"))
        }
    }
}

/// Compact language code badge (e.g. "SI", "EN") with Sinhala-safe font.
public struct LanguageBadge: View {
    private let language: LanguageCode
    public init(_ language: LanguageCode) { self.language = language }

    /// Upper-cased primary subtag shown in the badge.
    nonisolated public static func label(for language: LanguageCode) -> String { language.primary.rawValue.uppercased() }

    public var body: some View {
        Text(Self.label(for: language))
            .font(DSTypography.badge)
            .foregroundStyle(DSColor.secondaryText)
            .padding(.horizontal, DSSpacing.xs + 2)
            .padding(.vertical, DSSpacing.xxs)
            .background(DSColor.secondaryText.opacity(0.15), in: RoundedRectangle(cornerRadius: DSRadius.small, style: .continuous))
            .accessibilityLabel(Text(Locale.current.localizedString(forLanguageCode: language.rawValue) ?? language.rawValue))
    }
}

/// Speaker chip: colored dot (palette slot) plus name, so identity never relies on color alone.
public struct SpeakerChip: View {
    private let name: String
    private let slot: Int
    public init(name: String, slot: Int) {
        self.name = name
        self.slot = slot
    }
    public var body: some View {
        HStack(spacing: DSSpacing.xs) {
            Circle().fill(SpeakerPalette.color(forSlot: slot)).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(name).font(DSTypography.caption.weight(.medium)).foregroundStyle(DSColor.primaryText)
        }
        .padding(.horizontal, DSSpacing.sm)
        .padding(.vertical, DSSpacing.xxs + 1)
        .background(SpeakerPalette.color(forSlot: slot).opacity(0.18), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Speaker \(name)"))
    }
}

/// Row with title, optional detail and a progress bar (indeterminate when `fraction` is nil).
public struct ProgressRow: View {
    private let title: String
    private let detail: String?
    private let fraction: Double?
    public init(title: String, detail: String? = nil, fraction: Double?) {
        self.title = title
        self.detail = detail
        self.fraction = fraction.map { min(1, max(0, $0)) }
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            HStack {
                Text(title).font(DSTypography.body).lineLimit(1)
                Spacer(minLength: DSSpacing.sm)
                if let fraction { Text(fraction, format: .percent.precision(.fractionLength(0))).font(DSTypography.timestamp) }
            }
            if let fraction { ProgressView(value: fraction) } else { ProgressView().progressViewStyle(.linear) }
            if let detail { Text(detail).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Centered empty-state with icon, message and optional action.
public struct EmptyState: View {
    private let systemImage: String?
    private let symbol: DSSymbol?
    private let title: LocalizedStringKey
    private let message: LocalizedStringKey?
    private let actionTitle: LocalizedStringKey?
    private let action: (() -> Void)?
    public init(
        systemImage: String, title: LocalizedStringKey, message: LocalizedStringKey? = nil,
        actionTitle: LocalizedStringKey? = nil, action: (() -> Void)? = nil
    ) {
        self.systemImage = systemImage
        self.symbol = nil
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    /// Empty state with a custom duotone symbol (custom stays at empty-state size).
    public init(
        symbol: DSSymbol, title: LocalizedStringKey, message: LocalizedStringKey? = nil,
        actionTitle: LocalizedStringKey? = nil, action: (() -> Void)? = nil
    ) {
        self.systemImage = nil
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }
    public var body: some View {
        ContentUnavailableView {
            if let symbol {
                Label { Text(title) } icon: { DSIcon(symbol).dsIconContext(.emptyState) }
            } else {
                Label(title, systemImage: systemImage ?? "questionmark")
            }
        } description: {
            if let message { Text(message) }
        } actions: {
            if let actionTitle, let action { Button(actionTitle, action: action) }
        }
    }
}

/// Error state with message and retry action.
public struct ErrorState: View {
    private let title: LocalizedStringKey
    private let message: String
    private let retry: (() -> Void)?
    public init(title: LocalizedStringKey = "Something went wrong", message: String, retry: (() -> Void)? = nil) {
        self.title = title
        self.message = message
        self.retry = retry
    }
    public var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            if let retry { Button("Retry", action: retry) }
        }
    }
}

/// Loading placeholder; shimmer is replaced by a static fill under Reduce Motion.
public struct Skeleton: View {
    private let width: CGFloat?
    private let height: CGFloat
    @State private var phase = false
    public init(width: CGFloat? = nil, height: CGFloat = 14) {
        self.width = width
        self.height = height
    }
    public var body: some View {
        PolicyReader { policy in
            RoundedRectangle(cornerRadius: DSRadius.small, style: .continuous)
                .fill(DSColor.secondaryText.opacity(phase && !policy.suppressesMotion ? 0.12 : 0.22))
                .frame(width: width, height: height)
                .animation(DSMotion.shimmer(policy), value: phase)
                .onAppear { phase = true }
                .accessibilityHidden(true)
        }
    }
}
