import AppCore
import DesignSystem
import SwiftUI

/// Preset controls from the Components board: size step, 1-3 lines, background opacity, plus label toggles.
/// Solid surface (no glass), so it can sit in Settings or the Live view. Built-in presets are protected by
/// `CaptionPresetStore` (edits must go through Save As), not by this view. M8 restyles it.
public struct CaptionPresetControls: View {
    /// `standalone` draws its own padded card (Settings). `embedded` sits inside another card in a narrow panel: no extra
    /// padding or background, labels above full-width controls, and a menu for the four-way size choice.
    public enum Layout: Sendable { case standalone, embedded }

    @Binding private var preset: CaptionPreset
    private let layout: Layout
    public init(preset: Binding<CaptionPreset>, layout: Layout = .standalone) {
        _preset = preset
        self.layout = layout
    }

    private var sizeStep: Binding<CaptionSizeStep> {
        Binding(
            get: { CaptionSizeStep.nearest(to: preset.fontSize) },
            set: { preset.fontSize = $0.fontSize })
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            control("Size") {
                if layout == .embedded {
                    Picker("Size", selection: sizeStep) {
                        ForEach(CaptionSizeStep.allCases) { step in Text(step.title).tag(step) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .accessibilityIdentifier("liveCaptions.preset.size")
                } else {
                    Picker("Size", selection: sizeStep) {
                        ForEach(CaptionSizeStep.allCases) { step in Text(step.title).tag(step) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("liveCaptions.preset.size")
                }
            }
            control("Lines") {
                Picker("Lines", selection: $preset.visibleLines) {
                    ForEach(1...3, id: \.self) { n in Text("\(n)").tag(n) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("liveCaptions.preset.lines")
            }
            control("Opacity") {
                Slider(value: $preset.backgroundOpacity, in: 0.2...1)
                    .accessibilityIdentifier("liveCaptions.preset.opacity")
                    .accessibilityLabel(Text("Background opacity"))
            }
            Toggle("Show speaker labels", isOn: $preset.showSpeakerLabels)
                .accessibilityIdentifier("liveCaptions.preset.speakerLabels")
            Toggle("Show language badge", isOn: $preset.showLanguageBadge)
                .accessibilityIdentifier("liveCaptions.preset.languageBadge")
        }
        .padding(layout == .standalone ? DSSpacing.lg : 0)
        .background {
            if layout == .standalone {
                RoundedRectangle(cornerRadius: DSRadius.medium, style: .continuous).fill(DSColor.contentBackground)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("liveCaptions.preset.controls")
    }

    @ViewBuilder
    private func control<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        if layout == .embedded {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(title).font(DSTypography.caption).foregroundStyle(DSColor.secondaryText)
                content().frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            LabeledContent(title) { content() }
        }
    }
}
