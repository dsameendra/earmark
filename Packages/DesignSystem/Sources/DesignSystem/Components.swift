import AppCore
import SwiftUI

/// Rounded glass container for chrome (never for transcript content).
public struct GlassCard<Content: View>: View {
    private let padding: CGFloat
    private let content: Content
    public init(padding: CGFloat = DSSpacing.lg, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }
    public var body: some View {
        content.padding(padding).glassBackground(radius: DSRadius.large)
    }
}

/// Larger glass panel (e.g. overlay, HUD, popover body) with a smaller corner radius option.
public struct GlassPanel<Content: View>: View {
    private let radius: CGFloat
    private let content: Content
    public init(radius: CGFloat = DSRadius.large, @ViewBuilder content: () -> Content) {
        self.radius = radius
        self.content = content()
    }
    public var body: some View {
        content.padding(DSSpacing.md).glassBackground(radius: radius)
    }
}

/// Toolbar button using the system glass button style (bordered fallback when transparency is reduced).
public struct GlassToolbarButton: View {
    private let title: LocalizedStringKey
    private let systemImage: String
    private let prominent: Bool
    private let action: () -> Void
    public init(_ title: LocalizedStringKey, systemImage: String, prominent: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.prominent = prominent
        self.action = action
    }
    public var body: some View {
        PolicyReader { policy in
            let button = Button(action: action) { Label(title, systemImage: systemImage) }.labelStyle(.iconOnly).help(Text(title))
            if policy.usesSolidSurface {
                if prominent { button.buttonStyle(.borderedProminent) } else { button.buttonStyle(.bordered) }
            } else {
                if prominent { button.buttonStyle(.glassProminent) } else { button.buttonStyle(.glass) }
            }
        }
    }
}

/// Small capsule showing a status with icon and text (never color alone).
public struct StatusPill: View {
    private let text: LocalizedStringKey
    private let systemImage: String?
    private let tone: DSTone
    public init(_ text: LocalizedStringKey, systemImage: String? = nil, tone: DSTone = .neutral) {
        self.text = text
        self.systemImage = systemImage
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
            if let systemImage { Image(systemName: systemImage).accessibilityHidden(true) }
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
                    .animation(policy.animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)), value: pulsing)
                if let label { Text(label).font(DSTypography.badge).foregroundStyle(DSColor.recording) }
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
    private let systemImage: String
    private let title: LocalizedStringKey
    private let message: LocalizedStringKey?
    private let actionTitle: LocalizedStringKey?
    private let action: (() -> Void)?
    public init(
        systemImage: String, title: LocalizedStringKey, message: LocalizedStringKey? = nil,
        actionTitle: LocalizedStringKey? = nil, action: (() -> Void)? = nil
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }
    public var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
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
                .animation(policy.animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)), value: phase)
                .onAppear { phase = true }
                .accessibilityHidden(true)
        }
    }
}
